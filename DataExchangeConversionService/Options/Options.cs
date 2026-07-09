namespace DataExchangeConversionService.Options;

public sealed class Options
{
    public const string SectionName = "DataExchangeConversionService";

    public string OutputFolder { get; set; } = "data";
}