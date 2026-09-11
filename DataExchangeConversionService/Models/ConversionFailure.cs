namespace DataExchangeConversionService.Models;

// Why a conversion failed, in the form a client can actually use.
//
// The full exception goes to the conversion log, which is where a developer looks and which is
// readable in any state — including this one.
public sealed class ConversionFailure
{
    // One sentence, written for whoever is looking at the screen.
    public string Message { get; set; } = string.Empty;

    // Which step of the pipeline failed, as a stable identifier rather than prose, so a client can
    // branch on it without parsing English.
    public string Step { get; set; } = string.Empty;

    // The exception's type and message — deliberately not its stack trace. Enough to tell two
    // failures of the same step apart, and useful in a developer-facing demo, without turning the
    // response into a crash dump.
    public string? Detail { get; set; }
}

// The steps a conversion moves through. Reported as the `step` of a failure; kept as constants so
// the identifier a client branches on is not the human description that sits next to it in the log.
public static class ConversionSteps
{
    public const string Initializing = "initializing";
    public const string CreatingClient = "creatingClient";
    public const string FetchingDetails = "fetchingDetails";
    public const string DownloadingObj = "downloadingObj";
    public const string MovingArtifacts = "movingArtifacts";
    public const string DeletingTempFolder = "deletingTempFolder";
    public const string ConvertingGlb = "convertingGlb";
    public const string DownloadingUsd = "downloadingUsd";
    public const string BundlingUsdz = "bundlingUsdz";
}
