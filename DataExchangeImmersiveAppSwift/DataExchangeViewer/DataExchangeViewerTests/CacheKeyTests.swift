//
//  CacheKeyTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
@testable import DataExchangeViewer

/// What the on-disk USDZ cache is keyed by. A key that isn't version-specific serves last week's
/// geometry for a newly published exchange; a key that isn't stable across launches never hits.
@Suite("USDZ cache keys")
struct CacheKeyTests {
    private func exchange(fileUrn: String, fileVersionUrn: String) -> Exchange {
        Exchange(
            id: "exchange-1",
            name: "Basement",
            projectId: "project-1",
            fileUrn: fileUrn,
            fileVersionUrn: fileVersionUrn
        )
    }

    @Test func fileNameIsAHexDigestWithTheUSDZExtension() {
        let name = USDzCache.fileName(for: "urn:adsk.wipprod:dm.lineage:abc")
        #expect(name.hasSuffix(".usdz"))
        let digest = name.dropLast(".usdz".count)
        // SHA-256 as lowercase hex.
        #expect(digest.count == 64)
        #expect(digest.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    @Test func fileNameIsStableForTheSameURN() {
        let urn = "urn:adsk.wipprod:dm.lineage:abc"
        #expect(USDzCache.fileName(for: urn) == USDzCache.fileName(for: urn))
    }

    @Test func fileNameDistinguishesURNsThatDifferByOneCharacter() {
        #expect(
            USDzCache.fileName(for: "urn:adsk.wipprod:dm.lineage:abc")
                != USDzCache.fileName(for: "urn:adsk.wipprod:dm.lineage:abd")
        )
    }

    /// The conversion service is asked about the lineage URN, because the Data Exchange SDK only
    /// accepts one — but the cache is keyed by the version, so the two must not be conflated.
    @Test func conversionUsesTheLineageURN() {
        let exchange = exchange(fileUrn: "urn:lineage:abc", fileVersionUrn: "urn:version:abc:3")
        #expect(exchange.exchangeUrn == "urn:lineage:abc")
    }

    @Test func cacheKeyIsTheVersionURNWhenThereIsOne() {
        let exchange = exchange(fileUrn: "urn:lineage:abc", fileVersionUrn: "urn:version:abc:3")
        #expect(exchange.cacheKeyUrn == "urn:version:abc:3")
    }

    /// The API reports no version for some exchanges, so the key falls back to the lineage URN.
    @Test func cacheKeyFallsBackToTheLineageURN() {
        let exchange = exchange(fileUrn: "urn:lineage:abc", fileVersionUrn: "")
        #expect(exchange.cacheKeyUrn == "urn:lineage:abc")
    }

    /// Keying on the version is what stops a newly published version from being served as the
    /// file already on disk, behind a green "Ready to preview" badge.
    @Test func twoVersionsOfOneExchangeCacheSeparately() {
        let v2 = exchange(fileUrn: "urn:lineage:abc", fileVersionUrn: "urn:version:abc:2")
        let v3 = exchange(fileUrn: "urn:lineage:abc", fileVersionUrn: "urn:version:abc:3")
        #expect(v2.exchangeUrn == v3.exchangeUrn)
        #expect(USDzCache.fileName(for: v2.cacheKeyUrn) != USDzCache.fileName(for: v3.cacheKeyUrn))
    }
}
