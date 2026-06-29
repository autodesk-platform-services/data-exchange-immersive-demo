// Calls into the APS Data Exchange GraphQL API. All data — hubs, projects and
// exchanges — comes from this single GraphQL endpoint; no Data Management REST calls are needed.
//
// Schema notes (confirmed against the official APS fdxgraph tutorial and Node sample):
//  - Connection types wrap their items in a `results` array (not Relay edges/node).
//  - `projects` takes a plain `hubId` string argument.
//  - Exchanges live under folders: project -> folders -> exchanges.
//  - The exchange's file/lineage URN is exposed via `alternativeRepresentations`, NOT an
//    `attributes { exchangeFileUrn }` object.

const GRAPHQL_URL = "https://developer.api.autodesk.com/dataexchange/2023-05/graphql";

export interface Hub {
  id: string;
  name: string;
}

export interface Project {
  id: string;
  name: string;
}

export interface Exchange {
  id: string;
  name: string;
  // Lineage (file) URN — forwarded to the conversion service and used to look the exchange up.
  fileUrn: string;
  // Specific version URN — what the APS Viewer loads via Model Derivative.
  fileVersionUrn: string;
}

interface Results<T> {
  results: T[];
}

async function graphql<T>(token: string, query: string): Promise<T> {
  const response = await fetch(GRAPHQL_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ query }),
  });
  if (!response.ok) {
    throw new Error(`GraphQL request failed: ${response.status} ${await response.text()}`);
  }
  const payload = (await response.json()) as { data?: T; errors?: { message: string }[] };
  if (payload.errors?.length) {
    throw new Error(`GraphQL error: ${payload.errors.map((e) => e.message).join("; ")}`);
  }
  if (!payload.data) {
    throw new Error("GraphQL response contained no data.");
  }
  return payload.data;
}

export async function getHubs(token: string): Promise<Hub[]> {
  const data = await graphql<{ hubs: Results<Hub> }>(
    token,
    `query { hubs { results { id name } } }`,
  );
  return data.hubs.results;
}

export async function getProjects(token: string, hubId: string): Promise<Project[]> {
  const data = await graphql<{ projects: Results<Project> }>(
    token,
    `query { projects(hubId: ${JSON.stringify(hubId)}) { results { id name } } }`,
  );
  return data.projects.results;
}

interface RawExchange {
  id: string;
  name: string;
  alternativeRepresentations?: { fileUrn?: string; fileVersionUrn?: string } | null;
}

interface RawFolder {
  exchanges?: Results<RawExchange> | null;
  folders?: Results<RawFolder> | null;
}

// Collects every exchange found in a folder and (recursively) its sub-folders.
function flattenExchanges(folder: RawFolder): Exchange[] {
  const here = (folder.exchanges?.results ?? []).map((exchange) => ({
    id: exchange.id,
    name: exchange.name,
    fileUrn: exchange.alternativeRepresentations?.fileUrn ?? "",
    fileVersionUrn: exchange.alternativeRepresentations?.fileVersionUrn ?? "",
  }));
  const nested = (folder.folders?.results ?? []).flatMap(flattenExchanges);
  return [...here, ...nested];
}

export async function getExchanges(token: string, projectId: string): Promise<Exchange[]> {
  // The query walks two levels of folders, which covers the typical project layout for the demo.
  const exchangeFields = `
    exchanges {
      results {
        id
        name
        alternativeRepresentations { fileUrn fileVersionUrn }
      }
    }`;
  const data = await graphql<{ project: { folders: Results<RawFolder> } }>(
    token,
    `query {
      project(projectId: ${JSON.stringify(projectId)}) {
        folders {
          results {
            ${exchangeFields}
            folders {
              results {
                ${exchangeFields}
              }
            }
          }
        }
      }
    }`,
  );
  return data.project.folders.results.flatMap(flattenExchanges);
}
