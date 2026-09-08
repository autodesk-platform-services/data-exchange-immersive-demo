# Data Exchange Immersive App (visionOS)

Native visionOS/SwiftUI application for browsing [Data Exchanges](https://aps.autodesk.com/data-exchange-cover-page) from Autodesk Platform Services and previewing the converted 3D models in a spatial-computing context on Apple Vision Pro.

https://github.com/user-attachments/assets/b665195a-1842-4110-9c81-524b529ecf94

## What it does

- Signs in with an Autodesk account via OAuth 2.0 PKCE (`ASWebAuthenticationSession`).
- Browses hubs, projects, and exchanges (queried through the Data Exchange GraphQL API), with search and per-row retry on failure.
- Converts an exchange to USDZ (via the sibling `DataExchangeConversionService`) and caches the result locally.
- Previews the converted model three ways, each a different kind of scene, switchable from a single segmented control. Exactly one is active at a time:
  - **Portal** — the model through a portal in the app's own plain window. The default and the cheapest: no volume claimed, no passthrough replaced, nothing to dismiss. Available while a conversion is still on its way, and deliberately read-only — one tap promotes it to Volume.
  - **Volume** — a volumetric window you place and resize; the model is re-fitted to whatever bounds you give it. Pinch and drag to move it, two hands to rotate or resize, plus two mutually exclusive tools:
    - **Section** — a feathered clipping box (`ClippingComponent`) with six draggable faces. Three states: off, cut with the handles hidden, and cut with them visible. Turning it off keeps your box, so switching back on restores your section.
    - **Explode** — separates the model's sub-assemblies along its dominant axis, driven continuously by a drag (or a slider) rather than by a one-shot animation. The axis is chosen at load from volume-weighted position variance, which resolves to vertical for a storey stack.
  - **Immersive** — the model at **1:1** in a full immersive space, with locomotion controls: a fly puck mapped to your gaze direction, an altitude slider, a recentre button, and a slow/walk/fast toggle. Comfort is built in rather than optional — no controller-driven rotation, constant velocity with no acceleration curve, and an edge vignette while the world is translating.
- Loads the model **once** and re-parents it between the three scenes. An entity has a single parent, so switching modes moves a several-hundred-megabyte BIM assembly rather than re-reading it.
- Reads the USD stage's `metersPerUnit` and reconciles it against what RealityKit's loader already applied, so a millimetre or centimetre export is the right size at 1:1 — and is never scaled twice.
- Warns when an export has no named sub-assemblies (a flattened `Part_001…Part_n` dump). It renders correctly and leaves Section and Explode with nothing to operate on, which is worth saying rather than presenting tools that visibly do nothing.
- Drops detail and shadow quality on `ProcessInfo.thermalStateDidChange`, before the frame rate degrades rather than after.
- Shows the conversion log in a sheet, reached from the detail view's toolbar menu. It is fetched only while the sheet is open.
- Also offers the system's Quick Look AR viewer as a platform-native fallback/export path.

## Project structure

- `DataExchangeViewer/Auth/` — OAuth PKCE flow and token storage.
- `DataExchangeViewer/Networking/` — Data Exchange GraphQL client and the conversion service's REST client.
- `DataExchangeViewer/Caching/` — local USDZ cache, keyed by exchange *version* URN so a newly published version isn't served from a stale download.
- `DataExchangeViewer/Models/` — `Hub`/`Project`/`Exchange` data models.
- `DataExchangeViewer/Stores/` — `ConversionStore`, tracking a single exchange's conversion state, and `ModelStore`, which owns the one loaded model and everything derived from it (unit correction, bounds in meters, entry point, explode axis and rest transforms, scene ownership).
- `DataExchangeViewer/Tools/` — Volume mode's tool layer: `ActiveTool` (mutual exclusion), `SectionBoxTool` + `SectionBoxGeometry` (`ClippingComponent`, six draggable faces, the retained-bounds cache), and `ExplodeTool`.
- `DataExchangeViewer/Views/` — SwiftUI views, one per scene: `USDzPreviewView` + `PortalScene` (Portal), `VolumeView` (Volume), and `ImmersiveModelView` (Immersive).
  - `ModelPlacement.swift` — the placement arithmetic for all three modes (viewer frame, portal fit and clipping volume, volume fit, immersive entry transform), kept out of the views so it can be checked without a headset.
  - `ExplodeLayout.swift` — axis selection and part spacing, likewise pure and tested.
  - `LocomotionController.swift` / `LocomotionControls.swift` — the world rig's motion and the controls that drive it.
  - `PreviewEnvironment.swift` — the near-black backdrop and low, graded IBL that Portal and Immersive are shown against.
  - `ComfortVignette.swift`, `ThermalQuality.swift`, `LevelOfDetail.swift` — comfort and performance.
- `AppModel.swift` — shared `@Observable` state coordinating which preview mode/window/immersive space is active, along with the immersion style and the number of mode switches in flight.
- `Models/PreviewMode.swift`, `Models/PreviewModeDefaults.swift` — the three modes, their person-facing strings, and the one-shot migration off the old `peek`/`place`/`enter` raw values.
- `Models/USDStageMetadata.swift` — the stage's units and up axis, read with USDKit, and the residual unit-scale reconciliation.
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

- **Placement math** (`ModelPlacement`) — the viewer frame's yaw-only heading and its untracked fallback, Portal's fit inside its clipping volume, Volume's uniform binding-axis fit, and Immersive's 1:1 entry transform (entry point at the wearer's feet, identity rotation, residual unit scale).
- **USD units** (`USDUnitScale`, `USDStageMetadata`) — including two SDK behaviours the design rests on, asserted against a stage generated at run time: that RealityKit bakes `metersPerUnit` into the loaded root's scale, and that it levels a Z-up stage. These are what stop someone "fixing" the unit code by multiplying by `metersPerUnit` a second time.
- **Explode layout** (`ExplodeLayout`) — volume-weighted axis selection (a storey stack with 200 small fixtures still explodes vertically; a site of separate buildings explodes horizontally), non-overlapping spacing for uneven parts, re-centring, and coincident slabs.
- **Section box** (`SectionBoxGeometry`) — each face's sign convention, that off-normal hand motion is ignored, that a face can't be dragged through its opposite, the overshoot clamp, and handle placement/orientation including the two exactly-opposed normals.
- **Model store** — the load pipeline against a generated four-storey millimetre building: metre-normalised bounds with no double scaling, `clipRoot` identity, the tool overlay staying outside the clipped subtree, the authored entry point, explode interpolation and restoration, the flattened-export warning, and scene ownership.
- **Preview modes** — the `peek→portal`, `place→volume`, `enter→immersive` migration, that it runs exactly once, hierarchy inspection (assembly root, generated-name detection), and LOD group parsing.
- **PKCE** — verifier length and alphabet, and the code challenge against RFC 7636's test vector.
- **Cache keys** — the USDZ file-name derivation, and that two versions of one exchange cache separately while both convert under the lineage URN.
- **Conversion endpoints** — percent-encoding an exchange URN into a path segment without double-encoding it, and round-tripping it back unchanged.
- **Conversion state** — metadata decoding (including rejecting an unknown status), artifact selection, and download progress.
- **Error presentation** — the messages behind each failure, and which failures count as an expired session.
- **App model** — the Portal/Volume/Immersive state machine, nested mode switches, and what survives a dismissal.
- **Configuration** — build-setting fallbacks for a missing, unexpanded, or unusable value.

Run them from Xcode (**Product ▸ Test**), or:

```bash
xcodebuild test -project DataExchangeViewer/DataExchangeViewer.xcodeproj -scheme DataExchangeViewer -destination 'platform=visionOS Simulator,name=Apple Vision Pro Simulator'
```

Substitute the name of your own visionOS 27 simulator; `xcodebuild -showdestinations -project DataExchangeViewer/DataExchangeViewer.xcodeproj -scheme DataExchangeViewer` lists what is installed, and a visionOS 26 simulator is reported there as below the deployment target.

The tests are hosted by the app, so they need a visionOS 27 simulator (or a paired device) to run in — but none of them makes a network request, signs in, or loads a USDZ.

## Known limitations

- **Immersive is strictly 1:1.** Scale is the point of the mode, so nothing is clamped: a 20 cm bracket previewed in Immersive is a 20 cm object two metres away. Volume is the mode for anything below room scale.
- **Level of detail is plumbing, not yet a feature.** `LevelOfDetailComponent` switches between detail levels that already exist in the asset — it does not simplify geometry — and the conversion service does not emit any. `LevelOfDetail` detects the conventional `LOD0`/`LOD1` sibling groups and wires camera-distance switching for Immersive and screen-area switching for Portal and Volume, but on today's artifacts it finds none and does nothing. Generating LOD representations during conversion is separate, unstarted work.
- **Section box is Volume-only.** A clipping box at 1:1 while you are standing inside the model is disorienting, so it is deliberately not offered in Immersive.
- **Explode operates on direct children only.** The sub-assemblies one level below the model's first branching entity, which matches the storey-stack case. Recursive per-sub-assembly explode, and pulling an individual part free by hand, are separate behaviours.
- **Verified by build and unit tests, not by eye.** visionOS input is gaze plus pinch, which the simulator cannot be driven with programmatically, so the portal's appearance, the section box's feathered edge, the comfort vignette's strength, and the locomotion controls' reachability have not been checked visually on a device.
- **Hub listing.** Every hub the signed-in account can reach is listed, including hubs with no Data Exchange projects in them (those show an empty project list).
- **Exchange listing.** Hubs, projects, and folders are paged through in full, and folder nesting is no longer depth-limited — but the schema exposes no pagination argument on a folder's `exchanges` field, so a folder with more exchanges than fit one page contributes only the first page. The exchange list says so when this happens, naming the folders involved, rather than presenting a partial list as complete.
