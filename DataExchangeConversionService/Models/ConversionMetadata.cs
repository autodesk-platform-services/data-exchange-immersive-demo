namespace DataExchangeConversionService.Models;

// Persisted to metadata.json next to the generated artifacts.
public sealed class ConversionMetadata
{
    public string Status { get; set; } = ConversionStatus.Running;

    public List<string> Artifacts { get; set; } = [];

    public string? Error { get; set; }

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

// An exchange as the service currently sees it: the lineage URN it is addressed by, plus the
// version its contents would be converted from right now.
public sealed record ExchangeIdentity(string ExchangeUrn, string? FileVersionUrn);
