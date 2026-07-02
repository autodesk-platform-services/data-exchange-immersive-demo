//
//  USDzCache.swift
//  DataExchangeViewer
//

import Foundation
import CryptoKit

struct USDzCache {
    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("USDzCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileName(for exchangeUrn: String) -> String {
        let digest = SHA256.hash(data: Data(exchangeUrn.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".usdz"
    }

    func url(for exchangeUrn: String) -> URL {
        directory.appendingPathComponent(fileName(for: exchangeUrn))
    }

    func exists(for exchangeUrn: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: exchangeUrn).path)
    }

    @discardableResult
    func save(_ data: Data, for exchangeUrn: String) throws -> URL {
        let fileURL = url(for: exchangeUrn)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    func delete(for exchangeUrn: String) {
        try? FileManager.default.removeItem(at: url(for: exchangeUrn))
    }
}
