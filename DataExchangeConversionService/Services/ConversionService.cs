using DataExchangeViewingService.Models;
using DataExchangeViewingService.Options;
using Autodesk.DataExchange;
using Microsoft.Extensions.Options;
using System.Text;
using System.Text.Json;
using System.Diagnostics;

namespace DataExchangeViewingService.Services;

public sealed class ConversionService : IConversionService
{
    private const string MetadataFileName = "metadata.json";
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly IWebHostEnvironment _environment;
    private readonly Options.Options _options;

    public ConversionService(IWebHostEnvironment environment, IOptions<Options.Options> options)
    {
        _environment = environment;
        _options = options.Value;
    }

    public async Task<bool> HasAccessAsync(string exchangeUrn, string bearerToken)
    {
        // The exchange details call only succeeds for tokens that can access the exchange.
        try
        {
            var details = await CreateClient(bearerToken).GetExchangeDetailsAsync(exchangeUrn);
            return !string.IsNullOrWhiteSpace(details.ExchangeID);
        }
        catch
        {
            return false;
        }
    }

    public ConversionMetadata? GetStatus(string exchangeUrn)
    {
        var metadataPath = Path.Combine(GetExchangeOutputFolder(exchangeUrn), MetadataFileName);
        return File.Exists(metadataPath)
            ? JsonSerializer.Deserialize<ConversionMetadata>(File.ReadAllText(metadataPath), JsonOptions)
            : null;
    }

    public void StartObjConversion(string exchangeUrn, string bearerToken)
    {
        var outputFolder = GetExchangeOutputFolder(exchangeUrn);
        Directory.CreateDirectory(outputFolder);

        // Mark the conversion as running, then run it in the background.
        var metadata = new ConversionMetadata();
        WriteMetadata(outputFolder, metadata);
        _ = Task.Run(() => RunObjConversionAsync(exchangeUrn, bearerToken, outputFolder, metadata));
    }

    public void DeleteObjConversion(string exchangeUrn)
    {
        var outputFolder = GetExchangeOutputFolder(exchangeUrn);
        if (Directory.Exists(outputFolder))
        {
            Directory.Delete(outputFolder, true);
        }
    }

    public Artifact? GetArtifact(string exchangeUrn, string artifactName)
    {
        // GetFileName strips any directory parts, so the lookup stays inside the output folder.
        var artifactPath = Path.Combine(GetExchangeOutputFolder(exchangeUrn), Path.GetFileName(artifactName));
        if (!File.Exists(artifactPath))
        {
            return null;
        }

        var contentType = Path.GetExtension(artifactName).ToLowerInvariant() switch
        {
            ".obj" => "model/obj",
            ".glb" => "model/gltf-binary",
            ".usdz" => "model/vnd.usdz+zip",
            _ => "application/octet-stream",
        };
        return new Artifact(File.ReadAllBytes(artifactPath), Path.GetFileName(artifactPath), contentType);
    }

    private async Task RunObjConversionAsync(
        string exchangeUrn,
        string bearerToken,
        string outputFolder,
        ConversionMetadata metadata)
    {
        try
        {
            var client = CreateClient(bearerToken);
            Debug.WriteLine($"Starting OBJ conversion for exchange {exchangeUrn} with output folder {outputFolder}.");
            var details = await client.GetExchangeDetailsAsync(exchangeUrn);
            var response = client.DownloadCompleteExchangeAsOBJ(
                details.ExchangeID,
                details.CollectionID,
                outputFolder,
                CancellationToken.None);

            var tempFolder = response.Value;
            foreach (var sourcePath in Directory.GetFiles(tempFolder))
            {
                var fileName = Path.GetFileName(sourcePath);
                File.Move(sourcePath, Path.Combine(outputFolder, fileName), overwrite: true);
                metadata.Artifacts.Add(fileName);
            }
            Directory.Delete(tempFolder, recursive: true);

            // Post-process each generated OBJ into a self-contained binary glTF (*.glb) and a
            // USDZ package (*.usdz).
            foreach (var objFileName in metadata.Artifacts
                .Where(name => name.EndsWith(".obj", StringComparison.OrdinalIgnoreCase))
                .ToList())
            {
                var objPath = Path.Combine(outputFolder, objFileName);

                // The extraction emits Z-up geometry; rotate the OBJ to the Y-up convention that
                // OBJ/glTF/USD viewers assume before deriving the GLB and USDZ artifacts from it.
                ObjModel.ConvertZUpToYUp(objPath);

                var glbFileName = Path.ChangeExtension(objFileName, ".glb");
                GltfConverter.ConvertObjToGlb(
                    objPath,
                    Path.Combine(outputFolder, glbFileName));
                metadata.Artifacts.Add(glbFileName);

                var usdzFileName = Path.ChangeExtension(objFileName, ".usdz");
                UsdzConverter.ConvertObjToUsdz(
                    objPath,
                    Path.Combine(outputFolder, usdzFileName));
                metadata.Artifacts.Add(usdzFileName);
            }

            metadata.Status = ConversionStatus.Completed;
        }
        catch (Exception ex)
        {
            metadata.Status = ConversionStatus.Failed;
            metadata.Error = ex.Message;
        }

        WriteMetadata(outputFolder, metadata);
    }

    private Client CreateClient(string bearerToken)
    {
        return new Client(new SDKOptionsDefaultSetup
        {
            ClientId = "pass-through",
            ConnectorName = _options.ConnectorName,
            ConnectorVersion = _options.ConnectorVersion,
            HostApplicationName = _options.HostApplicationName,
            HostApplicationVersion = _options.HostApplicationVersion,
            AuthProvider = new BearerTokenAuthProvider(bearerToken),
        });
    }

    private static void WriteMetadata(string outputFolder, ConversionMetadata metadata)
    {
        var metadataPath = Path.Combine(outputFolder, MetadataFileName);
        File.WriteAllText(metadataPath, JsonSerializer.Serialize(metadata, JsonOptions));
    }

    private string GetExchangeOutputFolder(string exchangeUrn)
    {
        var outputFolder = Path.IsPathRooted(_options.OutputFolder)
            ? _options.OutputFolder
            : Path.Combine(_environment.ContentRootPath, _options.OutputFolder);

        return Path.Combine(outputFolder, CreateCacheKey(exchangeUrn));
    }

    private static string CreateCacheKey(string exchangeUrn)
    {
        return Convert.ToBase64String(Encoding.UTF8.GetBytes(exchangeUrn));
    }
}
