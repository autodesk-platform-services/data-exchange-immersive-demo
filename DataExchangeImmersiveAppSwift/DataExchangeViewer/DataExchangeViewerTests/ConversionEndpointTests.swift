//
//  ConversionEndpointTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
@testable import DataExchangeViewer

/// The conversion service identifies a job by the collection and exchange URN in its URL:
/// `/api/jobs/{collectionId}/{exchangeUrn}`. Getting the escaping wrong is a 404 — or worse, a URL
/// that names a different exchange — with nothing in the app to explain it.
@Suite("Conversion service endpoints")
struct ConversionEndpointTests {
    private let api = ConversionAPI()
    private let base = ConversionServiceConstants.baseURL.absoluteString
    private let collectionId = "b.project-1"

    private static let urns = [
        "urn:adsk.wipprod:dm.lineage:pTMcMOe6QIygw-QOgYbxRw",
        "urn:adsk.wipprod:fs.file:vf.pTMcMOe6QIygw-QOgYbxRw?version=3",
        "urn:adsk:a/b+c=d?e#f",
        "plain-urn",
    ]

    // MARK: - Job paths

    /// The pair occupies exactly two segments whatever the URN contains: anything that would end
    /// the segment, or split it into a third, is escaped.
    @Test(arguments: urns)
    func jobPathIsTwoSegments(urn: String) {
        let path = JobPath.of(collectionId: collectionId, exchangeUrn: urn)
        #expect(path.filter { $0 == "/" }.count == 1)
        #expect(!path.contains("?"))
        #expect(!path.contains("#"))
    }

    /// What the app escapes, the service must decode back character for character.
    @Test(arguments: urns)
    func jobPathRoundTripsTheURN(urn: String) throws {
        let halves = JobPath.of(collectionId: collectionId, exchangeUrn: urn)
            .split(separator: "/", maxSplits: 1)
            .map(String.init)
        try #require(halves.count == 2)
        #expect(halves[0].removingPercentEncoding == collectionId)
        #expect(halves[1].removingPercentEncoding == urn)
    }

    /// A collection ID may contain characters that are reserved elsewhere in a URL but legal in a
    /// path segment, and they survive the round trip either way.
    @Test func jobPathRoundTripsACollectionIdWithReservedCharacters() throws {
        let halves = JobPath.of(collectionId: "project&region=US", exchangeUrn: "urn:adsk:abc")
            .split(separator: "/", maxSplits: 1)
            .map(String.init)
        try #require(halves.count == 2)
        #expect(halves[0].removingPercentEncoding == "project&region=US")
        #expect(halves[1].removingPercentEncoding == "urn:adsk:abc")
    }

    /// The point of the whole scheme: a URN a developer has in front of them appears in the URL as
    /// it is, rather than as `urn%3Aadsk%3A...` or as a base64url job ID they have to compute.
    @Test func leavesAnExchangeURNReadable() {
        let urn = "urn:adsk.wipprod:dm.lineage:pTMcMOe6QIygw-QOgYbxRw"
        #expect(JobPath.of(collectionId: collectionId, exchangeUrn: urn) == "b.project-1/" + urn)
    }

    /// A `/` inside a URN cannot be a `/` in the path — it would look like a third segment.
    @Test func escapesASlashInsideTheURN() {
        let path = JobPath.of(collectionId: collectionId, exchangeUrn: "urn:adsk:a/b")
        #expect(path == "b.project-1/urn:adsk:a%2Fb")
    }

    // MARK: - URLs

    @Test func buildsTheJobEndpoint() {
        let urn = "urn:adsk.wipprod:dm.lineage:pTMcMOe6QIygw-QOgYbxRw"
        #expect(api.endpoint(urn: urn, collectionId: collectionId).absoluteString
            == base + "/api/jobs/b.project-1/" + urn)
    }

    /// The `?` of a version URN would otherwise start the query string, taking the rest of the URN
    /// with it and leaving the service looking for an exchange that does not exist.
    @Test func escapesAQueryMarkerInTheURN() {
        let url = api.endpoint(urn: "urn:adsk.wipprod:fs.file:vf.abc?version=3", collectionId: collectionId)
        #expect(url.absoluteString
            == base + "/api/jobs/b.project-1/urn:adsk.wipprod:fs.file:vf.abc%3Fversion=3")
        #expect(url.query == nil)
    }

    /// The log is a sub-resource of the job, not one of its artifacts.
    @Test func buildsTheLogEndpoint() {
        let urn = "urn:adsk.wipprod:dm.lineage:abc"
        #expect(api.logEndpoint(urn: urn, collectionId: collectionId).absoluteString
            == base + "/api/jobs/b.project-1/" + urn + "/log")
    }

    @Test func appendsTheArtifactFileNameUnderArtifacts() {
        let urn = "urn:adsk.wipprod:dm.lineage:abc"
        let url = api.artifactEndpoint(urn: urn, collectionId: collectionId, fileName: "log.txt")
        #expect(url.absoluteString == base + "/api/jobs/b.project-1/" + urn + "/artifacts/log.txt")
        #expect(url.lastPathComponent == "log.txt")
    }

    /// Artifact names are derived from the exchange's contents, so they are escaped too — a name
    /// with a space in it is not a URL as it stands.
    @Test func escapesTheArtifactFileName() {
        let url = api.artifactEndpoint(
            urn: "urn:adsk.wipprod:dm.lineage:abc",
            collectionId: collectionId,
            fileName: "my model.usdz"
        )
        #expect(url.absoluteString.hasSuffix("/artifacts/my%20model.usdz"))
        #expect(url.lastPathComponent == "my model.usdz")
    }
}
