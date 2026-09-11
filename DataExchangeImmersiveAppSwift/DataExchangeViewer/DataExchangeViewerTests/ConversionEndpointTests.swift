//
//  ConversionEndpointTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
@testable import DataExchangeViewer

/// The conversion service identifies a job by the base64url encoding of
/// `"{collectionId}|{exchangeUrn}"`. Getting that wrong is a 404 — or worse, a job ID that decodes
/// to a different exchange — with nothing in the app to explain it.
@Suite("Conversion service endpoints")
struct ConversionEndpointTests {
    private let api = ConversionAPI()
    private let base = ConversionServiceConstants.baseURL.absoluteString
    private let collectionId = "b.project-1"

    // MARK: - Job IDs

    /// The whole point of encoding the pair: base64url uses only characters that are already legal
    /// in a path segment, so nothing downstream has to percent-encode it.
    @Test(arguments: [
        "urn:adsk.wipprod:dm.lineage:pTMcMOe6QIygw-QOgYbxRw",
        "urn:adsk.wipprod:fs.file:vf.pTMcMOe6QIygw-QOgYbxRw?version=3",
        "urn:adsk:a/b+c=d?e#f",
        "plain-urn",
    ])
    func jobIdIsSafeInAPathSegment(urn: String) {
        let jobId = JobID.encode(collectionId: collectionId, exchangeUrn: urn)
        #expect(jobId.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
    }

    /// What the app encodes, the service must decode back character for character.
    @Test(arguments: [
        "urn:adsk.wipprod:dm.lineage:pTMcMOe6QIygw-QOgYbxRw",
        "urn:adsk.wipprod:fs.file:vf.pTMcMOe6QIygw-QOgYbxRw?version=3",
        "urn:adsk:a/b+c=d",
        "plain-urn",
    ])
    func jobIdRoundTripsTheURN(urn: String) throws {
        let jobId = JobID.encode(collectionId: collectionId, exchangeUrn: urn)
        let decoded = try #require(JobID.decode(jobId))
        #expect(decoded.collectionId == collectionId)
        #expect(decoded.exchangeUrn == urn)
    }

    /// A URN may contain the base64 padding and alphabet characters itself, which is exactly the
    /// case that broke when the URN went into the path unencoded.
    @Test func jobIdRoundTripsACollectionIdWithReservedCharacters() throws {
        let jobId = JobID.encode(collectionId: "project&region=US", exchangeUrn: "urn:adsk:abc")
        let decoded = try #require(JobID.decode(jobId))
        #expect(decoded.collectionId == "project&region=US")
        #expect(decoded.exchangeUrn == "urn:adsk:abc")
    }

    /// The separator belongs to the first occurrence, so a URN containing one cannot shift the
    /// split and silently rename the collection.
    @Test func jobIdSplitsOnTheFirstSeparatorOnly() throws {
        let jobId = JobID.encode(collectionId: "b.project-1", exchangeUrn: "urn:adsk:a|b")
        let decoded = try #require(JobID.decode(jobId))
        #expect(decoded.collectionId == "b.project-1")
        #expect(decoded.exchangeUrn == "urn:adsk:a|b")
    }

    @Test(arguments: ["", "!!!not-base64!!!", "YQ"])
    func rejectsTextThatIsNotAJobId(jobId: String) {
        // "YQ" decodes to "a" — valid base64url, but no separator and so no exchange.
        #expect(JobID.decode(jobId) == nil)
    }

    @Test func rejectsAJobIdWithAnEmptyHalf() {
        #expect(JobID.decode(JobID.encode(collectionId: "", exchangeUrn: "urn:adsk:abc")) == nil)
        #expect(JobID.decode(JobID.encode(collectionId: "b.project-1", exchangeUrn: "")) == nil)
    }

    // MARK: - URLs

    @Test func buildsTheJobEndpoint() {
        let urn = "urn:adsk.wipprod:dm.lineage:pTMcMOe6QIygw-QOgYbxRw"
        let jobId = JobID.encode(collectionId: collectionId, exchangeUrn: urn)
        #expect(api.endpoint(urn: urn, collectionId: collectionId).absoluteString == base + "/api/jobs/" + jobId)
    }

    /// No `%` anywhere in the URL: there is nothing left in it that needs escaping, which is what
    /// makes `appendingPathComponent` safe to use on the result.
    @Test func doesNotPercentEncodeAnything() {
        let url = api.endpoint(urn: "urn:adsk.wipprod:fs.file:vf.abc?version=3", collectionId: collectionId)
        #expect(!url.absoluteString.contains("%"))
    }

    /// The log is a sub-resource of the job, not one of its artifacts.
    @Test func buildsTheLogEndpoint() {
        let urn = "urn:adsk.wipprod:dm.lineage:abc"
        let jobId = JobID.encode(collectionId: collectionId, exchangeUrn: urn)
        #expect(api.logEndpoint(urn: urn, collectionId: collectionId).absoluteString
            == base + "/api/jobs/" + jobId + "/log")
    }

    @Test func appendsTheArtifactFileNameUnderArtifacts() {
        let urn = "urn:adsk.wipprod:dm.lineage:abc"
        let jobId = JobID.encode(collectionId: collectionId, exchangeUrn: urn)
        let url = api.artifactEndpoint(urn: urn, collectionId: collectionId, fileName: "log.txt")
        #expect(url.absoluteString == base + "/api/jobs/" + jobId + "/artifacts/log.txt")
        #expect(url.lastPathComponent == "log.txt")
    }
}
