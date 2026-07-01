import React, { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { getStoredToken, handleCallback, login, logout } from "./auth.ts";
import { getExchanges, getHubs, getProjects, type Exchange, type Hub, type Project } from "./aps.ts";
import {
  fetchArtifactBlob,
  fetchArtifactText,
  findArtifact,
  getStatus,
  startConversion,
  type ConversionStatus,
} from "./conversion.ts";
import { initViewer, loadExchange } from "./viewer.ts";

import "./styles.css";

const LOGO_URL = "https://cdn.autodesk.io/logo/white/stacked.png";

type Tab = "viewer" | "glb" | "usdz" | "logs";

const TAB_LABELS: Record<Tab, string> = {
  viewer: "Viewer",
  glb: "GLB",
  usdz: "USDZ",
  logs: "Logs",
};

// ---------------------------------------------------------------------------
// Login screen
// ---------------------------------------------------------------------------

function LoginPage() {
  return (
    <div className="login">
      <img className="login-logo" src={LOGO_URL} alt="Autodesk" />
      <h1>Data Exchange Immersive Demo</h1>
      <button onClick={() => void login()}>Login with Autodesk</button>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Sidebar: lazily-expanded Hub ▸ Project ▸ Exchange tree
// ---------------------------------------------------------------------------

function Sidebar({
  token,
  selected,
  onSelect,
}: {
  token: string;
  selected: Exchange | null;
  onSelect: (exchange: Exchange) => void;
}) {
  const [hubs, setHubs] = useState<Hub[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    getHubs(token).then(setHubs, (err) => setError(String(err)));
  }, [token]);

  return (
    <aside className="sidebar">
      {error && <p className="error">{error}</p>}
      {hubs.map((hub) => (
        <HubNode key={hub.id} token={token} hub={hub} selected={selected} onSelect={onSelect} />
      ))}
    </aside>
  );
}

function HubNode({
  token,
  hub,
  selected,
  onSelect,
}: {
  token: string;
  hub: Hub;
  selected: Exchange | null;
  onSelect: (exchange: Exchange) => void;
}) {
  const [open, setOpen] = useState(false);
  const [projects, setProjects] = useState<Project[] | null>(null);

  const toggle = () => {
    setOpen((wasOpen) => !wasOpen);
    if (projects === null) {
      getProjects(token, hub.id).then(setProjects, () => setProjects([]));
    }
  };

  return (
    <div className="tree-node">
      <div className={`tree-label ${open ? "open" : ""}`} onClick={toggle}>
        {hub.name}
      </div>
      {open &&
        (projects ?? []).map((project) => (
          <ProjectNode
            key={project.id}
            token={token}
            project={project}
            selected={selected}
            onSelect={onSelect}
          />
        ))}
    </div>
  );
}

function ProjectNode({
  token,
  project,
  selected,
  onSelect,
}: {
  token: string;
  project: Project;
  selected: Exchange | null;
  onSelect: (exchange: Exchange) => void;
}) {
  const [open, setOpen] = useState(false);
  const [exchanges, setExchanges] = useState<Exchange[] | null>(null);

  const toggle = () => {
    setOpen((wasOpen) => !wasOpen);
    if (exchanges === null) {
      getExchanges(token, project.id).then(setExchanges, () => setExchanges([]));
    }
  };

  return (
    <div className="tree-node indent">
      <div className={`tree-label ${open ? "open" : ""}`} onClick={toggle}>
        {project.name}
      </div>
      {open &&
        (exchanges ?? []).map((exchange) => (
          <div
            key={exchange.id}
            className={`tree-leaf indent ${selected?.id === exchange.id ? "selected" : ""}`}
            onClick={() => onSelect(exchange)}
          >
            {exchange.name}
          </div>
        ))}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Viewer tab: APS Viewer
// ---------------------------------------------------------------------------

function ViewerTab({ token, exchange }: { token: string; exchange: Exchange }) {
  const containerRef = useRef<HTMLDivElement>(null);
  const viewerRef = useRef<any>(null);
  const [error, setError] = useState<string | null>(null);

  // Model Derivative loads a specific version URN; fall back to the lineage URN if absent.
  const viewerUrn = exchange.fileVersionUrn || exchange.fileUrn;

  useEffect(() => {
    let cancelled = false;
    setError(null);

    async function run() {
      if (!containerRef.current) return;
      if (!viewerUrn) {
        setError("This exchange has no viewable derivative.");
        return;
      }
      if (!viewerRef.current) {
        viewerRef.current = await initViewer(containerRef.current, token);
      }
      try {
        await loadExchange(viewerRef.current, viewerUrn);
      } catch (err) {
        if (!cancelled) setError(String(err));
      }
    }
    run().catch((err) => !cancelled && setError(String(err)));

    return () => {
      cancelled = true;
    };
  }, [token, viewerUrn]);

  return (
    <div className="tab-body">
      {error && <p className="error">{error}</p>}
      <div ref={containerRef} className="viewer-container" />
    </div>
  );
}

// ---------------------------------------------------------------------------
// GLB / USDZ tabs: rendered from converted artifacts
// ---------------------------------------------------------------------------

function ArtifactTab({
  token,
  urn,
  status,
  extension,
  render,
}: {
  token: string;
  urn: string;
  status: ConversionStatus | null;
  extension: string;
  render: (blobUrl: string) => React.ReactNode;
}) {
  const [blobUrl, setBlobUrl] = useState<string | null>(null);
  const fileName = findArtifact(status, extension);

  useEffect(() => {
    if (!fileName) {
      setBlobUrl(null);
      return;
    }
    let revoked: string | null = null;
    fetchArtifactBlob(token, urn, fileName).then((url) => {
      revoked = url;
      setBlobUrl(url);
    });
    // Revoke the previous object URL when the artifact or exchange changes, to avoid leaks.
    return () => {
      if (revoked) URL.revokeObjectURL(revoked);
    };
  }, [token, urn, fileName]);

  if (status?.status !== "completed") {
    return <div className="tab-body placeholder">Run a conversion to view the {extension} artifact.</div>;
  }
  if (!fileName) {
    return <div className="tab-body placeholder">No {extension} artifact was produced.</div>;
  }
  if (!blobUrl) {
    return <div className="tab-body placeholder">Loading {extension}…</div>;
  }
  return <div className="tab-body">{render(blobUrl)}</div>;
}

// ---------------------------------------------------------------------------
// Logs tab: streams log.txt, which is readable even while a conversion runs
// ---------------------------------------------------------------------------

function LogsTab({
  token,
  urn,
  status,
}: {
  token: string;
  urn: string;
  status: ConversionStatus | null;
}) {
  const [text, setText] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // `status` is a fresh object on every poll (see MainPane), so this effect re-fetches the log
  // on the same 3s cadence as the status poll while running, and once more when it settles.
  useEffect(() => {
    if (!status) return;
    let cancelled = false;
    fetchArtifactText(token, urn, "log.txt").then(
      (contents) => {
        if (!cancelled) {
          setText(contents);
          setError(null);
        }
      },
      (err) => {
        if (!cancelled) setError(String(err));
      },
    );
    return () => {
      cancelled = true;
    };
  }, [token, urn, status]);

  if (!status) {
    return <div className="tab-body placeholder">Run a conversion to view logs.</div>;
  }
  if (error && !text) {
    return (
      <div className="tab-body placeholder">
        {status.status === "running" ? "Waiting for logs…" : <span className="error">{error}</span>}
      </div>
    );
  }
  if (!text) {
    return <div className="tab-body placeholder">Loading logs…</div>;
  }
  return (
    <div className="tab-body">
      <pre className="log-view">{text}</pre>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main pane: tabs + conversion controls for the selected exchange
// ---------------------------------------------------------------------------

function MainPane({ token, exchange }: { token: string; exchange: Exchange }) {
  const [tab, setTab] = useState<Tab>("viewer");
  const [status, setStatus] = useState<ConversionStatus | null>(null);

  // The conversion/viewing service identifies an exchange by its URL-encoded lineage URN
  // (urn:adsk.wipprod:dm.lineage:...), i.e. the exchange's fileUrn — not the GraphQL exchange id.
  const urn = exchange.fileUrn;

  // As soon as an exchange is selected, check the viewing service for already-available artifacts.
  useEffect(() => {
    setStatus(null);
    setTab("viewer");
    getStatus(token, urn).then(setStatus, () => setStatus(null));
  }, [token, urn]);

  // Poll while a conversion is running.
  useEffect(() => {
    if (status?.status !== "running") return;
    const timer = setInterval(() => {
      getStatus(token, urn).then(setStatus, () => {});
    }, 3000);
    return () => clearInterval(timer);
  }, [token, urn, status?.status]);

  const convert = useCallback(async () => {
    await startConversion(token, urn);
    setStatus({ status: "running", artifacts: [] });
  }, [token, urn]);

  return (
    <main className="main-pane">
      <header className="toolbar">
        <div className="tabs">
          {(["viewer", "glb", "usdz", "logs"] as Tab[]).map((t) => (
            <button
              key={t}
              className={tab === t ? "active" : ""}
              onClick={() => setTab(t)}
            >
              {TAB_LABELS[t]}
            </button>
          ))}
        </div>
        <div className="conversion">
          <button onClick={() => void convert()} disabled={status?.status === "running"}>
            {status?.status === "running" ? "Converting…" : "Convert"}
          </button>
          {status && <span className={`status ${status.status}`}>{status.status}</span>}
          {status?.error && <span className="error">{status.error}</span>}
        </div>
      </header>

      {tab === "viewer" && <ViewerTab token={token} exchange={exchange} />}
      {tab === "glb" && (
        <ArtifactTab
          token={token}
          urn={urn}
          status={status}
          extension=".glb"
          render={(url) => (
            <model-viewer src={url} auto-rotate camera-controls style={{ width: "100%", height: "100%" }} />
          )}
        />
      )}
      {tab === "usdz" && (
        <ArtifactTab
          token={token}
          urn={urn}
          status={status}
          extension=".usdz"
          render={(url) => (
            <>
              <p className="note">
                The &lt;model&gt; element renders only in Safari / visionOS.
              </p>
              <model src={url} style={{ width: "100%", height: "100%" }} />
            </>
          )}
        />
      )}
      {tab === "logs" && <LogsTab token={token} urn={urn} status={status} />}
    </main>
  );
}

// ---------------------------------------------------------------------------
// App shell
// ---------------------------------------------------------------------------

function App({ token }: { token: string }) {
  const [selected, setSelected] = useState<Exchange | null>(null);

  return (
    <div className="app">
      <nav className="topbar">
        <div className="brand">
          <img className="brand-logo" src={LOGO_URL} alt="Autodesk" />
          <span>Data Exchange Immersive Demo</span>
        </div>
        <button onClick={logout}>Logout</button>
      </nav>
      <div className="layout">
        <Sidebar token={token} selected={selected} onSelect={setSelected} />
        {selected ? (
          <MainPane key={selected.id} token={token} exchange={selected} />
        ) : (
          <main className="main-pane placeholder">Select an exchange to begin.</main>
        )}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Auth gate + bootstrap
// ---------------------------------------------------------------------------

function Root() {
  const [token, setToken] = useState<string | null>(getStoredToken());
  const [ready, setReady] = useState(false);

  useEffect(() => {
    // If we are returning from the Autodesk redirect, exchange the code for a token.
    handleCallback()
      .then((newToken) => {
        if (newToken) setToken(newToken);
      })
      .catch((err) => console.error(err))
      .finally(() => setReady(true));
  }, []);

  if (!ready && !token) {
    return <div className="login">Loading…</div>;
  }
  return token ? <App token={token} /> : <LoginPage />;
}

createRoot(document.getElementById("root")!).render(<Root />);
