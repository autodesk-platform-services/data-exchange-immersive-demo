import type React from "react";

// JSX declarations for the custom elements used by the GLB and USDZ tabs. Both are provided
// by scripts loaded from CDNs (model-viewer) or natively by the browser (<model>), so React
// only needs to know they are valid intrinsic elements.
declare module "react" {
  namespace JSX {
    interface IntrinsicElements {
      "model-viewer": React.DetailedHTMLProps<React.HTMLAttributes<HTMLElement>, HTMLElement> & {
        src?: string;
        alt?: string;
        "auto-rotate"?: boolean;
        "camera-controls"?: boolean;
        ar?: boolean;
      };
      model: React.DetailedHTMLProps<React.HTMLAttributes<HTMLElement>, HTMLElement> & {
        src?: string;
      };
    }
  }
}
