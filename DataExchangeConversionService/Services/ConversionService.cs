using DataExchangeConversionService.Models;
using DataExchangeConversionService.Options;
using Autodesk.DataExchange;
using Autodesk.DataExchange.Core.Models;
using Microsoft.Extensions.Options;
using System.Runtime;
using System.Security.Cryptography;
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

    // Resolves the exchange for a bearer token, or null when the token cannot read it. The
    // exchange details call only succeeds for tokens that have access, and it also reports the
    // exchange's current version — which is what decides whether a stored conversion is still a
    // conversion of what the exchange contains now.
    public async Task<ExchangeIdentity?> ResolveExchangeAsync(JobId job, string bearerToken)
    {
        try
        {
            var detailsResponse = await CreateClient(bearerToken)
                .GetExchangeDetailsAsync(job.CollectionId, job.ExchangeUrn);
            if (!detailsResponse.IsSuccess)
            {
                _logger.LogWarning(
                    "Data Exchange SDK could not resolve exchange {ExchangeUrn} in collection {CollectionId}: {Errors}",
                    job.ExchangeUrn,
                    job.CollectionId,
                    string.Join("; ", detailsResponse.Errors));
                return null;
            }

            var details = detailsResponse.Value;
            return string.IsNullOrWhiteSpace(details.ExchangeID)
                ? null
                : new ExchangeIdentity(job, details.FileVersionUrn);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Data Exchange SDK failed to resolve exchange {ExchangeUrn} in collection {CollectionId}.",
                job.ExchangeUrn,
                job.CollectionId);
            return null;
        }
    }

    public ConversionMetadata? GetStatus(ExchangeIdentity exchange)
    {
        var metadata = ReadMetadata(GetJobOutputFolder(exchange.Job));
        if (metadata is null)
        {
            return null;
        }

        // A conversion produced from an earlier version of the exchange is not a conversion of
        // what the exchange contains now. Reporting it as present is how a client ends up
        // previewing last week's geometry and being told it is current, so it is reported as
        // absent instead and re-converted on request.
        return IsCurrent(metadata, exchange) ? metadata : null;
    }

    public void StartObjConversion(ExchangeIdentity exchange, string bearerToken)
    {
        var outputFolder = GetJobOutputFolder(exchange.Job);
        if (Directory.Exists(outputFolder))
        {
            if (GetStatus(exchange) is not null)
            {
                throw new InvalidOperationException($"Conversion already in progress for exchange {exchange.Job.ExchangeUrn}. Delete the current conversion first if you want to start it again.");
            }

            // Anything still on disk was produced from a version that has since been superseded
            // (the caller has already been told about a conversion of the current one). Replacing
            // it keeps one folder per exchange rather than accumulating a copy of every version
            // ever converted — these artifacts run to hundreds of megabytes each.
            _logger.LogInformation(
                "Discarding a conversion of a superseded version of exchange {ExchangeUrn}.",
                exchange.Job.ExchangeUrn);
            DeleteFolderIfExists(outputFolder);
        }

        Directory.CreateDirectory(outputFolder);

        // Mark the conversion as running, then run it in the background.
        File.WriteAllText(Path.Combine(outputFolder, LogFileName), string.Empty);

        var metadata = new ConversionMetadata
        {
            Artifacts = [LogFileName],
            FileVersionUrn = exchange.FileVersionUrn
        };
        WriteMetadata(outputFolder, metadata);
        _ = Task.Run(() => RunObjConversionAsync(exchange.Job, bearerToken, outputFolder, metadata));
    }

    public void DeleteObjConversion(JobId job)
    {
        // Keyed on the job alone, so this removes whichever version's conversion is stored —
        // including one this service now considers superseded.
        DeleteFolderIfExists(GetJobOutputFolder(job));
    }

    public Artifact? GetArtifact(ExchangeIdentity exchange, string artifactName)
    {
        // Gated the same way as the status, so an artifact left over from a superseded version is
        // never served — not even to a client that asks for it by name.
        if (GetStatus(exchange) is null)
        {
            return null;
        }

        // GetFileName strips any directory parts, so the lookup stays inside the output folder.
        var artifactPath = Path.Combine(GetJobOutputFolder(exchange.Job), Path.GetFileName(artifactName));
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
        return new Artifact(artifactPath, Path.GetFileName(artifactPath), contentType);
    }

    private async Task RunObjConversionAsync(
        JobId job,
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
            var detailsResponse = await client.GetExchangeDetailsAsync(job.CollectionId, job.ExchangeUrn);
            if (!detailsResponse.IsSuccess)
            {
                throw new InvalidOperationException(
                    $"The Data Exchange SDK could not fetch exchange details: {string.Join("; ", detailsResponse.Errors)}");
            }

            var details = detailsResponse.Value;
            // The version the artifacts are actually produced from, which is what a later status
            // check compares against. Read again here rather than trusted from the request, in
            // case a new version was published between the two.
            if (!string.IsNullOrWhiteSpace(details.FileVersionUrn))
            {
                metadata.FileVersionUrn = details.FileVersionUrn;
            }

            var exchangeIdentifier = new DataExchangeIdentifier
            {
                ExchangeId = details.ExchangeID,
                CollectionId = details.CollectionID,
                HubId = details.HubId,
            };

            Step("downloading exchange as OBJ");
            var downloadResponse = client.DownloadCompleteExchangeAsOBJ(
                exchangeIdentifier,
                outputFolder,
                CancellationToken.None);

            if (!downloadResponse.IsSuccess)
            {
                throw new InvalidOperationException(
                    $"The Data Exchange SDK could not download the exchange as OBJ: {string.Join("; ", downloadResponse.Errors)}");
            }

            var tempFolder = GetDownloadFolder(downloadResponse.Value, "OBJ");
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

            // Post-process each generated OBJ into a self-contained binary glTF (*.glb).
            // USDZ is built separately from the SDK's native USD output below.
            var objFileNames = metadata.Artifacts
                .Where(name => name.EndsWith(".obj", StringComparison.OrdinalIgnoreCase))
                .ToList();
            foreach (var objFileName in objFileNames)
            {
                var objPath = Path.Combine(outputFolder, objFileName);
                var memory = new MemoryTelemetry(_logger, "Exchange post-processing", logPath);

                // The extraction emits Z-up geometry; rotate it to the Y-up convention used by
                // glTF viewers while streaming the OBJ.
                var glbFileName = Path.ChangeExtension(objFileName, ".glb");
                var glbPath = Path.Combine(outputFolder, glbFileName);
                Step($"converting OBJ {objFileName} to GLB {glbFileName}");
                using (memory.Step("convert OBJ to GLB"))
                {
                    GltfConverter.ConvertObjToGlb(objPath, glbPath, convertZUpToYUp: true, logger: _logger, logPath: logPath);
                }
                metadata.Artifacts.Add(glbFileName);
                ForceFullGarbageCollection(_logger, "OBJ to GLB conversion");
            }

            Step("downloading exchange as USD");
            var usdDownloadResponse = client.DownloadCompleteExchangeAsUSD(
                exchangeIdentifier,
                outputFolder,
                CancellationToken.None);

            if (!usdDownloadResponse.IsSuccess)
            {
                throw new InvalidOperationException(
                    $"The Data Exchange SDK could not download the exchange as USD: {string.Join("; ", usdDownloadResponse.Errors)}");
            }

            var usdFolder = GetDownloadFolder(usdDownloadResponse.Value, "USD");
            Log("Data Exchange USD extraction completed.");

            var usdzFileName = objFileNames.Count > 0
                ? Path.ChangeExtension(objFileNames[0], ".usdz")
                : "exchange.usdz";
            var usdzPath = Path.Combine(outputFolder, usdzFileName);
            Step($"bundling downloaded USD files into {usdzFileName}");
            UsdzConverter.BundleUsdFolder(usdFolder, usdzPath, _logger, logPath);
            metadata.Artifacts.Add(usdzFileName);

            Step("deleting USD temp folder");
            Directory.Delete(usdFolder, recursive: true);
            ForceFullGarbageCollection(_logger, "USD to USDZ bundling");

            metadata.Status = ConversionStatus.Completed;
            Log($"Exchange conversion completed. Artifacts: {string.Join(", ", metadata.Artifacts)}.");
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

    private static string GetDownloadFolder(string downloadPath, string format)
    {
        if (Directory.Exists(downloadPath))
        {
            return downloadPath;
        }

        if (File.Exists(downloadPath))
        {
            return Path.GetDirectoryName(downloadPath)
                ?? throw new InvalidOperationException(
                    $"The Data Exchange SDK returned a {format} file path without a parent folder: '{downloadPath}'.");
        }

        throw new FileNotFoundException(
            $"The Data Exchange SDK returned a {format} download path that does not exist: '{downloadPath}'.",
            downloadPath);
    }

    private static void WriteMetadata(string outputFolder, ConversionMetadata metadata)
    {
        var metadataPath = Path.Combine(outputFolder, MetadataFileName);
        File.WriteAllText(metadataPath, JsonSerializer.Serialize(metadata, JsonOptions));
    }

    private static ConversionMetadata? ReadMetadata(string outputFolder)
    {
        var metadataPath = Path.Combine(outputFolder, MetadataFileName);
        return File.Exists(metadataPath)
            ? JsonSerializer.Deserialize<ConversionMetadata>(File.ReadAllText(metadataPath), JsonOptions)
            : null;
    }

    // Whether a stored conversion belongs to the exchange's current version. Both URNs missing
    // is treated as current: either the exchange reports no version, or the conversion predates
    // this field being recorded, and in both cases the pre-version behaviour is the honest
    // fallback rather than discarding a conversion on a guess.
    private static bool IsCurrent(ConversionMetadata metadata, ExchangeIdentity exchange)
    {
        if (string.IsNullOrWhiteSpace(exchange.FileVersionUrn)
            || string.IsNullOrWhiteSpace(metadata.FileVersionUrn))
        {
            return true;
        }

        return string.Equals(metadata.FileVersionUrn, exchange.FileVersionUrn, StringComparison.Ordinal);
    }

    private string GetJobOutputFolder(JobId job)
    {
        var outputFolder = Path.IsPathRooted(_options.OutputFolder)
            ? _options.OutputFolder
            : Path.Combine(_environment.ContentRootPath, _options.OutputFolder);

        return Path.Combine(outputFolder, CreateCacheKey(job));
    }

    // The job's folder name: a hex SHA-256 of the collection ID and exchange URN together. Every
    // character is legal in a path segment on every platform, which the job ID's own base64url
    // text also is — but the digest is a constant 64 characters, so a long URN cannot push the
    // artifact paths towards the Windows path length limit. Derived from the unencoded pair rather
    // than from the encoded job ID so the layout on disk does not depend on the encoding.
    private static string CreateCacheKey(JobId job)
    {
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(job.CanonicalForm)));
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
