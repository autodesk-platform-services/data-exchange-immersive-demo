# Data Exchange Conversion Service

Simple ASP.NET application extracting geometry data from [Data Exchanges](https://aps.autodesk.com/data-exchange-cover-page) using the [Data Exchange .NET SDK v8](https://aps.autodesk.com/en/docs/dx-sdk/v8.0.0/developers_guide/overview/).

## Live demo

The application is deployed to an Azure Web App. Here's how you can try it out:

> [!WARNING]
> The live server at `data-exchange-conversion-service.azurewebsites.net` is a demo deployment and may only be available occasionally (e.g. scaled down or stopped between demos). If requests to it start timing out or failing, run the service locally instead — see [Running locally](#running-locally) below.

### Extracting geometry from an exchange

```curl
POST https://data-exchange-conversion-service.azurewebsites.net/api/exchanges/{{collectionId}}/{{exchangeUrn}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{exchangeUrn}}` | URL-encoded URN of your exchange | `urn%3Aadsk.wipprod%3Adm.lineage%3AlbJRla4QRhO-Xnu-1bEg5Q` |
| `{{collectionId}}` | URL-encoded Data Exchange collection ID (the ACC project ID) | `b.12345678-abcd-1234-abcd-1234567890ab` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

The endpoint will return `202 Accepted` to indicate that the conversion has started in the background.

### Checking status of an extraction

```curl
GET https://data-exchange-conversion-service.azurewebsites.net/api/exchanges/{{collectionId}}/{{exchangeUrn}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{exchangeUrn}}` | URL-encoded URN of your exchange | `urn%3Aadsk.wipprod%3Adm.lineage%3AlbJRla4QRhO-Xnu-1bEg5Q` |
| `{{collectionId}}` | URL-encoded Data Exchange collection ID (the ACC project ID) | `b.12345678-abcd-1234-abcd-1234567890ab` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

The endpoint will return JSON object with extraction metadata:

```jsonc
{
  "status": "completed",  // "running" | "completed" | "failed"
  "error": null,          // Error message in case "status" is "failed"
  "fileVersionUrn": "urn:adsk.wipprod:fs.file:vf.lbJRla4QRhO-Xnu-1bEg5Q?version=3",
                          // The exchange version these artifacts were produced from
  "artifacts": [          // List of filenames of generated artifacts in case "status" is "completed"
    "foo.obj",
    "foo.mtl",
    "foo.glb",            // glTF binary post-processed from the OBJ/MTL via SharpGLTF
    "foo.usdz"            // USDZ package bundled from the SDK's native USD folder
  ]
}
```

The endpoint returns `404 Not Found` when there is no conversion for the exchange — *including* when the only stored conversion was produced from a version the exchange has since moved past. An exchange's lineage URN doesn't change when a new version is published, but its contents do, so a stale conversion is reported as absent rather than as the current one. Requesting a new conversion (`POST`) discards the superseded artifacts and converts the current version; artifact fetches are gated the same way, so a stale USDZ is never served.

### Fetching an extraction artifact

```curl
GET https://data-exchange-conversion-service.azurewebsites.net/api/exchanges/{{collectionId}}/{{exchangeUrn}}/{{ArtifactFileName}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{exchangeUrn}}` | URL-encoded URN of your exchange | `urn%3Aadsk.wipprod%3Adm.lineage%3AlbJRla4QRhO-Xnu-1bEg5Q` |
| `{{collectionId}}` | URL-encoded Data Exchange collection ID (the ACC project ID) | `b.12345678-abcd-1234-abcd-1234567890ab` |
| `{{ArtifactFileName}}` | Name of the artifact file to fetch | `foo.obj` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

The endpoint will return the raw bytes of the requested artifact file, with the appropriate `Content-Type` header set.

### Deleting extracted geometry

> Note: this will only remove the extracted geometry, not the data exchange itself.

```curl
DELETE https://data-exchange-conversion-service.azurewebsites.net/api/exchanges/{{collectionId}}/{{exchangeUrn}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{exchangeUrn}}` | URL-encoded URN of your exchange | `urn%3Aadsk.wipprod%3Adm.lineage%3AlbJRla4QRhO-Xnu-1bEg5Q` |
| `{{collectionId}}` | URL-encoded Data Exchange collection ID (the ACC project ID) | `b.12345678-abcd-1234-abcd-1234567890ab` |
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
