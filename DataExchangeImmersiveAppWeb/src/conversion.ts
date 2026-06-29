// Client for the DataExchangeConversionService, which converts a data exchange into
// downloadable GLB and USDZ artifacts. Every request forwards the same 3-legged APS token
// as a bearer token; the service uses it both to authorize and to download the exchange.

const BASE_URL = "https://data-exchange-viewing-service.azurewebsites.net";

export interface ConversionStatus {
  status: "running" | "completed" | "failed";
  artifacts: string[];
  error?: string | null;
}

function authHeaders(token: string): HeadersInit {
  return { Authorization: `Bearer ${token}` };
}

// The exchange URN contains characters (':', '/', etc.) that must be escaped to fit in a path segment.
function exchangeEndpoint(urn: string): string {
  return `${BASE_URL}/api/exchanges/${encodeURIComponent(urn)}`;
}

// Kicks off a conversion. The service responds 202 Accepted and runs the work in the background.
export async function startConversion(token: string, urn: string): Promise<void> {
  const response = await fetch(exchangeEndpoint(urn), {
    method: "POST",
    headers: authHeaders(token),
  });
  if (!response.ok) {
    throw new Error(`Failed to start conversion: ${response.status} ${await response.text()}`);
  }
}

// Returns the current conversion status, or null if no conversion has been started for this exchange.
export async function getStatus(token: string, urn: string): Promise<ConversionStatus | null> {
  const response = await fetch(exchangeEndpoint(urn), { headers: authHeaders(token) });
  if (response.status === 404) {
    return null;
  }
  if (!response.ok) {
    throw new Error(`Failed to get status: ${response.status} ${await response.text()}`);
  }
  return (await response.json()) as ConversionStatus;
}

// Downloads a single artifact and returns an object URL. The <model-viewer>/<model> `src`
// attributes cannot send an Authorization header, so we fetch the bytes here and hand the
// elements a blob URL instead. Callers must revokeObjectUrl() the result when done.
export async function fetchArtifactBlob(
  token: string,
  urn: string,
  fileName: string,
): Promise<string> {
  const response = await fetch(`${exchangeEndpoint(urn)}/${encodeURIComponent(fileName)}`, {
    headers: authHeaders(token),
  });
  if (!response.ok) {
    throw new Error(`Failed to fetch artifact ${fileName}: ${response.status}`);
  }
  return URL.createObjectURL(await response.blob());
}

// Picks the first artifact with the given extension (e.g. ".glb", ".usdz"), or undefined.
export function findArtifact(
  status: ConversionStatus | null,
  extension: string,
): string | undefined {
  return status?.artifacts.find((name) => name.toLowerCase().endsWith(extension));
}
