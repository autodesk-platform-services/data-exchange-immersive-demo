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
    private func artifact(name: String, type: String, size: Int64 = 0) -> ConversionArtifact {
        ConversionArtifact(
            name: name,
            type: type,
            contentType: "application/octet-stream",
            size: size,
            checksum: nil,
            url: nil
        )
    }

    private func metadata(
        status: ConversionStatusValue,
        artifacts: [ConversionArtifact] = [],
        error: String? = nil,
        createdAt: Date? = nil,
        startedAt: Date? = nil
    ) -> ConversionMetadata {
        ConversionMetadata(
            status: status,
            artifacts: artifacts,
            error: error,
            fileVersionUrn: nil,
            currentFileVersionUrn: nil,
            logUrl: nil,
            createdAt: createdAt,
            startedAt: startedAt,
            updatedAt: nil,
            completedAt: nil
        )
    }

    // MARK: - Metadata

    @Test func decodesACompletedConversion() throws {
        let json = """
        {
          "status": "completed",
          "artifacts": [
            {
              "name": "model.usdz",
              "type": "usdz",
              "contentType": "model/vnd.usdz+zip",
              "size": 184320000,
              "checksum": "sha256:abc",
              "url": "https://example.test/api/jobs/abc/artifacts/model.usdz?secret=s3cr3t"
            },
            { "name": "model.glb", "type": "glb", "contentType": "model/gltf-binary", "size": 512, "checksum": null }
          ],
          "error": null,
          "logUrl": "https://example.test/api/jobs/abc/log?secret=s3cr3t"
        }
        """
        let metadata = try JSONDecoder().decode(ConversionMetadata.self, from: Data(json.utf8))
        #expect(metadata.status == .completed)
        #expect(metadata.artifacts.map(\.name) == ["model.usdz", "model.glb"])
        #expect(metadata.logUrl == "https://example.test/api/jobs/abc/log?secret=s3cr3t")
        #expect(metadata.artifacts.first?.size == 184_320_000)
        #expect(metadata.artifacts.first?.contentType == "model/vnd.usdz+zip")
        #expect(metadata.artifacts.first?.checksum == "sha256:abc")
        #expect(metadata.artifacts.first?.url == "https://example.test/api/jobs/abc/artifacts/model.usdz?secret=s3cr3t")
        // Absent for a conversion made before the service issued presigned URLs.
        #expect(metadata.artifacts.last?.url == nil)
        #expect(metadata.artifacts.last?.checksum == nil)
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

    /// A conversion of a version the exchange has moved past. Previously a 404, indistinguishable
    /// from an exchange nobody had ever converted.
    @Test func decodesASupersededConversion() throws {
        let json = """
        {
          "status": "superseded",
          "artifacts": [],
          "error": null,
          "fileVersionUrn": "urn:adsk.wipprod:fs.file:vf.abc?version=2",
          "currentFileVersionUrn": "urn:adsk.wipprod:fs.file:vf.abc?version=3"
        }
        """
        let metadata = try JSONDecoder.conversionService.decode(ConversionMetadata.self, from: Data(json.utf8))
        #expect(metadata.status == .superseded)
        #expect(metadata.fileVersionUrn == "urn:adsk.wipprod:fs.file:vf.abc?version=2")
        #expect(metadata.currentFileVersionUrn == "urn:adsk.wipprod:fs.file:vf.abc?version=3")
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

    @Test func decodesTheServiceTimestamps() throws {
        let json = """
        {
          "status": "running",
          "artifacts": [],
          "error": null,
          "createdAt": "2026-09-10T12:00:00Z",
          "startedAt": "2026-09-10T12:00:01Z",
          "updatedAt": "2026-09-10T12:04:12Z",
          "completedAt": null
        }
        """
        let metadata = try JSONDecoder.conversionService.decode(ConversionMetadata.self, from: Data(json.utf8))
        #expect(metadata.createdAt == Date(timeIntervalSince1970: 1_789_041_600))
        #expect(metadata.startedAt == Date(timeIntervalSince1970: 1_789_041_601))
        #expect(metadata.updatedAt == Date(timeIntervalSince1970: 1_789_041_852))
        #expect(metadata.completedAt == nil)
    }

    /// A conversion that has not begun yet still has a creation time to measure the wait from.
    @Test func fallsBackToTheCreationTimeBeforeTheConversionStarts() {
        let created = Date(timeIntervalSince1970: 1_789_041_600)
        #expect(metadata(status: .running, createdAt: created).startedOrCreatedAt == created)

        let started = created.addingTimeInterval(1)
        #expect(metadata(status: .running, createdAt: created, startedAt: started).startedOrCreatedAt == started)
        #expect(metadata(status: .running).startedOrCreatedAt == nil)
    }

    // MARK: - Artifact selection

    /// Selection is by `type`, not by file-name suffix: the names come from the exchange's
    /// contents and are not predictable, and an exchange called `Plans.usdz.rvt` should not be
    /// mistaken for a model.
    @Test func findsTheUSDZAmongTheArtifacts() {
        let metadata = metadata(
            status: .completed,
            artifacts: [
                artifact(name: "Basement.mtl", type: "mtl"),
                artifact(name: "Basement.obj", type: "obj"),
                artifact(name: "Basement.usdz", type: "usdz", size: 1_024),
            ]
        )
        #expect(ConversionAPI.findArtifact(metadata, type: ArtifactType.usdz)?.name == "Basement.usdz")
        #expect(ConversionAPI.findArtifact(metadata, type: ArtifactType.usdz)?.size == 1_024)
        #expect(ConversionAPI.findArtifact(metadata, type: "obj")?.name == "Basement.obj")
    }

    /// A conversion that reports success without producing a model is a failure the detail view
    /// has to explain, so this must not return something unusable.
    @Test func reportsNoUSDZWhenTheConversionProducedNone() {
        let metadata = metadata(status: .completed, artifacts: [artifact(name: "Basement.obj", type: "obj")])
        #expect(ConversionAPI.findArtifact(metadata, type: ArtifactType.usdz) == nil)
        #expect(ConversionAPI.findArtifact(nil, type: ArtifactType.usdz) == nil)
    }

    // MARK: - Progress

    /// The service publishes no completion percentage, so the conversion phase is reported as
    /// elapsed time rather than as a progress bar stuck at zero.
    @Test func reportsNoFractionWhileConverting() {
        let activity = ConversionActivity(since: Date())
        #expect(activity.fractionCompleted == nil)
    }

    /// The service declares the artifact size in the status, so the bar is determinate before any
    /// bytes arrive — it used to sit at "unknown" until the response headers landed.
    @Test func reportsProgressFromTheDeclaredSizeBeforeAnyBytesArrive() {
        var activity = ConversionActivity(since: Date())
        activity.phase = .downloading(receivedBytes: 0, totalBytes: 184_320_000)
        #expect(activity.fractionCompleted == 0)
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
