//
//  DataExchangeAPI.swift
//  DataExchangeViewer
//

import Foundation

/// What a project's exchange listing turned up, plus what it could not reach.
///
/// The second half matters: without it, an exchange that exists but isn't shown is
/// indistinguishable from one that doesn't exist.
struct ExchangeListing {
    var exchanges: [Exchange] = []
    /// Folders whose exchange list the service split across pages. `Folder.exchanges` takes no
    /// pagination argument in the published schema, so the remaining pages can't be requested —
    /// naming the folder is the honest alternative to dropping them silently.
    var partialFolders: [String] = []
    /// Set when the folder budget ran out before the whole tree had been walked.
    var reachedFolderLimit = false

    var isComplete: Bool { partialFolders.isEmpty && !reachedFolderLimit }
}

struct DataExchangeAPI {
    private let client = GraphQLClient()

    /// Cap on the number of folders whose subfolders are looked up while walking a project. Folder
    /// depth itself is unbounded, so this is what stops a pathological tree from turning one list
    /// into thousands of requests. Truncation here is reported, not hidden.
    private static let folderVisitBudget = 300

    /// Subfolder lookups within one level of the tree run a few at a time. One request per folder
    /// strictly in sequence would make a project with dozens of folders wait out a serial chain of
    /// round trips; running the whole level at once would fan out unboundedly instead.
    private static let folderRequestConcurrency = 6

    func hubs(token: String) async throws -> [Hub] {
        // Every hub the token can reach is listed. The schema exposes no attribute that marks a
        // personal hub with no exchanges in it, and filtering on the name would also hide a hub
        // genuinely named that, so a hub with no Data Exchange projects shows an empty project
        // list instead — which at least says so.
        let query = """
        query GetHubs($cursor: String) {
          hubs(pagination: { cursor: $cursor }) {
            pagination { cursor }
            results { id name }
          }
        }
        """
        struct HubsData: Decodable { let hubs: Results<Hub>? }
        return try await client.paginate(query, token: token) { (data: HubsData) in data.hubs }
    }

    func projects(token: String, hubId: String) async throws -> [Project] {
        let query = """
        query GetProjects($hubId: ID!, $cursor: String) {
          projects(hubId: $hubId, pagination: { cursor: $cursor }) {
            pagination { cursor }
            results { id name }
          }
        }
        """
        struct ProjectsData: Decodable { let projects: Results<Project>? }
        return try await client.paginate(
            query,
            variables: ["hubId": hubId],
            token: token
        ) { (data: ProjectsData) in data.projects }
    }

    /// Walks a project's folder tree breadth-first, collecting the exchanges in every folder.
    ///
    /// Discovering each level with its own `folders` query costs more round trips than one query
    /// built from a recursive GraphQL fragment, but it has no depth limit — a fragment has to be
    /// nested to a fixed bound, and grows exponentially with it — and it can follow the pagination
    /// cursor.
    func exchanges(token: String, projectId: String) async throws -> ExchangeListing {
        var listing = ExchangeListing()
        var seenFolderIDs: Set<String> = []
        var visitedFolderCount = 0

        /// Takes a folder's exchanges and queues the folder for subfolder discovery.
        func absorb(_ folder: RawFolder) {
            for raw in folder.exchanges?.results ?? [] {
                if let exchange = raw.exchange(in: projectId) {
                    listing.exchanges.append(exchange)
                }
            }
            if folder.exchanges?.isTruncated == true {
                listing.partialFolders.append(folder.displayName)
            }
        }

        let topFolders = try await self.topFolders(token: token, projectId: projectId)
        if topFolders.isTruncated {
            listing.partialFolders.append("this project's top-level folders")
        }
        var frontier: [RawFolder] = []
        for folder in topFolders.results where seenFolderIDs.insert(folder.id).inserted {
            absorb(folder)
            frontier.append(folder)
        }

        while !frontier.isEmpty {
            var nextFrontier: [RawFolder] = []
            for chunk in frontier.chunks(of: Self.folderRequestConcurrency) {
                guard visitedFolderCount < Self.folderVisitBudget else {
                    listing.reachedFolderLimit = true
                    return listing
                }
                visitedFolderCount += chunk.count

                let children = try await withThrowingTaskGroup(of: [RawFolder].self) { group in
                    for folder in chunk {
                        group.addTask { try await self.subfolders(token: token, folderId: folder.id) }
                    }
                    var all: [RawFolder] = []
                    for try await result in group {
                        all.append(contentsOf: result)
                    }
                    return all
                }

                for child in children where seenFolderIDs.insert(child.id).inserted {
                    absorb(child)
                    nextFrontier.append(child)
                }
            }
            frontier = nextFrontier
        }

        return listing
    }

    /// `topFolders` is the only listing query in the schema that takes no `pagination` argument,
    /// so its cursor can only be reported, not followed. Projects have very few top folders.
    private func topFolders(token: String, projectId: String) async throws -> Results<RawFolder> {
        let query = """
        query GetTopFolders($projectId: ID!) {
          topFolders(projectId: $projectId) {
            pagination { cursor }
            results { \(Self.folderFields) }
          }
        }
        """
        struct TopFoldersData: Decodable { let topFolders: Results<RawFolder>? }
        let data: TopFoldersData = try await client.execute(
            query,
            variables: ["projectId": projectId],
            token: token
        )
        return data.topFolders ?? Results(results: [], pagination: nil)
    }

    /// One level down from `folderId`, with each subfolder's own exchanges included so a folder's
    /// contents are never fetched twice.
    private func subfolders(token: String, folderId: String) async throws -> [RawFolder] {
        let query = """
        query GetFolders($folderId: ID!, $cursor: String) {
          folders(folderId: $folderId, pagination: { cursor: $cursor }) {
            pagination { cursor }
            results { \(Self.folderFields) }
          }
        }
        """
        struct FoldersData: Decodable { let folders: Results<RawFolder>? }
        return try await client.paginate(
            query,
            variables: ["folderId": folderId],
            token: token
        ) { (data: FoldersData) in data.folders }
    }

    private static let folderFields = """
    id
    name
    exchanges {
      pagination { cursor }
      results { id name alternativeIdentifiers { fileUrn fileVersionUrn } }
    }
    """
}

private struct RawFolder: Decodable {
    let id: String
    let name: String?
    let exchanges: Results<RawExchange>?

    /// Used only to name the folder in a truncation notice.
    var displayName: String { name ?? "an unnamed folder" }
}

private struct RawExchange: Decodable {
    let id: String
    let name: String
    let alternativeIdentifiers: AltIdentifiers?

    struct AltIdentifiers: Decodable {
        let fileUrn: String?
        let fileVersionUrn: String?
    }

    /// Nil for an exchange with no file URN: nothing can be converted or previewed without one,
    /// so listing it would only offer a row that fails when tapped.
    func exchange(in projectId: String) -> Exchange? {
        guard let fileUrn = alternativeIdentifiers?.fileUrn, !fileUrn.isEmpty else { return nil }
        return Exchange(
            id: id,
            name: name,
            projectId: projectId,
            fileUrn: fileUrn,
            fileVersionUrn: alternativeIdentifiers?.fileVersionUrn ?? ""
        )
    }
}

private extension Array {
    /// Splits into consecutive slices of at most `size` elements, for capping how many requests
    /// are in flight at once.
    func chunks(of size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
