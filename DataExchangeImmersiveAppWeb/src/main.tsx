import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { getStoredToken, handleCallback, login, logout } from "./auth.ts";
import { getExchanges, getHubs, getProjects, type Exchange, type Hub, type Project } from "./aps.ts";
import {
  conversionDuration,
  deleteConversion,
  fetchLogText,
  findArtifact,
  getStatus,
  startConversion,
  type ConversionArtifact,
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

// The artifact is rendered from its presigned URL rather than from a blob.
//
// The `src` attributes of <model-viewer> and <model> cannot send an Authorization header, and a
// presigned URL carries its own authorization, so the element streams the bytes itself instead of
// a several-hundred-megabyte USDZ being materialised in the tab's memory before anything is drawn.
function ArtifactTab({
  status,
  type,
  render,
}: {
  status: ConversionStatus | null | undefined;
  type: ConversionArtifact["type"];
  render: (url: string) => React.ReactNode;
}) {
  const artifact = findArtifact(status, type);

  if (status?.status === "superseded") {
    return (
      <div className="tab-body placeholder">
        A newer version of this exchange was published. Convert again to view the {type} artifact.
      </div>
    );
  }
  if (status?.status !== "completed") {
    return <div className="tab-body placeholder">Run a conversion to view the {type} artifact.</div>;
  }
  if (!artifact) {
    return <div className="tab-body placeholder">No {type} artifact was produced.</div>;
  }
  if (!artifact.url) {
    return (
      <div className="tab-body placeholder">
        This conversion predates presigned artifact URLs. Re-run it to view the {type} artifact.
      </div>
    );
  }
  return (
    <div className="tab-body">
      {/* Cross-origin, so the `download` attribute is advisory — the service serves presigned
          artifacts inline and the browser saves what it cannot render. */}
      <a
        className="download-button"
        href={artifact.url}
        download={artifact.name}
        aria-label={`Download ${artifact.name} (${formatBytes(artifact.size)})`}
      >
        <DownloadIcon />
      </a>
      {render(artifact.url)}
    </div>
  );
}

// The artifact size arrives with the status, so the loading placeholder can say how much is being
// fetched rather than leaving a multi-hundred-megabyte download unexplained.
function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ["KB", "MB", "GB"];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit += 1;
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}

// ---------------------------------------------------------------------------
// Logs tab: streams the job's log, which is readable even while a conversion runs
// ---------------------------------------------------------------------------

function LogsTab({
  token,
  urn,
  collectionId,
  status,
}: {
  token: string;
  urn: string;
  collectionId: string;
  status: ConversionStatus | null | undefined;
}) {
  const [text, setText] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // `status` is a fresh object on every poll (see MainPane), so this effect re-fetches the log
  // on the same 3s cadence as the status poll while running, and once more when it settles.
  useEffect(() => {
    // Readable in any state, including superseded and failed — where it is the only thing that
    // explains what happened.
    if (!status) return;
    let cancelled = false;
    fetchLogText(token, urn, collectionId, status).then(
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
  }, [token, urn, collectionId, status]);

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
// Conversion duration: how long it has been running, or how long it took
// ---------------------------------------------------------------------------

function formatDuration(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return minutes > 0 ? `${minutes}m ${seconds}s` : `${seconds}s`;
}

// The service reports when it started, so the readout is the conversion's real age rather than
// how long this tab has been open. Its own component, and its own 1s tick, so the surrounding
// pane isn't re-rendered once a second while a conversion runs.
function ConversionDuration({ status }: { status: ConversionStatus }) {
  const isRunning = status.status === "running";
  const [now, setNow] = useState(() => Date.now());

  useEffect(() => {
    if (!isRunning) return;
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [isRunning]);

  const duration = conversionDuration(status, now);
  if (duration === null) return null;
  return <span className="duration">{formatDuration(duration)}</span>;
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
  // undefined = not checked yet, null = no conversion started, otherwise the latest status.
  const [status, setStatus] = useState<ConversionStatus | null | undefined>(undefined);

  // The conversion/viewing service identifies an exchange by its URL-encoded lineage URN
  // (urn:adsk.wipprod:dm.lineage:...), i.e. the exchange's fileUrn — not the GraphQL exchange id.
  const urn = exchange.fileUrn;
  const collectionId = exchange.collectionId;

  // As soon as an exchange is selected, check the viewing service for already-available artifacts.
  // The GLB/USDZ/logs tabs and the convert/delete button stay disabled until this first check settles.
  useEffect(() => {
    setStatus(undefined);
    setTab("viewer");
    getStatus(token, urn, collectionId).then(setStatus, () => setStatus(null));
  }, [token, urn, collectionId]);

  // Poll while a conversion is running.
  useEffect(() => {
    if (status?.status !== "running") return;
    const timer = setInterval(() => {
      getStatus(token, urn, collectionId).then(setStatus, () => {});
    }, 3000);
    return () => clearInterval(timer);
  }, [token, urn, collectionId, status?.status]);

  async function convert() {
    // The service answers with the job's real state rather than just "accepted", so there is no
    // need to fabricate a running status and wait for the first poll to correct it.
    setStatus(await startConversion(token, urn, collectionId));
  }

  async function remove() {
    await deleteConversion(token, urn, collectionId);
    setStatus(null);
  }

  return (
    <main className="main-pane">
      <div className="pane-header">
        <button className="icon-button" onClick={onBack} aria-label="Back">
          <Chevron className="back" />
        </button>
        <span className="pane-title pane-title-centered">{exchange.name}</span>
        <div className="conversion">
          {status && <span className={`status ${status.status}`}>{status.status}</span>}
          {status && <ConversionDuration status={status} />}
          {/* The sentence is shown; the exception summary is a tooltip, and the stack trace is in
              the Logs tab rather than in this header. */}
          {status?.error && (
            <span className="error" title={status.error.detail ?? undefined}>
              {status.error.message}
            </span>
          )}
          {status && status.status !== "superseded" ? (
            <button className="secondary" onClick={() => void remove()} disabled={status.status === "running"}>
              {status.status === "running" ? "Converting…" : "Clear"}
            </button>
          ) : (
            // A superseded conversion needs the same action as a missing one: convert again.
            // Starting one is not a conflict in that state, so no Clear is needed first.
            <button onClick={() => void convert()} disabled={status === undefined}>
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
              disabled={t !== "viewer" && status === undefined}
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
          status={status}
          type="glb"
          render={(url) => (
            <model-viewer src={url} auto-rotate camera-controls style={{ width: "100%", height: "100%" }} />
          )}
        />
      )}
      {tab === "usdz" && (
        <ArtifactTab
          status={status}
          type="usdz"
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
      {tab === "logs" && <LogsTab token={token} urn={urn} collectionId={collectionId} status={status} />}
    </main>
  );
}

// ---------------------------------------------------------------------------
// App shell
// ---------------------------------------------------------------------------

function App({ token }: { token: string }) {
  const [selectedProject, setSelectedProject] = useState<Project | null>(null);
  const [selectedExchange, setSelectedExchange] = useState<Exchange | null>(null);

  function onSelectProject(project: Project) {
    setSelectedExchange(null);
    setSelectedProject(project);
  }

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
