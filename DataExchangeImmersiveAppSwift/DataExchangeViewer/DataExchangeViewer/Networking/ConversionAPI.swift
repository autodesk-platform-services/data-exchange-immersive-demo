//
//  ConversionAPI.swift
//  DataExchangeViewer
//

import Foundation

struct ConversionAPI {
    // Not private: `ConversionEndpointTests` checks the paths these build, because the service has
    // to read back exactly the collection and URN the app put in them.
    //
    // Sub-resources are concatenated rather than appended with `appendingPathComponent`, so every
    // escape in the URL is one `JobPath` put there.
    func artifactEndpoint(urn: String, collectionId: String, fileName: String) -> URL {
        URL(string: endpoint(urn: urn, collectionId: collectionId).absoluteString
            + "/artifacts/" + JobPath.escaped(fileName))!
    }

    /// The conversion log, which is a sub-resource of the job rather than one of its artifacts.
    func logEndpoint(urn: String, collectionId: String) -> URL {
        URL(string: endpoint(urn: urn, collectionId: collectionId).absoluteString + "/log")!
    }

    func endpoint(urn: String, collectionId: String) -> URL {
        URL(string: ConversionServiceConstants.baseURL.absoluteString
            + "/api/jobs/" + JobPath.of(collectionId: collectionId, exchangeUrn: urn))!
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
        case 200: return try JSONDecoder.conversionService.decode(ConversionMetadata.self, from: data)
        default: throw errorForStatus(http, data: data)
        }
    }

    /// Starts a conversion, or adopts the one already running or already finished, and returns the
    /// job's state as the service reports it.
    ///
    /// The call is idempotent — it used to answer 409 when a conversion existed, which meant the
    /// only way to ask again was to DELETE first. Returns nil if the service answers 202 without a
    /// body, which is what an older build does.
    func start(urn: String, collectionId: String, token: String) async throws -> ConversionMetadata? {
        var request = URLRequest(url: endpoint(urn: urn, collectionId: collectionId))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        switch http?.statusCode {
        case 202: return try? JSONDecoder.conversionService.decode(ConversionMetadata.self, from: data)
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
        artifact: ConversionArtifact,
        urn: String,
        collectionId: String,
        token: String,
        onProgress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }
    ) async throws -> URL {
        // The presigned URL carries its own authorization, so following it skips the bearer-token
        // path on the service — and with it the Data Exchange round trip that path performs on
        // every artifact request just to authorize one.
        let presigned = artifact.url.flatMap(URL.init(string:))
        var request = URLRequest(
            url: presigned ?? artifactEndpoint(urn: urn, collectionId: collectionId, fileName: artifact.name)
        )
        if presigned == nil {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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

    /// Reads the conversion log from `offset` onwards, so a growing log is tailed rather than
    /// refetched in full on every poll. Returns nil when there is no log.
    ///
    /// `presignedUrl` is the `logUrl` from the last status, when there was one. The bearer token is
    /// sent either way: the service takes the presigned path whenever a secret is present and
    /// ignores the header, so there is one request shape rather than two.
    func logChunk(
        urn: String,
        collectionId: String,
        presignedUrl: String?,
        token: String,
        from offset: Int
    ) async throws -> ArtifactChunk? {
        let url = presignedUrl.flatMap(URL.init(string:)) ?? logEndpoint(urn: urn, collectionId: collectionId)
        var request = URLRequest(url: url)
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

    /// The first artifact of the given type, or nil when the conversion produced none.
    static func findArtifact(_ metadata: ConversionMetadata?, type: String) -> ConversionArtifact? {
        metadata?.artifacts.first { $0.type == type }
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
