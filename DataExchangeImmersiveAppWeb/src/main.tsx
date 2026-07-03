import React, { useCallback, useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { getStoredToken, handleCallback, login, logout } from "./auth.ts";
import { getExchanges, getHubs, getProjects, type Exchange, type Hub, type Project } from "./aps.ts";
import {
  deleteConversion,
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
// Background: fixed, heavily blurred backdrop photo behind the whole app
// ---------------------------------------------------------------------------

function Backdrop() {
  return <div className="backdrop" />;
}

// ---------------------------------------------------------------------------
// Login screen
// ---------------------------------------------------------------------------

function LoginPage() {
  return (
    <div className="login">
      <div className="login-card">
        <img className="login-logo" src={LOGO_URL} alt="Autodesk" />
        <h1>Data Exchange Immersive Demo</h1>
        <button onClick={() => void login()}>Login with Autodesk</button>
      </div>
    </div>
  );
}

function Spinner() {
  return (
    <span className="spinner" aria-hidden="true">
      {Array.from({ length: 8 }, (_, i) => (
        <span
          key={i}
          className="spinner-blade"
          style={{ transform: `rotate(${i * 45}deg)`, animationDelay: `${(i * 0.125 - 1).toFixed(3)}s` }}
        />
      ))}
    </span>
  );
}

// A single chevron glyph (pointing right) reused — via rotation — for the hub disclosure
// indicator, the exchange-row trailing arrow, and the back button, so all three match.
function Chevron({ className = "" }: { className?: string }) {
  return (
    <svg className={`chevron-icon ${className}`} viewBox="0 0 24 24" width="14" height="14" aria-hidden="true">
      <polyline points="9 6 15 12 9 18" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg viewBox="0 0 24 24" width="16" height="16" aria-hidden="true">
      <path
        d="M12 3v12m0 0l-5-5m5 5l5-5M5 20h14"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}

// ---------------------------------------------------------------------------
// Sidebar: app header + lazily-expanded Hub ▸ Project tree
// ---------------------------------------------------------------------------

function Sidebar({
  token,
  selectedProject,
  onSelectProject,
}: {
  token: string;
  selectedProject: Project | null;
  onSelectProject: (project: Project) => void;
}) {
  const [hubs, setHubs] = useState<Hub[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    getHubs(token).then(setHubs, (err) => setError(String(err)));
  }, [token]);

  return (
    <aside className="sidebar">
      <div className="pane-header">
        <span className="pane-title">Data Exchange AR/VR</span>
        <button className="secondary pill-small" onClick={logout}>
          Logout
        </button>
      </div>
      <div className="sidebar-body">
        {error && <p className="error">{error}</p>}
        {hubs.map((hub) => (
          <HubNode
            key={hub.id}
            token={token}
            hub={hub}
            selectedProject={selectedProject}
            onSelectProject={onSelectProject}
          />
        ))}
      </div>
    </aside>
  );
}

function HubNode({
  token,
  hub,
  selectedProject,
  onSelectProject,
}: {
  token: string;
  hub: Hub;
  selectedProject: Project | null;
  onSelectProject: (project: Project) => void;
}) {
  const [open, setOpen] = useState(false);
  const [projects, setProjects] = useState<Project[] | null>(null);
  const [loading, setLoading] = useState(false);

  const toggle = () => {
    setOpen((wasOpen) => !wasOpen);
    if (projects === null) {
      setLoading(true);
      getProjects(token, hub.id).then(
        (result) => {
          setProjects(result);
          setLoading(false);
        },
        () => {
          setProjects([]);
          setLoading(false);
        },
      );
    }
  };

  return (
    <div className="section">
      <div className={`section-heading ${open ? "open" : ""}`} onClick={toggle}>
        <span>{hub.name}</span>
        <Chevron className={`disclosure ${open ? "open" : ""}`} />
      </div>
      {open && loading && (
        <div className="tree-loading">
          <Spinner /> Loading projects…
        </div>
      )}
      {open && (
        <div className="row-group indent">
          {(projects ?? []).map((project) => (
            <div
              key={project.id}
              className={`row ${selectedProject?.id === project.id ? "selected" : ""}`}
              onClick={() => onSelectProject(project)}
            >
              <span className="row-label">{project.name}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Exchange list: shown in the main pane once a project is selected
// ---------------------------------------------------------------------------

function ExchangeList({
  token,
  project,
  onSelect,
}: {
  token: string;
  project: Project;
  onSelect: (exchange: Exchange) => void;
}) {
  const [exchanges, setExchanges] = useState<Exchange[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setExchanges(null);
    setError(null);
    getExchanges(token, project.id).then(setExchanges, (err) => {
      setError(String(err));
      setExchanges([]);
    });
  }, [token, project.id]);

  return (
    <main className="main-pane">
      <div className="pane-header">
        <span className="pane-title">{project.name}</span>
      </div>
      <div className="pane-content">
        {error && <p className="error">{error}</p>}
        {exchanges === null && (
          <div className="tree-loading">
            <Spinner /> Loading exchanges…
          </div>
        )}
        {exchanges?.length === 0 && <p className="placeholder-text">No data exchanges found in this project.</p>}
        {exchanges && exchanges.length > 0 && (
          <div className="row-group">
            {exchanges.map((exchange) => (
              <div key={exchange.id} className="row" onClick={() => onSelect(exchange)}>
                <span className="row-label">{exchange.name}</span>
                <Chevron className="trailing" />
              </div>
            ))}
          </div>
        )}
      </div>
    </main>
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
  return (
    <div className="tab-body">
      <a className="download-button" href={blobUrl} download={fileName} aria-label={`Download ${fileName}`}>
        <DownloadIcon />
      </a>
      {render(blobUrl)}
    </div>
  );
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
// Main pane: exchange preview — tabs + conversion controls
// ---------------------------------------------------------------------------

function MainPane({
  token,
  exchange,
  onBack,
}: {
  token: string;
  exchange: Exchange;
  onBack: () => void;
}) {
  const [tab, setTab] = useState<Tab>("viewer");
  const [status, setStatus] = useState<ConversionStatus | null>(null);
  const [statusLoaded, setStatusLoaded] = useState(false);

  // The conversion/viewing service identifies an exchange by its URL-encoded lineage URN
  // (urn:adsk.wipprod:dm.lineage:...), i.e. the exchange's fileUrn — not the GraphQL exchange id.
  const urn = exchange.fileUrn;

  // As soon as an exchange is selected, check the viewing service for already-available artifacts.
  // The GLB/USDZ/logs tabs and the convert/delete button stay disabled until this first check settles.
  useEffect(() => {
    setStatus(null);
    setStatusLoaded(false);
    setTab("viewer");
    getStatus(token, urn).then(
      (result) => {
        setStatus(result);
        setStatusLoaded(true);
      },
      () => {
        setStatus(null);
        setStatusLoaded(true);
      },
    );
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

  const remove = useCallback(async () => {
    await deleteConversion(token, urn);
    setStatus(null);
  }, [token, urn]);

  return (
    <main className="main-pane">
      <div className="pane-header">
        <button className="icon-button" onClick={onBack} aria-label="Back">
          <Chevron className="back" />
        </button>
        <span className="pane-title pane-title-centered">{exchange.name}</span>
        <div className="conversion">
          {status && <span className={`status ${status.status}`}>{status.status}</span>}
          {status?.error && <span className="error">{status.error}</span>}
          {status ? (
            <button className="secondary" onClick={() => void remove()} disabled={status.status === "running"}>
              {status.status === "running" ? "Converting…" : "Clear"}
            </button>
          ) : (
            <button onClick={() => void convert()} disabled={!statusLoaded}>
              Convert
            </button>
          )}
        </div>
      </div>
      <div className="tabs-row">
        <div className="tabs">
          {(["viewer", "glb", "usdz", "logs"] as Tab[]).map((t) => (
            <button
              key={t}
              className={tab === t ? "active" : ""}
              disabled={t !== "viewer" && !statusLoaded}
              onClick={() => setTab(t)}
            >
              {TAB_LABELS[t]}
            </button>
          ))}
        </div>
      </div>

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
  const [selectedProject, setSelectedProject] = useState<Project | null>(null);
  const [selectedExchange, setSelectedExchange] = useState<Exchange | null>(null);

  const onSelectProject = useCallback((project: Project) => {
    setSelectedExchange(null);
    setSelectedProject(project);
  }, []);

  return (
    <div className="app">
      <div className="layout">
        <Sidebar token={token} selectedProject={selectedProject} onSelectProject={onSelectProject} />
        {!selectedProject && (
          <main className="main-pane placeholder">
            <p className="placeholder-text">Select a project to begin.</p>
          </main>
        )}
        {selectedProject && !selectedExchange && (
          <ExchangeList key={selectedProject.id} token={token} project={selectedProject} onSelect={setSelectedExchange} />
        )}
        {selectedExchange && (
          <MainPane
            key={selectedExchange.id}
            token={token}
            exchange={selectedExchange}
            onBack={() => setSelectedExchange(null)}
          />
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
    return (
      <>
        <Backdrop />
        <div className="login">Loading…</div>
      </>
    );
  }
  return (
    <>
      <Backdrop />
      {token ? <App token={token} /> : <LoginPage />}
    </>
  );
}

createRoot(document.getElementById("root")!).render(<Root />);
