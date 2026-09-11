// Client for the DataExchangeConversionService, which converts a data exchange into
// downloadable GLB and USDZ artifacts. Every request forwards the same 3-legged APS token
// as a bearer token; the service uses it both to authorize and to download the exchange.

const DEFAULT_BASE_URL = "https://data-exchange-conversion-service.azurewebsites.net";

// The backend can be overridden with a `?service=<url>` query parameter, e.g. for pointing
// at a local or staging deployment.
const BASE_URL = (
  new URL(window.location.href).searchParams.get("service") ?? DEFAULT_BASE_URL
).replace(/\/+$/, "");

// One file produced by a conversion. The service describes each artifact rather than just naming
// it, so a caller selects one by `type` instead of matching a file-name suffix, and knows the
// download size before the first byte arrives.
export interface ConversionArtifact {
  name: string;
  type: "obj" | "mtl" | "glb" | "usdz" | "log" | "unknown";
  contentType: string;
  size: number;
  checksum?: string | null;
  // Absolute URL carrying the job's secret, so it needs no Authorization header and can be given
  // straight to a `src` attribute. Absent only for a conversion produced by an older build of the
  // service, which is why callers still fall back to an authenticated fetch.
  url?: string | null;
}

export interface ConversionStatus {
  // "superseded" means the conversion finished, but of a version the exchange has since moved past:
  // its artifacts are not served and a new conversion is what resolves it. Previously reported as a
  // 404, indistinguishable from an exchange nobody had ever converted.
  status: "running" | "completed" | "failed" | "superseded";
  artifacts: ConversionArtifact[];
  error?: string | null;
  // The version the artifacts were produced from, and — when superseded — the version the exchange
  // is at now.
  fileVersionUrn?: string | null;
  currentFileVersionUrn?: string | null;
  // ISO 8601, UTC, second resolution (e.g. "2026-09-10T12:04:12Z"). `updatedAt` advances at every
  // step of the pipeline, so a `running` job whose `updatedAt` has stopped moving is one whose
  // conversion process is gone.
  createdAt?: string | null;
  startedAt?: string | null;
  updatedAt?: string | null;
  completedAt?: string | null;
}

// How long a conversion has been running, or how long it took. Returns null when the service
// reported no timestamps — a conversion written by an older build of the service.
export function conversionDuration(status: ConversionStatus, now: number = Date.now()): number | null {
  const start = status.startedAt ?? status.createdAt;
  if (!start) return null;
  const end = status.completedAt ? Date.parse(status.completedAt) : now;
  return Math.max(0, end - Date.parse(start));
}

// The service addresses a conversion job by one path segment: the base64url encoding of
// `"{collectionId}|{exchangeUrn}"`. The job ID is derived from the pair rather than handed out by
// the service, so it can be computed before any job exists — and because base64url uses only
// characters that are already legal in a path, nothing here needs percent-encoding.
export function jobId(collectionId: string, urn: string): string {
  // `btoa` takes a string of code points below 256, so the text is encoded to UTF-8 bytes first.
  // Collection IDs and URNs are ASCII in practice, but a stray non-ASCII character should produce
  // a wrong-looking job ID rather than throw from inside a fetch.
  const utf8 = new TextEncoder().encode(`${collectionId}|${urn}`);
  return btoa(String.fromCharCode(...utf8))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function jobEndpoint(urn: string, collectionId: string): string {
  return `${BASE_URL}/api/jobs/${jobId(collectionId, urn)}`;
}

// Kicks off a conversion. The service responds 202 Accepted and runs the work in the background.
export async function startConversion(token: string, urn: string, collectionId: string): Promise<void> {
  const response = await fetch(jobEndpoint(urn, collectionId), {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!response.ok) {
    throw new Error(`Failed to start conversion: ${response.status} ${await response.text()}`);
  }
}

// Deletes the results of a previous conversion so a new one can be started for this exchange.
export async function deleteConversion(token: string, urn: string, collectionId: string): Promise<void> {
  const response = await fetch(jobEndpoint(urn, collectionId), {
    method: "DELETE",
    headers: { Authorization: `Bearer ${token}` },
  });
  if (!response.ok) {
    throw new Error(`Failed to delete conversion: ${response.status} ${await response.text()}`);
  }
}

// Returns the current conversion status, or null if no conversion has been started for this exchange.
export async function getStatus(token: string, urn: string, collectionId: string): Promise<ConversionStatus | null> {
  const response = await fetch(jobEndpoint(urn, collectionId), { headers: { Authorization: `Bearer ${token}` } });
  if (response.status === 404) {
    return null;
  }
  if (!response.ok) {
    throw new Error(`Failed to get status: ${response.status} ${await response.text()}`);
  }
  return (await response.json()) as ConversionStatus;
}

async function fetchArtifact(token: string, urn: string, collectionId: string, fileName: string): Promise<Response> {
  const response = await fetch(
    `${jobEndpoint(urn, collectionId)}/artifacts/${encodeURIComponent(fileName)}`,
    {
      headers: { Authorization: `Bearer ${token}` },
    },
  );
  if (!response.ok) {
    throw new Error(`Failed to fetch artifact ${fileName}: ${response.status}`);
  }
  return response;
}

// Downloads a text artifact (e.g. log.txt) and returns its contents as a string.
export async function fetchArtifactText(
  token: string,
  urn: string,
  collectionId: string,
  fileName: string,
): Promise<string> {
  return (await fetchArtifact(token, urn, collectionId, fileName)).text();
}

// Picks the first artifact of the given type (e.g. "glb", "usdz"), or undefined. Selection is by
// type rather than by file name, which is derived from the exchange's contents and unpredictable.
export function findArtifact(
  status: ConversionStatus | null | undefined,
  type: ConversionArtifact["type"],
): ConversionArtifact | undefined {
  return status?.artifacts.find((artifact) => artifact.type === type);
}
