# Data Exchange Immersive App (visionOS)

Native visionOS/SwiftUI application for browsing [Data Exchanges](https://aps.autodesk.com/data-exchange-cover-page) from Autodesk Platform Services and previewing the converted 3D models in a spatial-computing context on Apple Vision Pro.

https://github.com/user-attachments/assets/613bb471-c902-4c0a-8494-4d2d084a5526

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
- `DataExchangeViewer/Caching/` — local USDZ cache, keyed by exchange URN.
- `DataExchangeViewer/Models/` — `Hub`/`Project`/`Exchange` data models.
- `DataExchangeViewer/Views/` — SwiftUI views, including the RealityKit-based portal/volumetric/immersive preview modes.
- `AppModel.swift` — shared `@Observable` state coordinating which preview mode/window/immersive space is active.

## Running locally

### Prerequisites

- Xcode with the visionOS SDK/simulator installed.
- An Autodesk Platform Services app with a registered `dxviewer://auth/callback` redirect URI (see `Networking/APSConstants.swift`).

### Steps

- Open `DataExchangeViewer/DataExchangeViewer.xcodeproj` in Xcode.
- Select a visionOS Simulator (or a paired Apple Vision Pro) as the run destination and build & run.
- Sign in with an Autodesk account that has access to a hub/project containing at least one Data Exchange.
- Select an exchange and tap **Convert** to send it to the conversion service; the button becomes **Converting…** until the USDZ artifact (or an error) comes back.

The app points at the hosted Azure deployment of the conversion service by default (see `ConversionServiceConstants` in `Networking/APSConstants.swift`). To run against a local instance instead, change that constant and see [`DataExchangeConversionService`](../DataExchangeConversionService/) for how to run it yourself.
