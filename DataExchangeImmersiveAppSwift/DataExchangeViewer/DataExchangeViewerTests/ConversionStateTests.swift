//
//  ConversionStateTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
@testable import DataExchangeViewer

/// What the app makes of the conversion service's answers: the metadata document, which artifact
/// to download, and what to show while waiting.
@Suite("Conversion state")
struct ConversionStateTests {
    // MARK: - Metadata

    @Test func decodesACompletedConversion() throws {
        let json = """
        { "status": "completed", "artifacts": ["model.usdz", "log.txt"], "error": null }
        """
        let metadata = try JSONDecoder().decode(ConversionMetadata.self, from: Data(json.utf8))
        #expect(metadata.status == .completed)
        #expect(metadata.artifacts == ["model.usdz", "log.txt"])
        #expect(metadata.error == nil)
    }

    @Test func decodesAFailedConversionWithItsMessage() throws {
        let json = """
        { "status": "failed", "artifacts": [], "error": "Unsupported geometry" }
        """
        let metadata = try JSONDecoder().decode(ConversionMetadata.self, from: Data(json.utf8))
        #expect(metadata.status == .failed)
        #expect(metadata.error == "Unsupported geometry")
    }

    /// A status the app doesn't know is a decoding failure rather than a silently mis-mapped
    /// state, so it surfaces as an error instead of a conversion that never finishes.
    @Test func rejectsAnUnknownStatus() {
        let json = """
        { "status": "queued", "artifacts": [], "error": null }
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ConversionMetadata.self, from: Data(json.utf8))
        }
    }

    // MARK: - Artifact selection

    @Test func findsTheUSDZAmongTheArtifacts() {
        let metadata = ConversionMetadata(
            status: .completed,
            artifacts: ["log.txt", "metadata.json", "Basement.usdz"],
            error: nil
        )
        #expect(ConversionAPI.findArtifact(metadata, extension: ".usdz") == "Basement.usdz")
        #expect(ConversionAPI.findArtifact(metadata, extension: ".txt") == "log.txt")
    }

    /// A conversion that reports success without producing a model is a failure the detail view
    /// has to explain, so this must not return something unusable.
    @Test func reportsNoUSDZWhenTheConversionProducedNone() {
        let metadata = ConversionMetadata(status: .completed, artifacts: ["log.txt"], error: nil)
        #expect(ConversionAPI.findArtifact(metadata, extension: ".usdz") == nil)
        #expect(ConversionAPI.findArtifact(nil, extension: ".usdz") == nil)
    }

    // MARK: - Progress

    /// The service publishes no completion percentage, so the conversion phase is reported as
    /// elapsed time rather than as a progress bar stuck at zero.
    @Test func reportsNoFractionWhileConverting() {
        let activity = ConversionActivity(since: Date())
        #expect(activity.fractionCompleted == nil)
    }

    @Test func reportsNoFractionForADownloadOfUnknownLength() {
        var activity = ConversionActivity(since: Date())
        activity.phase = .downloading(receivedBytes: 1_000, totalBytes: nil)
        #expect(activity.fractionCompleted == nil)

        activity.phase = .downloading(receivedBytes: 1_000, totalBytes: 0)
        #expect(activity.fractionCompleted == nil)
    }

    @Test func reportsDownloadProgressAsAFraction() throws {
        var activity = ConversionActivity(since: Date())
        activity.phase = .downloading(receivedBytes: 25, totalBytes: 100)
        #expect(try #require(activity.fractionCompleted) == 0.25)
    }

    /// A `Content-Length` that undercounts the body — or a range response the service extends —
    /// must not drive a progress bar past full.
    @Test func clampsProgressToOne() throws {
        var activity = ConversionActivity(since: Date())
        activity.phase = .downloading(receivedBytes: 150, totalBytes: 100)
        #expect(try #require(activity.fractionCompleted) == 1)
    }
}
