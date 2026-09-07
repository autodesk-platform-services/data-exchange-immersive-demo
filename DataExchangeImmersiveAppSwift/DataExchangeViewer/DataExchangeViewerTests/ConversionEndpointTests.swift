//
//  ConversionEndpointTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
@testable import DataExchangeViewer

/// Exchange URNs go into the path, not the query, and they contain characters that are reserved
/// there (`:` always, and `/`, `+`, `=` in the base64 tail of a version URN). Getting this wrong
/// is a 404 from the conversion service with nothing in the app to explain it.
@Suite("Conversion service endpoints")
struct ConversionEndpointTests {
    private let api = ConversionAPI()
    private let base = ConversionServiceConstants.baseURL.absoluteString

    @Test func encodesTheColonsInALineageURN() {
        let urn = "urn:adsk.wipprod:dm.lineage:pTMcMOe6QIygw-QOgYbxRw"
        let expected = base + "/api/exchanges/urn%3Aadsk.wipprod%3Adm.lineage%3ApTMcMOe6QIygw-QOgYbxRw"
        #expect(api.endpoint(urn: urn).absoluteString == expected)
    }

    @Test func encodesReservedCharactersThatWouldSplitThePath() {
        let prefix = base + "/api/exchanges/"
        let url = api.endpoint(urn: "urn:adsk:a/b+c=d?e#f")
        #expect(url.absoluteString.hasPrefix(prefix))

        let segment = url.absoluteString.dropFirst(prefix.count)
        for reserved in ["/", "+", "=", "?", "#"] {
            #expect(!segment.contains(reserved), "\(reserved) reached the URL unencoded")
        }
    }

    /// The service has to receive the URN it was given, character for character.
    @Test(arguments: [
        "urn:adsk.wipprod:dm.lineage:pTMcMOe6QIygw-QOgYbxRw",
        "urn:adsk.wipprod:fs.file:vf.pTMcMOe6QIygw-QOgYbxRw?version=3",
        "urn:adsk:a/b+c=d",
        "plain-urn",
    ])
    func decodesBackToTheOriginalURN(urn: String) {
        let expected = "/api/exchanges/" + urn
        #expect(api.endpoint(urn: urn).path(percentEncoded: false) == expected)
    }

    /// `appendingPathComponent` treats '%' as a character needing escaping, so layering it on an
    /// already-encoded segment turns `%3A` into `%253A` and the URN arrives corrupted.
    @Test func doesNotDoubleEncode() {
        let url = api.endpoint(urn: "urn:adsk.wipprod:dm.lineage:abc")
        #expect(!url.absoluteString.contains("%25"))
    }

    @Test func appendsTheArtifactFileNameAsItsOwnPathComponent() {
        let urn = "urn:adsk.wipprod:dm.lineage:abc"
        let url = api.artifactEndpoint(urn: urn, fileName: "log.txt")
        let expectedURL = api.endpoint(urn: urn).absoluteString + "/log.txt"
        let expectedPath = "/api/exchanges/" + urn + "/log.txt"
        #expect(url.absoluteString == expectedURL)
        #expect(url.lastPathComponent == "log.txt")
        #expect(url.path(percentEncoded: false) == expectedPath)
    }
}
