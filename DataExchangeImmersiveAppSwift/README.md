# Data Exchange Immersive App (visionOS)

Native visionOS/SwiftUI application for browsing [Data Exchanges](https://aps.autodesk.com/data-exchange-cover-page) from Autodesk Platform Services and previewing the converted 3D models in a spatial-computing context on Apple Vision Pro.

https://github.com/user-attachments/assets/b665195a-1842-4110-9c81-524b529ecf94

## What it does

- Signs in with an Autodesk account via OAuth 2.0 PKCE (`ASWebAuthenticationSession`).
- Browses hubs, projects, and exchanges (queried through the Data Exchange GraphQL API), with search and per-row retry on failure.
- Converts an exchange to USDZ (via the sibling `DataExchangeConversionService`) and caches the result locally.
- Previews the converted model three ways, presented as one continuum and switchable from a single segmented control:
  - **Peek** — the model seen through a framed opening in the flat window. Available while a conversion is still on its way.
  - **Place** — the model in your surroundings at tabletop scale (largest dimension 65 cm): pinch and drag to move it, two hands to rotate or resize. Mixed immersion, so the room stays visible.
  - **Enter** — the same model at walk-through scale, with on-screen controls that fly you through it while you stay physically still. Progressive immersion, so the Digital Crown remains the system-native comfort control, plus an opt-in **Go Full Immersion** toggle.
- Keeps a hand-authored Place position while you switch to Enter and back: the two modes share one immersive scene, so switching neither reloads the model nor loses where you put it. Returning to Peek resets it, so the next Place session starts in front of wherever you are then.
- Shows the conversion log in a sheet, reached from the detail view's toolbar menu. It is fetched only while the sheet is open.
- Also offers the system's Quick Look AR viewer as a platform-native fallback/export path.

## Project structure

- `DataExchangeViewer/Auth/` — OAuth PKCE flow and token storage.
- `DataExchangeViewer/Networking/` — Data Exchange GraphQL client and the conversion service's REST client.
- `DataExchangeViewer/Stores/` — `ConversionStore`, tracking a single exchange's conversion state.
- `DataExchangeViewer/Caching/` — local USDZ cache, keyed by exchange *version* URN so a newly published version isn't served from a stale download.
- `DataExchangeViewer/Models/` — `Hub`/`Project`/`Exchange` data models.
- `DataExchangeViewer/Views/` — SwiftUI views, including the RealityKit-based Peek portal (`PortalScene`, `USDzPreviewView`) and the shared Place/Enter immersive scene (`ImmersiveModelView`).
  - `ModelPlacement.swift` — the placement arithmetic for Place and Enter (viewer frame, scale clamps, floor grounding), kept out of the view so it can be checked without a headset.
  - `FlightController.swift` — velocity-based virtual locomotion for Enter.
- `AppModel.swift` — shared `@Observable` state coordinating which preview mode/window/immersive space is active, along with the immersion style and the number of mode switches in flight.
- `DataExchangeViewerTests/` — unit tests. See [Tests](#tests).

## Running locally

### Prerequisites

- Xcode 27 with the visionOS 27 SDK and a visionOS 27 simulator runtime. The app targets **visionOS 27 only** — it carries no availability gates for visionOS 26, so an earlier SDK will not build it.
- An Autodesk Platform Services app with a registered `dxviewer://auth/callback` redirect URI.

### Steps

- Open `DataExchangeViewer/DataExchangeViewer.xcodeproj` in Xcode.
- Select a visionOS 27 Simulator (or a paired Apple Vision Pro) as the run destination and build & run.
- Sign in with an Autodesk account that has access to a hub/project containing at least one Data Exchange.
- Select an exchange and tap **Convert** to send it to the conversion service. The toolbar button becomes **Cancel** while the conversion runs, and the preview area reports what the app is waiting on — elapsed conversion time, then the artifact download's byte progress — until the USDZ (or an error) comes back.

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

Changing `APS_CALLBACK_URL_SCHEME` also updates the scheme the app registers in `CFBundleURLTypes`, so it stays in step with the redirect URI. Whatever these are set to, a setting that is missing, left unexpanded, or — for `CONVERSION_SERVICE_BASE_URL` — not an absolute `http`/`https` URL falls back to the default rather than failing the launch.

The app points at the hosted Azure deployment of the conversion service by default. To run against a local instance instead, set `CONVERSION_SERVICE_BASE_URL` and see [`DataExchangeConversionService`](../DataExchangeConversionService/) for how to run it yourself.

### How your APS token is used

Sign-in is a PKCE authorization-code flow against APS, and the resulting refresh token is stored in the keychain (`AfterFirstUnlockThisDeviceOnly`, so it stays on the device and out of backups).

The app then **forwards the signed-in user's APS access token to the conversion service** on every request, in an `Authorization: Bearer` header. The service needs it to call Data Exchange on that user's behalf — it holds no credentials of its own, and it uses the token both to verify that the caller can actually read the exchange and to download its contents. By default that means the token is sent to `data-exchange-conversion-service.azurewebsites.net`. This is the intended design of the demo, but it is a real trust relationship: point `CONVERSION_SERVICE_BASE_URL` only at a conversion service you trust with read access to your Autodesk data.

## Tests

The `DataExchangeViewerTests` unit-test target covers the parts of the app that are pure and deterministic — the ones a headset can't usefully check by eye:

- **Placement math** (`ModelPlacement`) — the viewer frame's yaw-only heading and its untracked fallback, Place's 65 cm scaling and centering, and Enter's scale clamps in both directions, floor grounding, and two-metres-ahead entrance.
- **PKCE** — verifier length and alphabet, and the code challenge against RFC 7636's test vector.
- **Cache keys** — the USDZ file-name derivation, and that two versions of one exchange cache separately while both convert under the lineage URN.
- **Conversion endpoints** — percent-encoding an exchange URN into a path segment without double-encoding it, and round-tripping it back unchanged.
- **Conversion state** — metadata decoding (including rejecting an unknown status), artifact selection, and download progress.
- **Error presentation** — the messages behind each failure, and which failures count as an expired session.
- **App model** — the Peek/Place/Enter state machine, nested mode switches, and what survives a dismissal.
- **Configuration** — build-setting fallbacks for a missing, unexpanded, or unusable value.

Run them from Xcode (**Product ▸ Test**), or:

```bash
xcodebuild test -project DataExchangeViewer/DataExchangeViewer.xcodeproj -scheme DataExchangeViewer -destination 'platform=visionOS Simulator,name=Apple Vision Pro Simulator'
```

Substitute the name of your own visionOS 27 simulator; `xcodebuild -showdestinations -project DataExchangeViewer/DataExchangeViewer.xcodeproj -scheme DataExchangeViewer` lists what is installed, and a visionOS 26 simulator is reported there as below the deployment target.

The tests are hosted by the app, so they need a visionOS 27 simulator (or a paired device) to run in — but none of them makes a network request, signs in, or loads a USDZ.

## Known limitations

- **Hub listing.** Every hub the signed-in account can reach is listed, including hubs with no Data Exchange projects in them (those show an empty project list).
- **Exchange listing.** Hubs, projects, and folders are paged through in full, and folder nesting is no longer depth-limited — but the schema exposes no pagination argument on a folder's `exchanges` field, so a folder with more exchanges than fit one page contributes only the first page. The exchange list says so when this happens, naming the folders involved, rather than presenting a partial list as complete.
