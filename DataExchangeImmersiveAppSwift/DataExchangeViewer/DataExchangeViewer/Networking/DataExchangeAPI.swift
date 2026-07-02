//
//  DataExchangeAPI.swift
//  DataExchangeViewer
//

import Foundation

// Known limitations (matching/slightly improving on the DataExchangeImmersiveAppWeb reference app):
// - Folder recursion is bounded at `folderRecursionDepth`, not unbounded; exchanges nested deeper are omitted.
// - No pagination: only the first page of hubs/projects/exchanges results is fetched. The schema exposes
//   `pagination { cursor }` but nothing here consumes it.
struct DataExchangeAPI {
    private let client = GraphQLClient()
    private let folderRecursionDepth = 5

    func hubs(token: String) async throws -> [Hub] {
        let query = "query { hubs { results { id name } } }"
        struct HubsData: Decodable { let hubs: Results<Hub> }
        let data: HubsData = try await client.execute(query, token: token)
        return data.hubs.results.filter { !$0.name.hasPrefix("Team Hub") }
    }

    func projects(token: String, hubId: String) async throws -> [Project] {
        let query = "query { projects(hubId: \"\(hubId)\") { results { id name } } }"
        struct ProjectsData: Decodable { let projects: Results<Project> }
        let data: ProjectsData = try await client.execute(query, token: token)
        return data.projects.results
    }

    func exchanges(token: String, projectId: String) async throws -> [Exchange] {
        let query = """
        query {
          project(projectId: \"\(projectId)\") {
            folders {
              results {
                \(Self.folderFragment(depth: folderRecursionDepth - 1))
              }
            }
          }
        }
        """
        struct ProjectData: Decodable { let project: ProjectWrapper? }
        struct ProjectWrapper: Decodable { let folders: Results<RawFolder>? }
        let data: ProjectData = try await client.execute(query, token: token)
        let topFolders = data.project?.folders?.results ?? []
        return topFolders.flatMap(Self.flatten)
    }

    private static func folderFragment(depth: Int) -> String {
        let exchangesFragment = "exchanges { results { id name alternativeRepresentations { fileUrn fileVersionUrn } } }"
        guard depth > 0 else { return exchangesFragment }
        return "\(exchangesFragment) folders { results { \(folderFragment(depth: depth - 1)) } }"
    }

    private static func flatten(_ folder: RawFolder) -> [Exchange] {
        var result: [Exchange] = []
        for raw in folder.exchanges?.results ?? [] {
            guard let fileUrn = raw.alternativeRepresentations?.fileUrn else { continue }
            let fileVersionUrn = raw.alternativeRepresentations?.fileVersionUrn ?? fileUrn
            result.append(Exchange(id: raw.id, name: raw.name, fileUrn: fileUrn, fileVersionUrn: fileVersionUrn))
        }
        for subfolder in folder.folders?.results ?? [] {
            result.append(contentsOf: flatten(subfolder))
        }
        return result
    }
}

private struct RawExchange: Decodable {
    let id: String
    let name: String
    let alternativeRepresentations: AltReps?

    struct AltReps: Decodable {
        let fileUrn: String?
        let fileVersionUrn: String?
    }
}

// Decodable conformance is written by hand: the compiler's *synthesized* conformance can't
// resolve the two-hop cycle RawFolder -> Results<RawFolder> -> RawFolder ("circular reference"),
// even as a class. A manual init(from:) sidesteps synthesis entirely and compiles fine.
private final class RawFolder: Decodable {
    let exchanges: Results<RawExchange>?
    let folders: Results<RawFolder>?

    private enum CodingKeys: String, CodingKey {
        case exchanges, folders
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        exchanges = try container.decodeIfPresent(Results<RawExchange>.self, forKey: .exchanges)
        folders = try container.decodeIfPresent(Results<RawFolder>.self, forKey: .folders)
    }
}
