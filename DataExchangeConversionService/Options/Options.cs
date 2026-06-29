namespace DataExchangeViewingService.Options;

public sealed class Options
{
    public const string SectionName = "DataExchangeViewingService";

    public string ConnectorName { get; set; } = "DataExchangeViewingService";

    public string ConnectorVersion { get; set; } = "1.0.0";

    public string HostApplicationName { get; set; } = "DataExchangeViewingService";

    public string HostApplicationVersion { get; set; } = "1.0.0";

    public string OutputFolder { get; set; } = "data";
}