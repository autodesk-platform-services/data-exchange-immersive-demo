# DataExchangeConversionService

Simple ASP.NET application extracting geometry data from [Data Exchanges](https://aps.autodesk.com/data-exchange-cover-page) using the [Public Beta SDK](https://aps.autodesk.com/en/docs/dx-sdk-beta/v1/changelog/v1changelog/).

## Live demo

The application is deployed to an Azure Web App. Here's how you can try it out:

### Extracting geometry from an exchange

```curl
POST https://data-exchange-viewing-service.azurewebsites.net/api/exchanges/{{DataExchangeUrn}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{DataExchangeUrn}}` | URL-encoded URN of your exchange | `urn%3Aadsk.wipprod%3Adm.lineage%3AlbJRla4QRhO-Xnu-1bEg5Q` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

The endpoint will return `202 Accepted` to indicate that the conversion has started in the background.

### Checking status of an extraction

```curl
GET https://data-exchange-viewing-service.azurewebsites.net/api/exchanges/{{DataExchangeUrn}}
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

### Deleting extracted geometry

> Note: this will only remove the extracted geometry, not the data exchange itself.

```curl
DELETE https://data-exchange-viewing-service.azurewebsites.net/api/exchanges/{{DataExchangeUrn}}
Authorization: Bearer {{AccessToken}}
```

| Parameter | Description | Example |
| --- | --- | --- |
| `{{DataExchangeUrn}}` | URL-encoded URN of your exchange | `urn%3Aadsk.wipprod%3Adm.lineage%3AlbJRla4QRhO-Xnu-1bEg5Q` |
| `{{AccessToken}}` | access token that has a read access to your exchange | `eyJhb...` |

## Running locally

### Prerequisites

- Visual Studio with the _ASP.NET and web development_ workload and _.NET 10_ installed
- Data Exchange SDK 7.4.0 Public Beta (available on our [Feedback Portal](https://feedback.autodesk.com/project/home.html?cap=40e7f0ad-ab3a-46b0-819a-ae2fc4f7a25f&display=personal))
- Existing data exchange in [Autodesk Forma](https://acc.autodesk.com)

### Steps

- Download the following NuGet packages from the feedback portal, and place them in a `packages` subfolder in the repository (next to the *.slnx file):
  - `Autodesk.DataExchange.7.4.0-beta.nupkg`
  - `Autodesk.DataExchange.GeometryDefinitions.0.1.12.nupkg`
  - `Autodesk.Newtonsoft.Json.13.0.3.nupkg`
  - `forgeparameters_win_release_intel64_v140.40.1.nupkg`
  - `forgeunits_win_release_intel64_v140.5.3.2.nupkg`
- Build and run the solution
- Try the endpoints listed in the [Live demo](#live-demo) section against https://localhost:7008

## Deploying to Azure

TBD
