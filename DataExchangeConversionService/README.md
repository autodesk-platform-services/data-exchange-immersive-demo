# Data Exchange Conversion Service

Simple ASP.NET application extracting geometry data from [Data Exchanges](https://aps.autodesk.com/data-exchange-cover-page) using the [Public Beta SDK](https://aps.autodesk.com/en/docs/dx-sdk-beta/v1/changelog/v1changelog/).

## Live demo

The application is deployed to an Azure Web App. Here's how you can try it out:

> [!WARNING]
> The live server at `data-exchange-conversion-service.azurewebsites.net` is a demo deployment and may only be available occasionally (e.g. scaled down or stopped between demos). If requests to it start timing out or failing, run the service locally instead — see [Running locally](#running-locally) below.

### Extracting geometry from an exchange

```curl
POST https://data-exchange-conversion-service.azurewebsites.net/api/exchanges/{{DataExchangeUrn}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{DataExchangeUrn}}` | URL-encoded URN of your exchange | `urn%3Aadsk.wipprod%3Adm.lineage%3AlbJRla4QRhO-Xnu-1bEg5Q` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

The endpoint will return `202 Accepted` to indicate that the conversion has started in the background.

### Checking status of an extraction

```curl
GET https://data-exchange-conversion-service.azurewebsites.net/api/exchanges/{{DataExchangeUrn}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{DataExchangeUrn}}` | URL-encoded URN of your exchange | `urn%3Aadsk.wipprod%3Adm.lineage%3AlbJRla4QRhO-Xnu-1bEg5Q` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

The endpoint will return JSON object with extraction metadata:

```jsonc
{
  "status": "completed",  // "running" | "completed" | "failed"
  "error": null,          // Error message in case "status" is "failed"
  "artifacts": [          // List of filenames of generated artifacts in case "status" is "completed"
    "foo.obj",
    "foo.mtl",
    "foo.glb",            // glTF binary post-processed from the OBJ/MTL via SharpGLTF
    "foo.usdz"            // USDZ package post-processed from the OBJ/MTL
  ]
}
```

### Fetching an extraction artifact

```curl
GET https://data-exchange-conversion-service.azurewebsites.net/api/exchanges/{{DataExchangeUrn}}/{{ArtifactFileName}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{DataExchangeUrn}}` | URL-encoded URN of your exchange | `urn%3Aadsk.wipprod%3Adm.lineage%3AlbJRla4QRhO-Xnu-1bEg5Q` |
| `{{ArtifactFileName}}` | Name of the artifact file to fetch | `foo.obj` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

The endpoint will return the raw bytes of the requested artifact file, with the appropriate `Content-Type` header set.

### Deleting extracted geometry

> Note: this will only remove the extracted geometry, not the data exchange itself.

```curl
DELETE https://data-exchange-conversion-service.azurewebsites.net/api/exchanges/{{DataExchangeUrn}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{DataExchangeUrn}}` | URL-encoded URN of your exchange | `urn%3Aadsk.wipprod%3Adm.lineage%3AlbJRla4QRhO-Xnu-1bEg5Q` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

## Running locally

### Prerequisites

- Visual Studio with the _ASP.NET and web development_ workload and _.NET 10_ installed
- Data Exchange SDK 7.5.0 Public Beta (available on our [Feedback Portal](https://feedback.autodesk.com/project/version/item.html?cap=40e7f0adab3a46b0819aae2fc4f7a25f&artid=366cffebe97842a8893bd2cedbb39788))
- Existing data exchange in [Autodesk Forma](https://acc.autodesk.com)

### Steps

- Download the following NuGet packages from the feedback portal, and place them in a `packages` subfolder in the repository (next to the *.slnx file):
  - `Autodesk.DataExchange.7.5.0-beta.nupkg`
  - `Autodesk.DataExchange.GeometryDefinitions.0.9.3.nupkg`
- Build and run the solution
- Try the endpoints listed in the [Live demo](#live-demo) section against https://localhost:7008

## Deploying to Azure

See [docs/deploying-to-azure.md](../docs/deploying-to-azure.md).
