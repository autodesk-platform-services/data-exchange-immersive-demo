# DataExchangeImmersiveDemo

Experimental project exploring the use cases of Data Exchanges being used in augmented reality and spatial computing applications.

## Project structure

The repository is organized into three independent components:

- [`DataExchangeConversionService/`](DataExchangeConversionService/) — ASP.NET (.NET 10) web service that extracts geometry from [Data Exchanges](https://aps.autodesk.com/data-exchange-cover-page) using the Public Beta SDK and converts it into OBJ/MTL, GLB (glTF binary), and USDZ artifacts. Exposes a small REST API (under `/api/exchanges`) to start a conversion, poll its status, download the resulting artifacts, and delete them.

- [`DataExchangeImmersiveAppWeb/`](DataExchangeImmersiveAppWeb/) — Browser-based client (Bun + React + TypeScript) for logging into Autodesk Platform Services, browsing available exchanges, and previewing the converted models. It renders geometry three ways: the APS Viewer, Google's `<model-viewer>` web component for GLB, and Safari/visionOS's native `<model>` element for USDZ.

- [`DataExchangeImmersiveAppSwift/`](DataExchangeImmersiveAppSwift/) — Native visionOS/SwiftUI application (visionOS 27) for previewing data exchanges from Autodesk Platform Services in an immersive, spatial-computing context. It authenticates via OAuth PKCE, lets users browse hubs, projects, and exchanges, and previews the converted USDZ three ways with RealityKit: through a portal in the window (Peek), at tabletop scale in the room (Place), or at walk-through scale in an immersive space (Enter).

Each component has its own README with setup and usage details.
