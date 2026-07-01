using DataExchangeViewingService.Models;
using DataExchangeViewingService.Options;
using Autodesk.DataExchange;
using Microsoft.Extensions.Options;
using System.Runtime;
using System.Text;
using System.Text.Json;

namespace DataExchangeViewingService.Services;

public sealed class ConversionService : IConversionService
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

    public bool StartObjConversion(string exchangeUrn, string bearerToken)
    {
        var outputFolder = GetExchangeOutputFolder(exchangeUrn);
        if (Directory.Exists(outputFolder))
        {
            return false;
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
        return true;
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
        using var logger = new ConversionLogger(_logger, Path.Combine(outputFolder, LogFileName));

        // Track the step so a failure anywhere along the pipeline can be pinpointed from the
        // logs and from the metadata written back to disk.
        var currentStep = "initializing conversion";
        logger.LogInformation("Starting OBJ conversion.");

        try
        {
            currentStep = "creating Data Exchange client";
            logger.LogInformation("Step: {Step}.", currentStep);
            var client = CreateClient(bearerToken);

            currentStep = "fetching exchange details";
            logger.LogInformation("Step: {Step}.", currentStep);
            var details = await client.GetExchangeDetailsAsync(exchangeUrn);

            currentStep = "downloading exchange as OBJ";
            logger.LogInformation("Step: {Step}.", currentStep);
            var response = client.DownloadCompleteExchangeAsOBJ(
                details.ExchangeID,
                details.CollectionID,
                outputFolder,
                CancellationToken.None);

            var tempFolder = response.Value;
            logger.LogInformation("Data Exchange extraction completed.");

            foreach (var sourcePath in Directory.GetFiles(tempFolder))
            {
                var fileName = Path.GetFileName(sourcePath);
                var destinationPath = Path.Combine(outputFolder, fileName);
                currentStep = $"moving extracted artifact {fileName}";
                logger.LogInformation("Step: {Step}.", currentStep);
                File.Move(sourcePath, destinationPath, overwrite: true);
                metadata.Artifacts.Add(fileName);
            }

            currentStep = "deleting temp folder";
            logger.LogInformation("Step: {Step}.", currentStep);
            Directory.Delete(tempFolder, recursive: true);
            ForceFullGarbageCollection(logger, "Data Exchange to OBJ conversion");

            // Post-process each generated OBJ into a self-contained binary glTF (*.glb) and a
            // USDZ package (*.usdz).
            foreach (var objFileName in metadata.Artifacts
                .Where(name => name.EndsWith(".obj", StringComparison.OrdinalIgnoreCase))
                .ToList())
            {
                var objPath = Path.Combine(outputFolder, objFileName);

                // The extraction emits Z-up geometry; rotate the OBJ to the Y-up convention that
                // OBJ/glTF/USD viewers assume before deriving the GLB and USDZ artifacts from it.
                var memory = new MemoryTelemetry(logger, "Exchange post-processing");

                currentStep = $"rotating OBJ {objFileName} from Z-up to Y-up";
                logger.LogInformation("Step: {Step}.", currentStep);
                using (memory.Step("rotate OBJ Z-up to Y-up"))
                {
                    ObjModel.ConvertZUpToYUp(objPath);
                }

                var glbFileName = Path.ChangeExtension(objFileName, ".glb");
                var glbPath = Path.Combine(outputFolder, glbFileName);
                currentStep = $"converting OBJ {objFileName} to GLB {glbFileName}";
                logger.LogInformation("Step: {Step}.", currentStep);
                using (memory.Step("convert OBJ to GLB"))
                {
                    GltfConverter.ConvertObjToGlb(objPath, glbPath, logger);
                }
                metadata.Artifacts.Add(glbFileName);
                ForceFullGarbageCollection(logger, "OBJ to GLB conversion");

                var usdzFileName = Path.ChangeExtension(objFileName, ".usdz");
                var usdzPath = Path.Combine(outputFolder, usdzFileName);
                currentStep = $"converting OBJ {objFileName} to USDZ {usdzFileName}";
                logger.LogInformation("Step: {Step}.", currentStep);
                using (memory.Step("convert OBJ to USDZ"))
                {
                    UsdzConverter.ConvertObjToUsdz(objPath, usdzPath, logger);
                }
                metadata.Artifacts.Add(usdzFileName);
                ForceFullGarbageCollection(logger, "OBJ to USDZ conversion");
            }

            metadata.Status = ConversionStatus.Completed;
            logger.LogInformation("OBJ conversion completed. Artifacts: {Artifacts}.", string.Join(", ", metadata.Artifacts));
        }
        catch (Exception ex)
        {
            logger.LogError(
                ex,
                "OBJ conversion failed while {Step}.",
                currentStep);

            metadata.Status = ConversionStatus.Failed;
            // Persist the failing step and the full exception (type, message, stack trace,
            // inner exceptions) so the failure is diagnosable from metadata.json alone.
            metadata.Error = $"Failed while {currentStep}. {ex}";
        }

        WriteMetadata(outputFolder, metadata);
    }

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

    private sealed class ConversionLogger(ILogger innerLogger, string path) : ILogger, IDisposable
    {
        private readonly object _gate = new();

        public IDisposable? BeginScope<TState>(TState state)
            where TState : notnull
        {
            return innerLogger.BeginScope(state);
        }

        public bool IsEnabled(LogLevel logLevel)
        {
            return innerLogger.IsEnabled(logLevel);
        }

        public void Log<TState>(
            LogLevel logLevel,
            EventId eventId,
            TState state,
            Exception? exception,
            Func<TState, Exception?, string> formatter)
        {
            innerLogger.Log(logLevel, eventId, state, exception, formatter);

            var message = formatter(state, exception);
            if (string.IsNullOrWhiteSpace(message) && exception is null)
            {
                return;
            }

            var line = $"{DateTimeOffset.UtcNow:O} [{logLevel}] {message}";
            if (exception is not null)
            {
                line += Environment.NewLine + exception;
            }

            lock (_gate)
            {
                File.AppendAllText(path, line + Environment.NewLine);
            }
        }

        public void Dispose()
        {
        }
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
