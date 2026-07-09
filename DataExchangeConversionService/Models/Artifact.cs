namespace DataExchangeConversionService.Models;

public sealed record Artifact(byte[] Content, string FileName, string ContentType);
