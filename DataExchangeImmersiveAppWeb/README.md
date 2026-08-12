# Data Exchange Immersive App (Web)

Browser-based client for browsing [Data Exchanges](https://aps.autodesk.com/data-exchange-cover-page) from Autodesk Platform Services and previewing the converted 3D models directly in the browser, including on visionOS Safari.

https://github.com/user-attachments/assets/7fd1c604-eb14-4301-8c39-2a9b7d44dfeb

## What it does

- Signs in with an Autodesk account via OAuth 2.0 PKCE (browser redirect flow; no client secret required).
- Browses hubs, projects, and exchanges (queried through the Data Exchange GraphQL API), via a hub/project tree in the sidebar and an exchange list in the main pane.
- Converts an exchange to GLB/USDZ (via the sibling `DataExchangeConversionService`) and polls its status every few seconds while the conversion is running.
- Previews the exchange four ways, switchable from a tab strip:
  - **Viewer** — the APS Viewer, streaming the exchange's Model Derivative viewable.
  - **GLB** — Google's `<model-viewer>` web component, which renders in any browser.
  - **USDZ** — Safari/visionOS's native `<model>` element.
  - **Logs** — the conversion log, readable even while a conversion is still running.
- Lets you download the converted GLB/USDZ artifact straight from its preview tab.
- Lets you clear a previous conversion's artifacts and re-run it.

## Project structure

- `index.ts` — Bun HTTP server entry point; serves `index.html`.
- `index.html` — page shell; loads the APS Viewer and `<model-viewer>` from CDN.
- `src/auth.ts` — OAuth 2.0 PKCE flow and token storage (`sessionStorage`).
- `src/aps.ts` — Data Exchange GraphQL client (hubs/projects/exchanges).
- `src/conversion.ts` — REST client for the sibling `DataExchangeConversionService`.
- `src/viewer.ts` — thin wrapper around the APS Viewer.
- `src/main.tsx` — React app: sidebar hub/project tree, exchange list, and the tabbed preview/conversion pane.

## Running locally

### Prerequisites

- [Bun](https://bun.sh) installed.
- An Autodesk Platform Services app with the origin you'll run this app on (e.g. `http://localhost:3000`) registered as a callback URL (see `CLIENT_ID` in `src/auth.ts`).

### Steps

- Install dependencies:

  ```bash
  bun install
  ```

- Run:

  ```bash
  bun run index.ts
  ```

  (or `bun --hot index.ts` for hot reload during development)

- Open the printed URL and sign in with an Autodesk account that has access to a hub/project containing at least one Data Exchange.
- Optional: point the app at a different conversion service backend (e.g. a local instance) by appending `?service=<url>` to the page URL. It defaults to the hosted Azure deployment described in [`DataExchangeConversionService`](../DataExchangeConversionService/).
