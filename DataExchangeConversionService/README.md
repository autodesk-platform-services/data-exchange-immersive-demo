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

The endpoint will return `202 Accepted` to indicate that the conversion has started in the background.

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
  "status": "completed",  // "running" | "completed" | "failed"
  "error": null,          // Error message in case "status" is "failed"
  "fileVersionUrn": "urn:adsk.wipprod:fs.file:vf.lbJRla4QRhO-Xnu-1bEg5Q?version=3",
                          // The exchange version these artifacts were produced from
  "createdAt": "2026-09-10T12:00:00Z",   // When the job was accepted
  "startedAt": "2026-09-10T12:00:01Z",   // When conversion work began; null until it does
  "updatedAt": "2026-09-10T12:04:12Z",   // Bumped at every step of the pipeline
  "completedAt": "2026-09-10T12:04:12Z", // When it finished or failed; null while running
  "artifacts": [          // Generated artifacts, described rather than just named
    {
      "name": "foo.usdz",
      "type": "usdz",     // "obj" | "mtl" | "glb" | "usdz" | "log" | "unknown"
      "contentType": "model/vnd.usdz+zip",
      "size": 184320000,  // bytes, so a client can show real download progress
      "checksum": "sha256:9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08"
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

The endpoint returns `404 Not Found` when there is no conversion for the exchange — *including* when the only stored conversion was produced from a version the exchange has since moved past. An exchange's lineage URN doesn't change when a new version is published, but its contents do, so a stale conversion is reported as absent rather than as the current one. Requesting a new conversion (`POST`) discards the superseded artifacts and converts the current version; artifact fetches are gated the same way, so a stale USDZ is never served.

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

The endpoint will return the raw bytes of the requested artifact file, with the appropriate `Content-Type` header set.

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
