namespace DataExchangeConversionService.Models;

// Persisted to metadata.json next to the generated artifacts.
public sealed class ConversionMetadata
{
    public string Status { get; set; } = ConversionStatus.Running;

    public List<string> Artifacts { get; set; } = [];

    public string? Error { get; set; }
}

public static class ConversionStatus
{
    public const string Running = "running";
    public const string Completed = "completed";
    public const string Failed = "failed";
}
