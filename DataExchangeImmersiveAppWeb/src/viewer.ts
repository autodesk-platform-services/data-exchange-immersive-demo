// Thin wrapper around the APS Viewer, which is loaded from the CDN in index.html and exposed
// as the global `Autodesk.Viewing` namespace.

// The viewer ships no TypeScript types via the CDN, so we treat the global as untyped.
declare const Autodesk: any;

let initialized = false;

// Initializes the viewer runtime (once) and returns a GuiViewer3D mounted in `container`.
export function initViewer(container: HTMLElement, token: string): Promise<any> {
  return new Promise((resolve, reject) => {
    const options = {
      env: "AutodeskProduction2",
      api: "streamingV2",
      // The viewer calls this whenever it needs a fresh token; we hand back the 3-legged token.
      getAccessToken: (onSuccess: (token: string, expiresIn: number) => void) => {
        onSuccess(token, 3600);
      },
    };

    const start = () => {
      try {
        const viewer = new Autodesk.Viewing.GuiViewer3D(container);
        if (viewer.start() > 0) {
          reject(new Error("Failed to start the APS Viewer."));
          return;
        }
        resolve(viewer);
      } catch (err) {
        reject(err);
      }
    };

    if (initialized) {
      start();
    } else {
      Autodesk.Viewing.Initializer(options, () => {
        initialized = true;
        start();
      });
    }
  });
}

// Loads the exchange's derivative (referenced by its URN) into the viewer's default 3D view.
export function loadExchange(viewer: any, urn: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const documentId = `urn:${btoa(urn).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_")}`;
    Autodesk.Viewing.Document.load(
      documentId,
      (doc: any) => {
        const defaultModel = doc.getRoot().getDefaultGeometry();
        if (!defaultModel) {
          reject(new Error("No viewable derivative found for this exchange."));
          return;
        }
        viewer.loadDocumentNode(doc, defaultModel).then(() => resolve(), reject);
      },
      (errorCode: number, errorMsg: string) => {
        reject(new Error(`Failed to load document (${errorCode}): ${errorMsg}`));
      },
    );
  });
}
