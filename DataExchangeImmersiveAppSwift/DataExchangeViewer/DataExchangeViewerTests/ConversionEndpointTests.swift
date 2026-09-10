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
    private let collectionId = "b.project-1"

    @Test func encodesTheColonsInALineageURN() {
        let urn = "urn:adsk.wipprod:dm.lineage:pTMcMOe6QIygw-QOgYbxRw"
        let expected = base + "/api/exchanges/b.project-1/urn%3Aadsk.wipprod%3Adm.lineage%3ApTMcMOe6QIygw-QOgYbxRw"
        #expect(api.endpoint(urn: urn, collectionId: collectionId).absoluteString == expected)
    }

    @Test func encodesReservedCharactersThatWouldSplitThePath() {
        let url = api.endpoint(urn: "urn:adsk:a/b+c=d?e#f", collectionId: collectionId)
        let segment = url.lastPathComponent
        for reserved in ["/", "+", "=", "?", "#"] {
            #expect(!segment.contains(reserved), "\(reserved) reached the URL unencoded")
        }
    }

    @Test func encodesReservedCharactersInTheCollectionId() {
        let url = api.endpoint(urn: "plain-urn", collectionId: "project&region=US")
        #expect(url.pathComponents[url.pathComponents.count - 2] == "project&region=US")
        #expect(url.absoluteString.hasSuffix("/project%26region%3DUS/plain-urn"))
    }

    /// The service has to receive the URN it was given, character for character.
    @Test(arguments: [
        "urn:adsk.wipprod:dm.lineage:pTMcMOe6QIygw-QOgYbxRw",
        "urn:adsk.wipprod:fs.file:vf.pTMcMOe6QIygw-QOgYbxRw?version=3",
        "urn:adsk:a/b+c=d",
        "plain-urn",
    ])
    func decodesBackToTheOriginalURN(urn: String) {
        let expected = "/api/exchanges/" + collectionId + "/" + urn
        #expect(api.endpoint(urn: urn, collectionId: collectionId).path(percentEncoded: false) == expected)
    }

    /// `appendingPathComponent` treats '%' as a character needing escaping, so layering it on an
    /// already-encoded segment turns `%3A` into `%253A` and the URN arrives corrupted.
    @Test func doesNotDoubleEncode() {
        let url = api.endpoint(urn: "urn:adsk.wipprod:dm.lineage:abc", collectionId: collectionId)
        #expect(!url.absoluteString.contains("%25"))
    }

    @Test func appendsTheArtifactFileNameAsItsOwnPathComponent() {
        let urn = "urn:adsk.wipprod:dm.lineage:abc"
        let url = api.artifactEndpoint(urn: urn, collectionId: collectionId, fileName: "log.txt")
        let expectedURL = base + "/api/exchanges/b.project-1/urn%3Aadsk.wipprod%3Adm.lineage%3Aabc/log.txt"
        let expectedPath = "/api/exchanges/" + collectionId + "/" + urn + "/log.txt"
        #expect(url.absoluteString == expectedURL)
        #expect(url.lastPathComponent == "log.txt")
        #expect(url.path(percentEncoded: false) == expectedPath)
    }
}
