//
//  ConversionAPI.swift
//  DataExchangeViewer
//

import Foundation

struct ConversionAPI {
    // Not private: `ConversionEndpointTests` checks the job ID that goes into the path, because
    // the service has to read back exactly the collection and URN the app encoded.
    func artifactEndpoint(urn: String, collectionId: String, fileName: String) -> URL {
        endpoint(urn: urn, collectionId: collectionId)
            .appendingPathComponent("artifacts")
            .appendingPathComponent(fileName)
    }

    func endpoint(urn: String, collectionId: String) -> URL {
        // The job ID is base64url, whose alphabet is entirely safe in a path segment, so there is
        // no percent-encoding here to get wrong — and `appendingPathComponent` can be used on the
        // result without the double-encoding it would cause on an already-escaped URN.
        let jobId = JobID.encode(collectionId: collectionId, exchangeUrn: urn)
        return URL(string: ConversionServiceConstants.baseURL.absoluteString + "/api/jobs/" + jobId)!
    }

    // Maps the error status codes shared by every endpoint (401/403); anything else becomes a
    // generic ConversionError.http carrying the status code and response body.
    private func errorForStatus(_ http: HTTPURLResponse?, data: Data) -> Error {
        switch http?.statusCode {
        case 401: return ConversionError.unauthorized
        case 403: return ConversionError.forbidden
        default: return ConversionError.http(http?.statusCode ?? -1, String(data: data, encoding: .utf8) ?? "")
        }
    }

    func status(urn: String, collectionId: String, token: String) async throws -> ConversionMetadata? {
        var request = URLRequest(url: endpoint(urn: urn, collectionId: collectionId))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 404: return nil
        case 200: return try JSONDecoder().decode(ConversionMetadata.self, from: data)
        default: throw errorForStatus(http, data: data)
        }
    }

    func start(urn: String, collectionId: String, token: String) async throws {
        var request = URLRequest(url: endpoint(urn: urn, collectionId: collectionId))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 202: return
        case 409: throw ConversionError.conflict
        default: throw errorForStatus(http, data: data)
        }
    }

    func delete(urn: String, collectionId: String, token: String) async throws {
        var request = URLRequest(url: endpoint(urn: urn, collectionId: collectionId))
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 200: return
        default: throw errorForStatus(http, data: data)
        }
    }

    /// The outcome of an incremental artifact read.
    enum ArtifactChunk {
        /// Only the bytes appended since the requested offset.
        case appended(Data)
        /// The whole artifact, either because this is the first read or because the service
        /// answered a range request with a full body.
        case whole(Data)
        /// Nothing has been appended since the requested offset.
        case unchanged
    }

    /// Streams an artifact to a temporary file and returns its location; the caller owns the
    /// file from that point on. `data(for:)` would materialize the whole package in memory
    /// first — a 400 MB USDZ becomes a 400 MB `Data` before it is ever written to disk.
    ///
    /// `onProgress` receives the bytes written so far and the total the service declared, when it
    /// declared one. It is called on `URLSession`'s delegate queue rather than the main actor.
    func downloadArtifact(
        urn: String,
        collectionId: String,
        fileName: String,
        token: String,
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> URL {
        var request = URLRequest(url: artifactEndpoint(urn: urn, collectionId: collectionId, fileName: fileName))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Held in a local so the delegate outlives the call regardless of how strongly
        // `URLSessionTask` happens to reference it.
        let progress = DownloadProgressDelegate(onProgress: onProgress)
        let (fileURL, response) = try await URLSession.shared.download(for: request, delegate: progress)
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200 else {
            // Error bodies are small, so reading this one back is safe — and it carries the
            // detail the generic status-code message would otherwise lose.
            let body = (try? Data(contentsOf: fileURL)) ?? Data()
            try? FileManager.default.removeItem(at: fileURL)
            throw errorForStatus(http, data: body)
        }
        return fileURL
    }

    /// Reads a text artifact from `offset` onwards, so a growing conversion log is tailed rather
    /// than refetched in full on every poll. Returns nil when the artifact does not exist.
    func artifactChunk(
        urn: String,
        collectionId: String,
        fileName: String,
        token: String,
        from offset: Int
    ) async throws -> ArtifactChunk? {
        var request = URLRequest(url: artifactEndpoint(urn: urn, collectionId: collectionId, fileName: fileName))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        // 200 in answer to a range request means the service ignored it, so this is a full body.
        case 200: return .whole(data)
        case 206: return .appended(data)
        // The requested range starts at or past the end of the file: no new output yet.
        case 416: return .unchanged
        case 404: return nil
        default: throw errorForStatus(http, data: data)
        }
    }

    static func findArtifact(_ metadata: ConversionMetadata?, extension ext: String) -> String? {
        metadata?.artifacts.first { $0.hasSuffix(ext) }
    }
}

/// Reports byte counts for `URLSession.download(for:delegate:)`. A task-specific delegate is the
/// only way to observe progress there — the async call itself just hands back the finished file —
/// and a multi-hundred-megabyte BIM export is exactly the case where an indeterminate spinner
/// isn't good enough.
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64?) -> Void

    nonisolated init(onProgress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.onProgress = onProgress
        super.init()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        // The expected total is `NSURLSessionTransferSizeUnknown` when the response carries no
        // Content-Length, which the caller reports as an indeterminate download rather than 0%.
        onProgress(
            totalBytesWritten,
            totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        )
    }

    /// Required by `URLSessionDownloadDelegate`, but the async `download(for:delegate:)` returns
    /// the downloaded file itself, so there is nothing to move here.
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}
