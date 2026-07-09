# Deploying the Data Exchange Conversion Service to Azure

This guide walks through deploying the [DataExchangeConversionService](../DataExchangeConversionService) ASP.NET application to an Azure Web App, and publishing updates to it from Visual Studio.

## 1. Create the Azure Web App

In the [Azure Portal](https://portal.azure.com), go to **Create a resource** and select **Web App**.

![Create a resource](./azure-step-01.png)

On the **Basics** tab, configure the app:

- **Publish**: Code
- **Runtime stack**: .NET 10 (LTS)
- **Operating System**: Windows
- Pick the subscription, resource group, name, and region that fit your environment

![Web App Basics tab](./azure-step-02.png)

On the remaining tabs you can keep the defaults:

- **Database**: leave **Create a Database** unchecked

  ![Database tab](./azure-step-03.png)

- **Deployment**: leave **Continuous deployment** disabled (this guide publishes directly from Visual Studio instead)

  ![Deployment tab](./azure-step-04.png)

- **Networking**: leave public access enabled and virtual network integration disabled

  ![Networking tab](./azure-step-05.png)

- **Monitor + secure**: leave Application Insights disabled (or enable it if you want telemetry)

  ![Monitor + secure tab](./azure-step-06.png)

- **Tags**: none required

  ![Tags tab](./azure-step-07.png)

Finally, go to **Review + create**, verify the summary, and click **Create**.

![Review + create](./azure-step-08.png)

## 2. Configure the Web App platform and stack

Once the Web App is created, open it in the portal and go to **Settings > Configuration**.

On the **General settings** tab, set **Platform** to **64 Bit**.

![General settings - Platform](./azure-step-09.png)

On the **Stack settings** tab, set **Stack** to **.NET** and **.NET version** to **.NET 10 (LTS)**.

![Stack settings](./azure-step-10.png)

Click **Apply** to save the changes.

## 3. Create a publish profile in Visual Studio

With the `DataExchangeConversionService` project open in Visual Studio, right-click the project and select **Publish**.

Choose **Azure** as the publish target.

![Publish target](./publish-step-1.png)

Choose **Azure App Service (Windows)** as the specific target.

![Azure App Service (Windows)](./publish-step-2.png)

Select the Web App created in step 1.

![Select Web App](./publish-step-3.png)

Choose **Publish (generates pubxml file)** as the deployment type.

![Deployment type](./publish-step-4.png)

## 4. Configure the publish settings

In the generated publish profile, click the pencil icon next to **Settings** and set:

- **Configuration**: Debug
- **Target Framework**: net10.0-windows8
- **Deployment Mode**: Self-contained
- **Target Runtime**: win-x64

![Publish settings](./publish-step-5.png)

Save the settings. The publish profile summary should show **Ready to publish** with the settings above.

![Ready to publish](./publish-step-6.png)

Click **Publish** to deploy the application to the Azure Web App.
