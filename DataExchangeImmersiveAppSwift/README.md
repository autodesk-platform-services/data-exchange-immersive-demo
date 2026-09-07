# Data Exchange Immersive App (visionOS)

Native visionOS/SwiftUI application for browsing [Data Exchanges](https://aps.autodesk.com/data-exchange-cover-page) from Autodesk Platform Services and previewing the converted 3D models in a spatial-computing context on Apple Vision Pro.

https://github.com/user-attachments/assets/b665195a-1842-4110-9c81-524b529ecf94

## What it does

- Signs in with an Autodesk account via OAuth 2.0 PKCE (`ASWebAuthenticationSession`).
- Browses hubs, projects, and exchanges (queried through the Data Exchange GraphQL API), with search and per-row retry on failure.
- Converts an exchange to USDZ (via the sibling `DataExchangeConversionService`) and caches the result locally.
- Previews the converted model four ways, switchable from a single control:
  - **Portal** — the model viewed through a framed opening in the flat window.
  - **Inspect** — a bounded volumetric window you can pick up, rotate, and scale by hand.
  - **Walk Through** — a full immersive space at real-world scale, with drag-to-reposition.
  - **Logs** — the conversion log, in place of the portal.
- Also offers the system's Quick Look AR viewer as a platform-native fallback/export path.

## Project structure

- `DataExchangeViewer/Auth/` — OAuth PKCE flow and token storage.
- `DataExchangeViewer/Networking/` — Data Exchange GraphQL client and the conversion service's REST client.
- `DataExchangeViewer/Stores/` — `ConversionStore`, tracking a single exchange's conversion state.
- `DataExchangeViewer/Caching/` — local USDZ cache, keyed by exchange *version* URN so a newly published version isn't served from a stale download.
- `DataExchangeViewer/Models/` — `Hub`/`Project`/`Exchange` data models.
- `DataExchangeViewer/Views/` — SwiftUI views, including the RealityKit-based portal/volumetric/immersive preview modes.
- `AppModel.swift` — shared `@Observable` state coordinating which preview mode/window/immersive space is active.

## Running locally

### Prerequisites

- Xcode with the visionOS SDK/simulator installed.
- An Autodesk Platform Services app with a registered `dxviewer://auth/callback` redirect URI.

### Steps

- Open `DataExchangeViewer/DataExchangeViewer.xcodeproj` in Xcode.
- Select a visionOS Simulator (or a paired Apple Vision Pro) as the run destination and build & run.
- Sign in with an Autodesk account that has access to a hub/project containing at least one Data Exchange.
- Select an exchange and tap **Convert** to send it to the conversion service; the button becomes **Converting…** until the USDZ artifact (or an error) comes back.

### Configuration

The APS client ID, requested scopes, OAuth callback scheme, and conversion service URL are build settings, surfaced to the app through `Info.plist` and read by `AppConfiguration` in `Networking/APSConstants.swift`. Override them without editing source — on the command line:

```bash
xcodebuild build -scheme DataExchangeViewer -destination 'generic/platform=visionOS Simulator' CONVERSION_SERVICE_BASE_URL=http://localhost:5000
```

…or in an `.xcconfig`, or in the target's build settings in Xcode.

| Build setting | `Info.plist` key | Default |
| --- | --- | --- |
| `APS_CLIENT_ID` | `APSClientID` | the demo's public PKCE client |
| `APS_SCOPES` | `APSScopes` | `data:read viewables:read` |
| `APS_CALLBACK_URL_SCHEME` | `APSCallbackURLScheme` | `dxviewer` |
| `CONVERSION_SERVICE_BASE_URL` | `ConversionServiceBaseURL` | the hosted Azure deployment |

Changing `APS_CALLBACK_URL_SCHEME` also updates the scheme the app registers in `CFBundleURLTypes`, so it stays in step with the redirect URI. Whatever these are set to, a setting that is missing or left unexpanded falls back to the default rather than failing the launch.

The app points at the hosted Azure deployment of the conversion service by default. To run against a local instance instead, set `CONVERSION_SERVICE_BASE_URL` and see [`DataExchangeConversionService`](../DataExchangeConversionService/) for how to run it yourself.

### How your APS token is used

Sign-in is a PKCE authorization-code flow against APS, and the resulting refresh token is stored in the keychain (`AfterFirstUnlockThisDeviceOnly`, so it stays on the device and out of backups).

The app then **forwards the signed-in user's APS access token to the conversion service** on every request, in an `Authorization: Bearer` header. The service needs it to call Data Exchange on that user's behalf — it holds no credentials of its own, and it uses the token both to verify that the caller can actually read the exchange and to download its contents. By default that means the token is sent to `data-exchange-conversion-service.azurewebsites.net`. This is the intended design of the demo, but it is a real trust relationship: point `CONVERSION_SERVICE_BASE_URL` only at a conversion service you trust with read access to your Autodesk data.

## Known limitations

- **Hub listing.** Every hub the signed-in account can reach is listed, including hubs with no Data Exchange projects in them (those show an empty project list).
- **Exchange listing.** Hubs, projects, and folders are paged through in full, and folder nesting is no longer depth-limited — but the schema exposes no pagination argument on a folder's `exchanges` field, so a folder with more exchanges than fit one page contributes only the first page. The exchange list says so when this happens, naming the folders involved, rather than presenting a partial list as complete.
