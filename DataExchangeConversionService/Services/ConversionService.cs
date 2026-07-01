using DataExchangeViewingService.Models;
using DataExchangeViewingService.Options;
using Autodesk.DataExchange;
using Microsoft.Extensions.Options;
using System.Text;
using System.Text.Json;

namespace DataExchangeViewingService.Services;

public sealed class ConversionService : IConversionService
{
    private const string MetadataFileName = "metadata.json";
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web);

    private readonly IWebHostEnvironment _environment;
    private readonly Options.Options _options;
    private readonly ILogger<ConversionService> _logger;

    public ConversionService(
        IWebHostEnvironment environment,
        IOptions<Options.Options> options,
        ILogger<ConversionService> logger)
    {
        _environment = environment;
        _options = options.Value;
        _logger = logger;
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
        // Start each run from a clean slate.
        DeleteFolderIfExists(outputFolder);
        Directory.CreateDirectory(outputFolder);

        // Mark the conversion as running, then run it in the background.
        var metadata = new ConversionMetadata();
        WriteMetadata(outputFolder, metadata);
        _ = Task.Run(() => RunObjConversionAsync(exchangeUrn, bearerToken, outputFolder, metadata));
    }

    public void DeleteObjConversion(string exchangeUrn)
    {
        DeleteFolderIfExists(GetExchangeOutputFolder(exchangeUrn));
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
        // Track the step (and the paths it touches) so a failure anywhere along the pipeline
        // can be pinpointed from the logs and from the metadata written back to disk.
        var currentStep = "initializing conversion";
        _logger.LogInformation(
            "Starting OBJ conversion for exchange {ExchangeUrn} into {OutputFolder}.",
            exchangeUrn,
            outputFolder);

        try
        {
            currentStep = "creating Data Exchange client";
            _logger.LogInformation("Step: {Step}.", currentStep);
            var client = CreateClient(bearerToken);

            currentStep = $"fetching exchange details for {exchangeUrn}";
            _logger.LogInformation("Step: {Step}.", currentStep);
            var details = await client.GetExchangeDetailsAsync(exchangeUrn);

            currentStep = $"downloading exchange {details.ExchangeID} (collection {details.CollectionID}) as OBJ into {outputFolder}";
            _logger.LogInformation("Step: {Step}.", currentStep);
            var response = client.DownloadCompleteExchangeAsOBJ(
                details.ExchangeID,
                details.CollectionID,
                outputFolder,
                CancellationToken.None);

            var tempFolder = response.Value;
            _logger.LogInformation(
                "Data Exchange extraction produced files in temp folder {TempFolder}.",
                tempFolder);

            foreach (var sourcePath in Directory.GetFiles(tempFolder))
            {
                var fileName = Path.GetFileName(sourcePath);
                var destinationPath = Path.Combine(outputFolder, fileName);
                currentStep = $"moving extracted artifact {sourcePath} -> {destinationPath}";
                _logger.LogInformation("Step: {Step}.", currentStep);
                File.Move(sourcePath, destinationPath, overwrite: true);
                metadata.Artifacts.Add(fileName);
            }

            currentStep = $"deleting temp folder {tempFolder}";
            _logger.LogInformation("Step: {Step}.", currentStep);
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
                var memory = new MemoryTelemetry(_logger, $"Exchange post-processing");

                currentStep = $"rotating OBJ {objPath} from Z-up to Y-up (writes {objPath}.tmp then moves it over the original)";
                _logger.LogInformation("Step: {Step}.", currentStep);
                using (memory.Step("rotate OBJ Z-up to Y-up"))
                {
                    ObjModel.ConvertZUpToYUp(objPath);
                }

                var glbFileName = Path.ChangeExtension(objFileName, ".glb");
                var glbPath = Path.Combine(outputFolder, glbFileName);
                currentStep = $"converting OBJ {objPath} to GLB {glbPath}";
                _logger.LogInformation("Step: {Step}.", currentStep);
                using (memory.Step("convert OBJ to GLB"))
                {
                    GltfConverter.ConvertObjToGlb(objPath, glbPath, _logger);
                }
                metadata.Artifacts.Add(glbFileName);

                var usdzFileName = Path.ChangeExtension(objFileName, ".usdz");
                var usdzPath = Path.Combine(outputFolder, usdzFileName);
                currentStep = $"converting OBJ {objPath} to USDZ {usdzPath}";
                _logger.LogInformation("Step: {Step}.", currentStep);
                using (memory.Step("convert OBJ to USDZ"))
                {
                    UsdzConverter.ConvertObjToUsdz(objPath, usdzPath, _logger);
                }
                metadata.Artifacts.Add(usdzFileName);
            }

            metadata.Status = ConversionStatus.Completed;
            _logger.LogInformation(
                "OBJ conversion completed for exchange {ExchangeUrn}. Artifacts: {Artifacts}.",
                exchangeUrn,
                string.Join(", ", metadata.Artifacts));
        }
        catch (Exception ex)
        {
            _logger.LogError(
                ex,
                "OBJ conversion failed for exchange {ExchangeUrn} while {Step}.",
                exchangeUrn,
                currentStep);

            metadata.Status = ConversionStatus.Failed;
            // Persist the failing step and the full exception (type, message, stack trace,
            // inner exceptions) so the failure is diagnosable from metadata.json alone.
            metadata.Error = $"Failed while {currentStep}. {ex}";
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

    // Deletes the folder and everything inside it.
    private static void DeleteFolderIfExists(string path)
    {
        if (!Directory.Exists(path))
        {
            return;
        }

        Directory.Delete(path, recursive: true);
    }
}
