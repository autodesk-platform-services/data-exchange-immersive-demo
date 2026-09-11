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

    // The version of the exchange this conversion was produced from. Recorded so a conversion
    // made from a superseded version is reported as absent rather than served as current: an
    // exchange's contents change when a new version is published, but its lineage URN — the key
    // everything here is stored under — does not. Null for a conversion written before this
    // field existed, or for an exchange whose version the Data Exchange SDK does not report.
    public string? FileVersionUrn { get; set; }
}

public static class ConversionStatus
{
    public const string Running = "running";
    public const string Completed = "completed";
    public const string Failed = "failed";
}

// An exchange as the service currently sees it: the job that addresses it, plus the version its
// contents would be converted from right now.
public sealed record ExchangeIdentity(JobId Job, string? FileVersionUrn);
