namespace DataExchangeConversionService.Models;

// Identifies an artifact on disk rather than carrying its bytes. A converted BIM exchange can run
// to hundreds of megabytes, so the file is streamed to the client from its path instead of being
// buffered in the server's managed heap first.
public sealed record Artifact(string Path, string FileName, string ContentType);
