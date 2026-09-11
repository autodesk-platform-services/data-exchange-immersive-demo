using DataExchangeConversionService.Models;
using DataExchangeConversionService.Options;
using Autodesk.DataExchange;
using Autodesk.DataExchange.Core.Models;
using Microsoft.Extensions.Options;
using System.Collections.Concurrent;
using System.Runtime;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace DataExchangeConversionService.Services;

public sealed class ConversionService
{
    private const string MetadataFileName = "metadata.json";
    private const string LogFileName = "log.txt";
    private const string SecretFileName = "secret";
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        Converters = { new Iso8601UtcConverter() }
    };

    // Statuses whose stored conversion answers a new request on its own: one is already running,
    // the other already produced the artifacts.
    //
    // "failed" is deliberately not among them. A failed attempt is not a result worth keeping, and
    // a client asking again is asking for a retry — which is what the visionOS Retry button was
    // already trying to do, only to get a 409, swallow it, and poll the same failure back onto the
    // screen. "superseded" is not among them either: it is the very case a new conversion resolves.
    private static readonly string[] ReusableStatuses = [ConversionStatus.Running, ConversionStatus.Completed];

    private static readonly ConcurrentDictionary<string, object> StartGates = new();

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

    // The stored conversion for a job, or null when there is none.
    //
    // A conversion produced from an earlier version of the exchange is reported as "superseded"
    // rather than as absent. It used to be reported as a 404 — indistinguishable from an exchange
    // nobody had ever converted — which left a client unable to say why the artifacts it had a
    // moment ago were gone. The visionOS store carried a comment listing the two causes it could
    // not tell apart. Its artifacts are still not served; the difference is only that the client
    // is now told which case it is in, and against which version.
    public ConversionMetadata? GetStatus(ExchangeIdentity exchange)
    {
        var metadata = ReadMetadata(GetJobOutputFolder(exchange.Job));
        if (metadata is null)
        {
            return null;
        }

        if (!IsCurrent(metadata, exchange))
        {
            metadata.Status = ConversionStatus.Superseded;
            metadata.CurrentFileVersionUrn = exchange.FileVersionUrn;
        }

        return metadata;
    }

    // Whether a stored conversion is one whose artifacts describe the exchange as it is now.
    // Anything else — no conversion at all, or one of a version that has been superseded — means
    // the job has to be run again before there is anything worth serving.
    public static bool IsUsable(ConversionMetadata? metadata)
    {
        return metadata is not null && metadata.Status != ConversionStatus.Superseded;
    }

    // Starts a conversion for the job, or returns the one that already answers the request.
    //
    // Asking for a conversion that is already running, or already finished, is not an error: the
    // state the caller wants either is being reached or has been. It used to be a 409, which meant
    // a client had to DELETE before it could ask again — and both clients simply worked around it.
    // `force` discards whatever is stored and converts again regardless.
    public ConversionMetadata StartConversion(ExchangeIdentity exchange, string bearerToken, bool force)
    {
        var outputFolder = GetJobOutputFolder(exchange.Job);

        // Serialises the decision with the start, so two requests arriving together cannot both
        // conclude they should convert and then write into the same folder. Static because the
        // service is scoped to a request. Single-process only: it does not coordinate across App
        // Service instances, and the entry per job is never reclaimed — both acceptable for a
        // demo-scale service, neither a substitute for a real conversion queue.
        lock (StartGates.GetOrAdd(exchange.Job.CanonicalForm, _ => new object()))
        {
            var existing = GetStatus(exchange);
            if (!force && IsUsable(existing) && ReusableStatuses.Contains(existing!.Status))
            {
                _logger.LogInformation(
                    "Reusing the {Status} conversion of exchange {ExchangeUrn}.",
                    existing.Status,
                    exchange.Job.ExchangeUrn);
                return existing;
            }

            if (Directory.Exists(outputFolder))
            {
                // Replacing keeps one folder per job rather than accumulating a copy of every
                // version ever converted — these artifacts run to hundreds of megabytes each.
                _logger.LogInformation(
                    "Discarding the stored conversion of exchange {ExchangeUrn} ({Reason}).",
                    exchange.Job.ExchangeUrn,
                    force ? "forced" : existing?.Status ?? "unreadable");
                DeleteFolderIfExists(outputFolder);
            }

            return StartConversionCore(exchange, bearerToken, outputFolder);
        }
    }

    private ConversionMetadata StartConversionCore(
        ExchangeIdentity exchange,
        string bearerToken,
        string outputFolder)
    {
        Directory.CreateDirectory(outputFolder);

        // Mark the conversion as running, then run it in the background.
        var logPath = Path.Combine(outputFolder, LogFileName);
        File.WriteAllText(logPath, string.Empty);

        // The capability that presigned artifact URLs carry. Minted per conversion, so deleting
        // the job — or superseding it, which deletes the folder — revokes every URL handed out
        // for it. 256 bits from a cryptographic RNG: it is guessed or it is not usable.
        File.WriteAllText(
            Path.Combine(outputFolder, SecretFileName),
            Convert.ToBase64String(RandomNumberGenerator.GetBytes(32))
                .TrimEnd('=')
                .Replace('+', '-')
                .Replace('/', '_'));

        var now = DateTimeOffset.UtcNow;
        var metadata = new ConversionMetadata
        {
            FileVersionUrn = exchange.FileVersionUrn,
            CreatedAt = now,
            UpdatedAt = now
        };
        WriteMetadata(outputFolder, metadata);
        _ = Task.Run(() => RunObjConversionAsync(exchange.Job, bearerToken, outputFolder, metadata));
        return metadata;
    }

    public void DeleteObjConversion(JobId job)
    {
        // Keyed on the job alone, so this removes whichever version's conversion is stored —
        // including one this service now considers superseded.
        DeleteFolderIfExists(GetJobOutputFolder(job));
    }

    // The conversion log.
    //
    // Not an artifact: it exists from the moment the job starts rather than when it finishes, it
    // grows while the conversion runs, and its size and digest are meaningless until it stops. It
    // was nonetheless listed in `artifacts`, which is why both clients reached for it by the
    // hardcoded name "log.txt".
    //
    // Readable whatever state the job is in, including failed and superseded. It is the one file
    // worth reading when a conversion has gone wrong, and gating it behind "are these artifacts
    // still current" made a superseded job's log unreachable at exactly the wrong moment.
    public Artifact? GetLog(JobId job)
    {
        var logPath = Path.Combine(GetJobOutputFolder(job), LogFileName);
        return File.Exists(logPath)
            ? new Artifact(logPath, LogFileName, ArtifactTypes.For(LogFileName).ContentType)
            : null;
    }

    // The job's presigning secret, or null when there is no job on disk.
    public string? GetJobSecret(JobId job)
    {
        var secretPath = Path.Combine(GetJobOutputFolder(job), SecretFileName);
        return File.Exists(secretPath) ? File.ReadAllText(secretPath) : null;
    }

    // Whether a presented secret is the one this job was issued.
    public bool IsJobSecretValid(JobId job, string presented)
    {
        var secret = GetJobSecret(job);
        if (secret is null)
        {
            return false;
        }

        // Compared without a timing signal, so a caller cannot learn the secret one character at
        // a time by measuring how long a rejection takes.
        return CryptographicOperations.FixedTimeEquals(
            Encoding.UTF8.GetBytes(secret),
            Encoding.UTF8.GetBytes(presented));
    }

    // An artifact fetched with a presigned URL, whose secret the caller has already presented.
    //
    // Unlike the bearer-token path this does not check that the conversion is still of the
    // exchange's current version — with no token there is no way to ask the Data Exchange service
    // what that version is. A presigned URL therefore points at the artifact of a specific
    // conversion, and keeps working until that conversion is deleted or replaced. The status
    // endpoint that hands the URL out is still version-gated, so a client following a fresh URL
    // never receives stale bytes; only a client holding on to an old URL does.
    public Artifact? GetPresignedArtifact(JobId job, string artifactName)
    {
        var outputFolder = GetJobOutputFolder(job);
        var metadata = ReadMetadata(outputFolder);
        return metadata is null ? null : ResolveDeclaredArtifact(outputFolder, metadata, artifactName);
    }

    public Artifact? GetArtifact(ExchangeIdentity exchange, string artifactName)
    {
        // Gated the same way as the status, so an artifact left over from a superseded version is
        // never served — not even to a client that asks for it by name.
        var status = GetStatus(exchange);
        if (!IsUsable(status))
        {
            return null;
        }

        return ResolveDeclaredArtifact(GetJobOutputFolder(exchange.Job), status!, artifactName);
    }

    // Resolves a name against the artifacts the conversion actually declared.
    //
    // This used to resolve any file name that happened to exist in the job's folder, which made
    // the job's own bookkeeping downloadable: `metadata.json` — including the full exception text
    // a failed conversion stores in it — and, once presigning arrived, the secret next to it.
    // Answering only for declared artifacts closes that by construction rather than by remembering
    // to add each new internal file to a denylist.
    //
    // The content type comes from the declaration too, so the status and the bytes cannot disagree
    // about what a file is.
    private static Artifact? ResolveDeclaredArtifact(
        string outputFolder,
        ConversionMetadata metadata,
        string artifactName)
    {
        // GetFileName strips any directory parts, so a name cannot walk out of the output folder
        // even before it is matched against the declarations.
        var fileName = Path.GetFileName(artifactName);

        var declared = metadata.Artifacts.FirstOrDefault(artifact =>
            string.Equals(artifact.Name, fileName, StringComparison.OrdinalIgnoreCase));
        if (declared is null)
        {
            return null;
        }

        var artifactPath = Path.Combine(outputFolder, declared.Name);
        if (!File.Exists(artifactPath))
        {
            return null;
        }

        return new Artifact(artifactPath, declared.Name, declared.ContentType);
    }

    private async Task RunObjConversionAsync(
        JobId job,
        string bearerToken,
        string outputFolder,
        ConversionMetadata metadata)
    {
        var logPath = Path.Combine(outputFolder, LogFileName);

        // Track the step so a failure anywhere along the pipeline can be pinpointed from the logs
        // and from the metadata written back to disk. The identifier is what a client branches on;
        // the description is what goes in the log next to it.
        var currentStepId = ConversionSteps.Initializing;
        var currentStep = "initializing conversion";

        void Log(string message)
        {
            _logger.LogInformation(message);
            File.AppendAllText(logPath, $"{DateTimeOffset.UtcNow:O} {message}{Environment.NewLine}");
        }

        // Each step persists the metadata as well as logging, so UpdatedAt is a heartbeat a
        // reader can trust: a "running" job that has stopped moving it is one whose process is
        // gone. Writing metadata.json is a few hundred bytes against a step that takes seconds.
        void Step(string stepId, string description)
        {
            currentStepId = stepId;
            currentStep = description;
            Log($"Step: {description}.");
            metadata.UpdatedAt = DateTimeOffset.UtcNow;
            WriteMetadata(outputFolder, metadata);
        }

        metadata.StartedAt = DateTimeOffset.UtcNow;
        Log("Starting OBJ conversion.");

        try
        {
            Step(ConversionSteps.CreatingClient, "creating Data Exchange client");
            var client = CreateClient(bearerToken);

            Step(ConversionSteps.FetchingDetails, "fetching exchange details");
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

            Step(ConversionSteps.DownloadingObj, "downloading exchange as OBJ");
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
                Step(ConversionSteps.MovingArtifacts, $"moving extracted artifact {fileName}");
                File.Move(sourcePath, destinationPath, overwrite: true);
                RecordArtifact(metadata, destinationPath);
            }

            Step(ConversionSteps.DeletingTempFolder, "deleting temp folder");
            Directory.Delete(tempFolder, recursive: true);
            ForceFullGarbageCollection(_logger, "Data Exchange to OBJ conversion");

            // Post-process each generated OBJ into a self-contained binary glTF (*.glb).
            // USDZ is built separately from the SDK's native USD output below.
            var objFileNames = metadata.Artifacts
                .Where(artifact => artifact.Type == "obj")
                .Select(artifact => artifact.Name)
                .ToList();
            foreach (var objFileName in objFileNames)
            {
                var objPath = Path.Combine(outputFolder, objFileName);
                var memory = new MemoryTelemetry(_logger, "Exchange post-processing", logPath);

                // The extraction emits Z-up geometry; rotate it to the Y-up convention used by
                // glTF viewers while streaming the OBJ.
                var glbFileName = Path.ChangeExtension(objFileName, ".glb");
                var glbPath = Path.Combine(outputFolder, glbFileName);
                Step(ConversionSteps.ConvertingGlb, $"converting OBJ {objFileName} to GLB {glbFileName}");
                using (memory.Step("convert OBJ to GLB"))
                {
                    GltfConverter.ConvertObjToGlb(objPath, glbPath, convertZUpToYUp: true, logger: _logger, logPath: logPath);
                }
                RecordArtifact(metadata, glbPath);
                ForceFullGarbageCollection(_logger, "OBJ to GLB conversion");
            }

            Step(ConversionSteps.DownloadingUsd, "downloading exchange as USD");
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
            Step(ConversionSteps.BundlingUsdz, $"bundling downloaded USD files into {usdzFileName}");
            UsdzConverter.BundleUsdFolder(usdFolder, usdzPath, _logger, logPath);
            RecordArtifact(metadata, usdzPath);

            Step(ConversionSteps.DeletingTempFolder, "deleting USD temp folder");
            Directory.Delete(usdFolder, recursive: true);
            ForceFullGarbageCollection(_logger, "USD to USDZ bundling");

            metadata.Status = ConversionStatus.Completed;
            metadata.CompletedAt = DateTimeOffset.UtcNow;
            Log($"Exchange conversion completed. Artifacts: {string.Join(", ", metadata.Artifacts.Select(artifact => artifact.Name))}.");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "OBJ conversion failed while {Step}.", currentStep);
            File.AppendAllText(logPath, $"{DateTimeOffset.UtcNow:O} [Error] Failed while {currentStep}.{Environment.NewLine}{ex}{Environment.NewLine}");

            metadata.Status = ConversionStatus.Failed;
            metadata.CompletedAt = DateTimeOffset.UtcNow;
            // A sentence for a person plus the step and the exception summary. The stack trace and
            // the inner exceptions went to the log above, which is readable in this state and is
            // where a developer looks — they used to be sent to clients and rendered verbatim.
            metadata.Error = new ConversionFailure
            {
                Step = currentStepId,
                Message = $"The conversion failed while {currentStep}.",
                Detail = $"{ex.GetType().Name}: {ex.Message}",
            };
        }

        metadata.UpdatedAt = DateTimeOffset.UtcNow;
        WriteMetadata(outputFolder, metadata);
    }

    // Adds an artifact's description, replacing any earlier description of the same file.
    private static void RecordArtifact(ConversionMetadata metadata, string path)
    {
        var artifact = ConversionArtifact.Describe(path);
        metadata.Artifacts.RemoveAll(existing =>
            string.Equals(existing.Name, artifact.Name, StringComparison.OrdinalIgnoreCase));
        metadata.Artifacts.Add(artifact);
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

    // The job's folder name: a hex SHA-256 of the collection ID and exchange URN together. An
    // exchange URN cannot be a folder name as it stands — ':' is not legal in a Windows path — and
    // a digest is a constant 64 characters, so a long URN cannot push the artifact paths towards
    // the Windows path length limit either. Derived from the canonical pair rather than from the
    // URL form, so the layout on disk does not depend on how the pair is escaped in a URL.
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
