// 3-legged OAuth using PKCE (Proof Key for Code Exchange). No client secret is required
// or stored, so it is safe to keep the client ID in front-end source for a demo app.

const AUTH_BASE = "https://developer.api.autodesk.com/authentication/v2";
const CLIENT_ID = "YmHvRac8ZID6GHVY3R9skAcVZ8joHmyYT1RH7mvic7kEpTM9";
const REDIRECT_URI = window.location.origin;
const SCOPES = "data:read viewables:read";

const VERIFIER_KEY = "aps_pkce_verifier";
const TOKEN_KEY = "aps_access_token";
const EXPIRY_KEY = "aps_token_expiry";

// Base64url-encode an ArrayBuffer without padding (per RFC 7636).
function base64UrlEncode(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer);
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function randomVerifier(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes.buffer);
}

async function challengeFromVerifier(verifier: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
  return base64UrlEncode(digest);
}

// Kicks off the login flow by redirecting the browser to the Autodesk authorize endpoint.
export async function login(): Promise<void> {
  const verifier = randomVerifier();
  const challenge = await challengeFromVerifier(verifier);
  sessionStorage.setItem(VERIFIER_KEY, verifier);

  const params = new URLSearchParams({
    response_type: "code",
    client_id: CLIENT_ID,
    redirect_uri: REDIRECT_URI,
    scope: SCOPES,
    code_challenge: challenge,
    code_challenge_method: "S256",
  });
  window.location.assign(`${AUTH_BASE}/authorize?${params.toString()}`);
}

// Exchanges the `?code=` query parameter for an access token. Returns the token, or null
// if there was no code in the URL (i.e. this is not a redirect back from Autodesk).
export async function handleCallback(): Promise<string | null> {
  const url = new URL(window.location.href);
  const code = url.searchParams.get("code");
  if (!code) {
    return null;
  }

  const verifier = sessionStorage.getItem(VERIFIER_KEY);
  if (!verifier) {
    throw new Error("Missing PKCE verifier; please try logging in again.");
  }

  const response = await fetch(`${AUTH_BASE}/token`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      client_id: CLIENT_ID,
      code,
      redirect_uri: REDIRECT_URI,
      code_verifier: verifier,
    }),
  });
  if (!response.ok) {
    throw new Error(`Token exchange failed: ${response.status} ${await response.text()}`);
  }

  const data = (await response.json()) as { access_token: string; expires_in: number };
  sessionStorage.setItem(TOKEN_KEY, data.access_token);
  sessionStorage.setItem(EXPIRY_KEY, String(Date.now() + data.expires_in * 1000));
  sessionStorage.removeItem(VERIFIER_KEY);

  // Strip the OAuth query parameters from the URL so a refresh does not re-trigger the exchange.
  window.history.replaceState({}, document.title, REDIRECT_URI);
  return data.access_token;
}

// Returns the stored access token if it exists and has not expired, otherwise null.
export function getStoredToken(): string | null {
  const token = sessionStorage.getItem(TOKEN_KEY);
  const expiry = Number(sessionStorage.getItem(EXPIRY_KEY) ?? 0);
  if (!token || Date.now() >= expiry) {
    return null;
  }
  return token;
}

export function logout(): void {
  sessionStorage.clear();
  window.location.assign(REDIRECT_URI);
}
