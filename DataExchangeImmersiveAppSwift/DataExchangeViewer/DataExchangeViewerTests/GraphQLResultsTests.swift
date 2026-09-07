//
//  GraphQLResultsTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
@testable import DataExchangeViewer

/// One page of a Data Exchange connection. `isTruncated` is what the exchange list uses to tell
/// "there is nothing more" apart from "there is more and the schema gives me no way to ask for
/// it", which is the difference between a complete listing and a silently partial one.
@Suite("GraphQL results")
struct GraphQLResultsTests {
    @Test func decodesAPageAndItsCursor() throws {
        let json = """
        {
          "pagination": { "cursor": "page-2" },
          "results": [{ "id": "h1", "name": "Autodesk Hub" }]
        }
        """
        let page = try JSONDecoder().decode(Results<Hub>.self, from: Data(json.utf8))
        #expect(page.results.map(\.id) == ["h1"])
        #expect(page.nextCursor == "page-2")
        #expect(page.isTruncated)
    }

    @Test func treatsANullCursorAsTheLastPage() throws {
        let json = """
        { "pagination": { "cursor": null }, "results": [] }
        """
        let page = try JSONDecoder().decode(Results<Hub>.self, from: Data(json.utf8))
        #expect(page.nextCursor == nil)
        #expect(!page.isTruncated)
    }

    /// Nested `exchanges` connections are read without asking for pagination at all, so the whole
    /// field is absent from the response.
    @Test func treatsAMissingPaginationFieldAsTheLastPage() throws {
        let json = """
        { "results": [{ "id": "p1", "name": "Tower" }] }
        """
        let page = try JSONDecoder().decode(Results<Project>.self, from: Data(json.utf8))
        #expect(page.results.count == 1)
        #expect(!page.isTruncated)
    }

    @Test func decodesAnExchangeWithItsLineageAndVersionURNs() throws {
        let json = """
        {
          "id": "e1",
          "name": "Basement",
          "fileUrn": "urn:lineage:abc",
          "fileVersionUrn": "urn:version:abc:3"
        }
        """
        let exchange = try JSONDecoder().decode(Exchange.self, from: Data(json.utf8))
        #expect(exchange.exchangeUrn == "urn:lineage:abc")
        #expect(exchange.cacheKeyUrn == "urn:version:abc:3")
    }

    // MARK: - Listing completeness

    @Test func anEmptyListingIsStillComplete() {
        #expect(ExchangeListing().isComplete)
    }

    /// Both kinds of truncation have to make the listing announce itself as partial: a folder
    /// whose `exchanges` field ran to a second page, and a folder tree that exhausted the visit
    /// budget before it was fully walked.
    @Test func reportsAPartialListing() {
        var byPage = ExchangeListing()
        byPage.partialFolders = ["Drawings"]
        #expect(!byPage.isComplete)

        var byBudget = ExchangeListing()
        byBudget.reachedFolderLimit = true
        #expect(!byBudget.isComplete)
    }

    // MARK: - Load state

    /// The sidebar used to claim "No hubs found" while the request was still in flight, because an
    /// empty array and a pending load looked identical.
    @Test func loadStateOnlyYieldsAValueWhenLoaded() {
        #expect(LoadState<[Hub]>.loading.value == nil)
        #expect(LoadState<[Hub]>.failed("nope").value == nil)
        #expect(LoadState.loaded([Hub(id: "h1", name: "Autodesk Hub")]).value?.count == 1)
        // Genuinely empty, and distinguishable from not-yet-loaded.
        #expect(LoadState<[Hub]>.loaded([]).value?.isEmpty == true)
    }
}
