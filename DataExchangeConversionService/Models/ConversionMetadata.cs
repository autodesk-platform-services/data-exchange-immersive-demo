using System.Text.Json.Serialization;

namespace DataExchangeConversionService.Models;

// Persisted to metadata.json next to the generated artifacts.
public sealed class ConversionMetadata
{
    public string Status { get; set; } = ConversionStatus.Running;

    public List<ConversionArtifact> Artifacts { get; set; } = [];

    public string? Error { get; set; }

    // When the job was accepted. Distinct from StartedAt because the two diverge as soon as
    // conversions are queued rather than started on the spot.
    public DateTimeOffset CreatedAt { get; set; }

    // When the conversion actually began working. Null until it does.
    public DateTimeOffset? StartedAt { get; set; }

    // Bumped and persisted at every step of the pipeline, so this is a liveness heartbeat as well
    // as a modification time: a "running" job whose UpdatedAt has stopped moving is a job whose
    // process died — the fire-and-forget conversion task does not survive an App Service restart,
    // but the metadata it left behind still says "running".
    public DateTimeOffset UpdatedAt { get; set; }

    // When the job reached "completed" or "failed". Null while it is still running.
    public DateTimeOffset? CompletedAt { get; set; }

    // The version of the exchange this conversion was produced from. An exchange's contents change
    // when a new version is published, but its lineage URN — the key everything here is stored
    // under — does not, so this is what decides whether the artifacts still describe the exchange.
    // Null for a conversion written before this field existed, or for an exchange whose version the
    // Data Exchange SDK does not report.
    public string? FileVersionUrn { get; set; }

    // The version the exchange is at now, set only when this conversion has been superseded by a
    // newer one. Filled in per request, not persisted — the answer changes whenever someone
    // publishes, not when the conversion is written.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? CurrentFileVersionUrn { get; set; }

    // Presigned URL for the conversion log. The log is not an artifact — it exists before the
    // conversion produces anything and grows while it runs — but it was listed as one, which is
    // why both clients reached for it by the hardcoded name "log.txt". Filled in per request, not
    // persisted.
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? LogUrl { get; set; }
}

public static class ConversionStatus
{
    public const string Running = "running";
    public const string Completed = "completed";
    public const string Failed = "failed";

    // The conversion finished, but of a version the exchange has since moved past. Its artifacts
    // still exist and still describe what they were made from — they just no longer describe the
    // exchange, so they are not served and a new conversion is needed.
    public const string Superseded = "superseded";
}

// An exchange as the service currently sees it: the job that addresses it, plus the version its
// contents would be converted from right now.
public sealed record ExchangeIdentity(JobId Job, string? FileVersionUrn);
