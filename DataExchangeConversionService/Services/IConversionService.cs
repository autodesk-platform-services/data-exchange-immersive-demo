using DataExchangeViewingService.Models;

namespace DataExchangeViewingService.Services;

public interface IConversionService
{
    // True when the token is allowed to access the original data exchange.
    Task<bool> HasAccessAsync(string exchangeUrn, string bearerToken);

    // Current status of the exchange, or null if no conversion has been started.
    ConversionMetadata? GetStatus(string exchangeUrn);

    // Starts an OBJ conversion in the background and returns immediately. Returns false without
    // starting anything if a conversion for this exchange already exists.
    bool StartObjConversion(string exchangeUrn, string bearerToken);

    // Deletes the results of a conversion, but does not affect the original data exchange or its contents.
    void DeleteObjConversion(string exchangeUrn);

    // Reads a produced artifact, or null if it does not exist.
    Artifact? GetArtifact(string exchangeUrn, string artifactName);
}
