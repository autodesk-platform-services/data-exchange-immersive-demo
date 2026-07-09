using DataExchangeConversionService.Models;
using DataExchangeConversionService.Options;
using Autodesk.DataExchange;
using Microsoft.Extensions.Options;
using System.Runtime;
using System.Text;
using System.Text.Json;

namespace DataExchangeConversionService.Services;

public sealed class ConversionService
{
    private const string MetadataFileName = "metadata.json";
    private const string LogFileName = "log.txt";
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
        if (Directory.Exists(outputFolder))
        {
            throw new InvalidOperationException($"Conversion already in progress for exchange {exchangeUrn}. Delete the current conversion first if you want to start it again.");
        }

        Directory.CreateDirectory(outputFolder);

        // Mark the conversion as running, then run it in the background.
        File.WriteAllText(Path.Combine(outputFolder, LogFileName), string.Empty);

        var metadata = new ConversionMetadata
        {
            Artifacts = [LogFileName]
        };
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
            ".txt" => "text/plain",
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
        var logPath = Path.Combine(outputFolder, LogFileName);

        // Track the step so a failure anywhere along the pipeline can be pinpointed from the
        // logs and from the metadata written back to disk.
        var currentStep = "initializing conversion";

        void Log(string message)
        {
            _logger.LogInformation(message);
            File.AppendAllText(logPath, $"{DateTimeOffset.UtcNow:O} {message}{Environment.NewLine}");
        }

        void Step(string description)
        {
            currentStep = description;
            Log($"Step: {description}.");
        }

        Log("Starting OBJ conversion.");

        try
        {
            Step("creating Data Exchange client");
            var client = CreateClient(bearerToken);

            Step("fetching exchange details");
            var details = await client.GetExchangeDetailsAsync(exchangeUrn);

            Step("downloading exchange as OBJ");
            var response = client.DownloadCompleteExchangeAsOBJ(
                details.ExchangeID,
                details.CollectionID,
                outputFolder,
                CancellationToken.None);

            var tempFolder = response.Value;
            Log("Data Exchange extraction completed.");

            foreach (var sourcePath in Directory.GetFiles(tempFolder))
            {
                var fileName = Path.GetFileName(sourcePath);
                var destinationPath = Path.Combine(outputFolder, fileName);
                Step($"moving extracted artifact {fileName}");
                File.Move(sourcePath, destinationPath, overwrite: true);
                metadata.Artifacts.Add(fileName);
            }

            Step("deleting temp folder");
            Directory.Delete(tempFolder, recursive: true);
            ForceFullGarbageCollection(_logger, "Data Exchange to OBJ conversion");

            // Post-process each generated OBJ into a self-contained binary glTF (*.glb) and a
            // USDZ package (*.usdz).
            foreach (var objFileName in metadata.Artifacts
                .Where(name => name.EndsWith(".obj", StringComparison.OrdinalIgnoreCase))
                .ToList())
            {
                var objPath = Path.Combine(outputFolder, objFileName);
                var memory = new MemoryTelemetry(_logger, "Exchange post-processing", logPath);

                // The extraction emits Z-up geometry; both converters rotate it to the Y-up
                // convention that OBJ/glTF/USD viewers assume on the fly as they stream the OBJ.
                var glbFileName = Path.ChangeExtension(objFileName, ".glb");
                var glbPath = Path.Combine(outputFolder, glbFileName);
                Step($"converting OBJ {objFileName} to GLB {glbFileName}");
                using (memory.Step("convert OBJ to GLB"))
                {
                    GltfConverter.ConvertObjToGlb(objPath, glbPath, convertZUpToYUp: true, logger: _logger, logPath: logPath);
                }
                metadata.Artifacts.Add(glbFileName);
                ForceFullGarbageCollection(_logger, "OBJ to GLB conversion");

                var usdzFileName = Path.ChangeExtension(objFileName, ".usdz");
                var usdzPath = Path.Combine(outputFolder, usdzFileName);
                Step($"converting OBJ {objFileName} to USDZ {usdzFileName}");
                using (memory.Step("convert OBJ to USDZ"))
                {
                    UsdzConverter.ConvertObjToUsdz(objPath, usdzPath, convertZUpToYUp: true, logger: _logger, logPath: logPath);
                }
                metadata.Artifacts.Add(usdzFileName);
                ForceFullGarbageCollection(_logger, "OBJ to USDZ conversion");
            }

            metadata.Status = ConversionStatus.Completed;
            Log($"OBJ conversion completed. Artifacts: {string.Join(", ", metadata.Artifacts)}.");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "OBJ conversion failed while {Step}.", currentStep);
            File.AppendAllText(logPath, $"{DateTimeOffset.UtcNow:O} [Error] Failed while {currentStep}.{Environment.NewLine}{ex}{Environment.NewLine}");

            metadata.Status = ConversionStatus.Failed;
            // Persist the failing step and the full exception (type, message, stack trace,
            // inner exceptions) so the failure is diagnosable from metadata.json alone.
            metadata.Error = $"Failed while {currentStep}. {ex}";
        }

        WriteMetadata(outputFolder, metadata);
    }

    // TODO: remove alongside MemoryTelemetry once the memory investigation is done.

    private static void ForceFullGarbageCollection(ILogger logger, string reason)
    {
        var beforeBytes = GC.GetTotalMemory(forceFullCollection: false);

        GCSettings.LargeObjectHeapCompactionMode = GCLargeObjectHeapCompactionMode.CompactOnce;
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);
        GC.WaitForPendingFinalizers();
        GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, blocking: true, compacting: true);

        var afterBytes = GC.GetTotalMemory(forceFullCollection: false);
        logger.LogInformation(
            "Forced garbage collection after {Reason}. Managed memory: {BeforeBytes} -> {AfterBytes} bytes.",
            reason,
            beforeBytes,
            afterBytes);
    }

    private static Client CreateClient(string bearerToken)
    {
        return new Client(new SDKOptionsDefaultSetup
        {
            ClientId = "pass-through",
            ConnectorName = "DataExchangeViewingService",
            ConnectorVersion = "1.0.0",
            HostApplicationName = "DataExchangeViewingService",
            HostApplicationVersion = "1.0.0",
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
