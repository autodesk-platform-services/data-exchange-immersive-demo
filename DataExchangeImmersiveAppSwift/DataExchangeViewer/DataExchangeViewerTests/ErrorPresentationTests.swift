//
//  ErrorPresentationTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
@testable import DataExchangeViewer

/// Failure messages are rendered verbatim in the UI, so what these errors say — and whether they
/// carry the sentence that says what to do next — is behaviour, not formatting.
@Suite("Error presentation")
struct ErrorPresentationTests {
    /// `localizedDescription` returns only `errorDescription`, so the recovery suggestion written
    /// alongside it never reaches the UI on its own.
    @Test func userFacingDescriptionIncludesTheRecoverySuggestion() {
        let message = ConversionError.unauthorized.userFacingDescription
        #expect(message.contains("Your session expired."))
        #expect(message.contains("Sign in again"))
    }

    /// Not every error is a `LocalizedError`; `URLError` and `DecodingError` come straight out of
    /// `do` blocks and must still produce something readable.
    @Test func userFacingDescriptionFallsBackToFoundationsDescription() {
        let error = URLError(.notConnectedToInternet)
        #expect(error.userFacingDescription == error.localizedDescription)
        #expect(!error.userFacingDescription.isEmpty)
    }

    /// The service answers with an RFC 9457 problem document, whose `detail` is a sentence written
    /// for a person.
    @Test func httpFailuresPreferTheProblemDetailFromTheBody() {
        let body = """
        { "title": "Conversion failed", "detail": "The exchange contains no geometry." }
        """
        let message = ConversionError.http(500, body).localizedDescription
        #expect(message.contains("The exchange contains no geometry."))
    }

    @Test func httpFailuresFallBackToTheProblemTitle() {
        let message = ConversionError.http(500, #"{ "title": "Conversion failed" }"#).localizedDescription
        #expect(message.contains("Conversion failed"))
    }

    /// An unexpected failure can answer with a whole HTML error page, which is not something to
    /// put in front of a person.
    @Test func httpFailuresHideAnUnstructuredBody() {
        let html = "<html><head><title>502 Bad Gateway</title></head><body>…</body></html>"
        let message = ConversionError.http(502, html).localizedDescription
        #expect(!message.contains("<html>"))
        #expect(message.contains("502"))
    }

    @Test func graphQLFailuresReportTheFirstMessage() {
        let error = GraphQLError.graphQL(["Folder not found", "Cannot query field 'exchanges'"])
        #expect(error.localizedDescription == "Folder not found")
    }

    @Test func graphQLFailuresStillSaySomethingWithNoMessages() {
        #expect(!GraphQLError.graphQL([]).localizedDescription.isEmpty)
        #expect(!GraphQLError.noData.localizedDescription.isEmpty)
        #expect(GraphQLError.http(500, "").localizedDescription.contains("500"))
    }

    // MARK: - Session expiry

    /// A rejected token repeats on every subsequent request, so it's worth signing out for rather
    /// than reporting from each screen independently.
    @Test func recognizesARejectedTokenAsAnExpiredSession() {
        #expect(ConversionError.unauthorized.indicatesExpiredSession)
        #expect(GraphQLError.http(401, "").indicatesExpiredSession)
    }

    /// Everything else is a failure of one request, and signing out over it would throw away a
    /// perfectly good session.
    @Test func doesNotTreatOtherFailuresAsAnExpiredSession() {
        #expect(!ConversionError.forbidden.indicatesExpiredSession)
        #expect(!ConversionError.conflict.indicatesExpiredSession)
        #expect(!ConversionError.http(500, "").indicatesExpiredSession)
        #expect(!GraphQLError.http(403, "").indicatesExpiredSession)
        #expect(!GraphQLError.noData.indicatesExpiredSession)
        #expect(!URLError(.timedOut).indicatesExpiredSession)
    }

    /// Both services describe a 403 as a permissions problem rather than a session problem, since
    /// signing in again would not help.
    @Test func distinguishesForbiddenFromExpired() {
        #expect(ConversionError.forbidden.userFacingDescription.contains("access"))
        #expect(GraphQLError.http(403, "").userFacingDescription.contains("access"))
    }
}
