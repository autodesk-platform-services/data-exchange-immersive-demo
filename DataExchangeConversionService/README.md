# Data Exchange Conversion Service

Simple ASP.NET application extracting geometry data from [Data Exchanges](https://aps.autodesk.com/data-exchange-cover-page) using the [Data Exchange .NET SDK v8](https://aps.autodesk.com/en/docs/dx-sdk/v8.0.0/developers_guide/overview/).

## Job IDs

Every endpoint addresses a *conversion job*, identified by a single path segment: the base64url
encoding (RFC 4648 §5 — `-` and `_` instead of `+` and `/`, no `=` padding) of

```
{collectionId}|{exchangeUrn}
```

| Part | Description | Example |
| --- | --- | --- |
| `{collectionId}` | Data Exchange collection ID (the ACC project ID) | `b.12345678-abcd-1234-abcd-1234567890ab` |
| `{exchangeUrn}` | URN of your exchange | `urn:adsk.wipprod:dm.lineage:lbJRla4QRhO-Xnu-1bEg5Q` |

```js
const jobId = btoa(`${collectionId}|${exchangeUrn}`)
  .replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
// Yi4xMjM0NTY3OC1hYmNkLTEyMzQtYWJjZC0xMjM0NTY3ODkwYWJ8dXJuOmFkc2sud2lwcHJvZDpkbS5saW5lYWdlOmxiSlJsYTRRUmhPLVhudS0xYkVnNVE
```

The job ID is derived from the pair, not handed out by the service, so a client can compute it
before any job exists. base64url output is already safe inside a path segment, so — unlike the
exchange URN it encodes — it needs no percent-encoding.

## Live demo

The application is deployed to an Azure Web App. Here's how you can try it out:

> [!WARNING]
> The live server at `data-exchange-conversion-service.azurewebsites.net` is a demo deployment and may only be available occasionally (e.g. scaled down or stopped between demos). If requests to it start timing out or failing, run the service locally instead — see [Running locally](#running-locally) below.

### Extracting geometry from an exchange

```curl
POST https://data-exchange-conversion-service.azurewebsites.net/api/jobs/{{jobId}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{jobId}}` | Job ID, as described under [Job IDs](#job-ids) | `Yi4xMjM0NTY3OC1hYmNkLTEyMzQt...` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |
| `force` | Optional query parameter. `true` discards whatever is stored and converts again | `?force=true` |

The endpoint returns `202 Accepted` with the job's current state — the same document the status
endpoint returns — so a caller learns whether it is waiting on a fresh conversion or can go
straight to the artifacts without a second request.

The call is idempotent. Asking for a conversion that is already `running`, or already `completed`,
returns that conversion and starts nothing: the state you asked for either is being reached or has
been. A `failed` or `superseded` conversion is replaced, since neither is a result worth keeping —
so retrying a failure is just another `POST`, with no `DELETE` first. Pass `?force=true` to convert
again over a `completed` conversion.

### Checking status of an extraction

```curl
GET https://data-exchange-conversion-service.azurewebsites.net/api/jobs/{{jobId}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{jobId}}` | Job ID, as described under [Job IDs](#job-ids) | `Yi4xMjM0NTY3OC1hYmNkLTEyMzQt...` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

The endpoint will return JSON object with extraction metadata:

```jsonc
{
  "status": "completed",  // "running" | "completed" | "failed" | "superseded"
  "error": null,          // Error message in case "status" is "failed"
  "fileVersionUrn": "urn:adsk.wipprod:fs.file:vf.lbJRla4QRhO-Xnu-1bEg5Q?version=3",
                          // The exchange version these artifacts were produced from
  "currentFileVersionUrn": null,
                          // Only when "status" is "superseded": the version the exchange is at now
  "createdAt": "2026-09-10T12:00:00Z",   // When the job was accepted
  "startedAt": "2026-09-10T12:00:01Z",   // When conversion work began; null until it does
  "updatedAt": "2026-09-10T12:04:12Z",   // Bumped at every step of the pipeline
  "completedAt": "2026-09-10T12:04:12Z", // When it finished or failed; null while running
  "logUrl": "https://.../api/jobs/{jobId}/log?secret=...",
                          // The conversion log, readable in any state — including failed
  "artifacts": [          // Generated artifacts, described rather than just named
    {
      "name": "foo.usdz",
      "type": "usdz",     // "obj" | "mtl" | "glb" | "usdz" | "unknown"
      "contentType": "model/vnd.usdz+zip",
      "size": 184320000,  // bytes, so a client can show real download progress
      "checksum": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
      "url": "https://.../api/jobs/{jobId}/artifacts/foo.usdz?secret=..."
                          // Presigned — needs no Authorization header
    }
  ]
}
```

A job ID that is not valid base64url, or that does not decode to a `{collectionId}|{exchangeUrn}` pair, is answered with `400 Bad Request` on every endpoint.

Select an artifact by its `type` rather than by parsing `name` — the file names are derived from
the exchange's contents and are not predictable.

Timestamps are ISO 8601, UTC, second resolution (`2026-09-10T12:04:12Z`). `updatedAt` moves at
every step of the pipeline, so it doubles as a liveness heartbeat: a job still reporting `running`
whose `updatedAt` has stopped advancing is one whose conversion process is gone — the background
task does not survive a restart of the service, but the metadata it left behind does.

The endpoint returns `404 Not Found` when there is no conversion for the exchange.

A conversion produced from a version the exchange has since moved past is reported with
`"status": "superseded"` rather than as absent. An exchange's lineage URN doesn't change when a new
version is published, but its contents do, so the stored artifacts no longer describe the exchange:

- `fileVersionUrn` is the version they *were* produced from, `currentFileVersionUrn` the version the
  exchange is at now.
- The artifacts are not served — artifact fetches over the bearer route are gated the same way, so a
  stale USDZ is never handed out — and they carry no `url`.
- Requesting a new conversion (`POST`) is not a conflict in this state: it discards the superseded
  artifacts and converts the current version.

Reporting this as a 404 previously left a client unable to say why artifacts it had a moment ago
were gone: an exchange nobody had ever converted and one whose conversion had just been invalidated
looked identical.

> A presigned artifact URL handed out before the conversion was superseded keeps working until the
> conversion is replaced — see [Presigned artifact URLs](#presigned-artifact-urls).

### Presigned artifact URLs

Every artifact in a status response carries a `url` with a `secret` query parameter. Requests to it
need no `Authorization` header, which is the only way to hand these bytes to something that cannot
send one — a `<model-viewer>` or `<model>` `src`, or a `QLPreviewController`. Without it a client
has to fetch the whole artifact itself and pass along an object URL, which for a several-hundred-
megabyte USDZ means materialising the entire package in memory first.

- The secret is 256 bits from a cryptographic RNG, minted per conversion, and appears only in a
  status response — which the caller had to present a valid bearer token to read.
- It is revoked when the conversion is deleted or replaced, since it lives in the job's folder.
- It does **not** expire on its own, and query strings are commonly recorded in server and proxy
  access logs. Treat a presigned URL as a bearer credential for that one conversion's artifacts.
- Presigned responses are served inline; the bearer-token route still sets
  `Content-Disposition: attachment`.
- Unlike the bearer-token route, the presigned route does not check that the conversion is still of
  the exchange's current version — with no token there is no way to ask the Data Exchange service
  what that version is. A presigned URL points at the artifacts of one specific conversion. The
  status endpoint that hands it out is still version-gated, so a client following a fresh URL never
  receives stale bytes; only a client holding on to an old one does.

### Fetching an extraction artifact

```curl
GET https://data-exchange-conversion-service.azurewebsites.net/api/jobs/{{jobId}}/artifacts/{{ArtifactFileName}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{jobId}}` | Job ID, as described under [Job IDs](#job-ids) | `Yi4xMjM0NTY3OC1hYmNkLTEyMzQt...` |
| `{{ArtifactFileName}}` | Name of the artifact file to fetch | `foo.obj` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

The endpoint will return the raw bytes of the requested artifact file, with the appropriate `Content-Type` header set. Pass `?secret=...` instead of the `Authorization` header to use a [presigned URL](#presigned-artifact-urls).

This endpoint answers only for artifacts the conversion declared in `artifacts`. The job's own
bookkeeping — `metadata.json`, including the exception text a failed conversion records in it, and
the presigning `secret` next to it — lives in the same folder but is not reachable through it.

### Fetching the conversion log

```curl
GET https://data-exchange-conversion-service.azurewebsites.net/api/jobs/{{jobId}}/log
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{jobId}}` | Job ID, as described under [Job IDs](#job-ids) | `Yi4xMjM0NTY3OC1hYmNkLTEyMzQt...` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

Returns `text/plain`, inline, with range requests supported so a client can tail a growing log
rather than refetch it whole on every poll. The status response's `logUrl` is a presigned
equivalent that needs no `Authorization` header.

The log is **not** an artifact and no longer appears in `artifacts`: it exists from the moment the
job starts rather than when it finishes, it grows while the conversion runs, and its size and digest
are meaningless until it stops. It is readable whatever state the job is in — including `failed` and
`superseded`, where it is the only thing that explains what happened.

### Deleting extracted geometry

> Note: this will only remove the extracted geometry, not the data exchange itself.

```curl
DELETE https://data-exchange-conversion-service.azurewebsites.net/api/jobs/{{jobId}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{jobId}}` | Job ID, as described under [Job IDs](#job-ids) | `Yi4xMjM0NTY3OC1hYmNkLTEyMzQt...` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

## Running locally

### Prerequisites

- Visual Studio with the _ASP.NET and web development_ workload and _.NET 10_ installed
- Data Exchange SDK 8.0.0
- Existing data exchange in [Autodesk Forma](https://acc.autodesk.com)

### Steps

- Restore the NuGet packages referenced by the project. The Data Exchange SDK is available from the configured package sources.
- Build and run the solution
- Try the endpoints listed in the [Live demo](#live-demo) section against https://localhost:7008

## Deploying to Azure

See [docs/deploying-to-azure.md](../docs/deploying-to-azure.md).
