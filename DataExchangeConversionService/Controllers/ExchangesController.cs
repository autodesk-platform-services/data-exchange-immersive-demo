using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using DataExchangeConversionService.Models;
using DataExchangeConversionService.Services;

namespace DataExchangeConversionService.Controllers;

[ApiController]
[Route("api/exchanges/{collectionId}")]
public sealed class ExchangesController : ControllerBase
{
    private readonly ConversionService _conversionService;

    public ExchangesController(ConversionService conversionService)
    {
        _conversionService = conversionService;
    }

    // Returns the conversion status and the artifacts available for an exchange. A conversion
    // produced from a version the exchange has since moved past is reported as 404, the same as
    // no conversion at all — see ConversionService.GetStatus.
    [HttpGet("{exchangeUrn}")]
    public async Task<IActionResult> GetStatus(string collectionId, string exchangeUrn)
    {
        var (denied, exchange) = await ResolveExchangeAsync(collectionId, exchangeUrn);
        if (denied is not null) { return denied; }

        var status = _conversionService.GetStatus(exchange);
        return status is null ? NotFound() : Ok(status);
    }

    // Starts a new OBJ conversion and returns immediately while it runs in the background.
    [HttpPost("{exchangeUrn}")]
    public async Task<IActionResult> StartConversion(string collectionId, string exchangeUrn)
    {
        var (denied, exchange) = await ResolveExchangeAsync(collectionId, exchangeUrn);
        if (denied is not null) { return denied; }

        TryGetBearerToken(out var bearerToken);
        if (_conversionService.GetStatus(exchange) is not null)
        {
            return Conflict(new ProblemDetails
            {
                Title = "Conversion already in progress",
                Detail = "This exchange is already being processed. Delete the current conversion first if you want to start it again.",
                Status = StatusCodes.Status409Conflict
            });
        }
        _conversionService.StartObjConversion(collectionId, exchange, bearerToken);

        return Accepted($"/api/exchanges/{Uri.EscapeDataString(collectionId)}/{Uri.EscapeDataString(exchangeUrn)}");
    }

    // Deletes the conversion results for an exchange. This does not affect the exchange itself or its contents on the Data Exchange service.
    [HttpDelete("{exchangeUrn}")]
    public async Task<IActionResult> DeleteConversion(string collectionId, string exchangeUrn)
    {
        var (denied, _) = await ResolveExchangeAsync(collectionId, exchangeUrn);
        if (denied is not null) { return denied; }

        _conversionService.DeleteObjConversion(exchangeUrn);
        return Ok();
    }

    // Returns a single artifact produced by a conversion (e.g. the generated OBJ file).
    [HttpGet("{exchangeUrn}/{artifact}")]
    [Produces("model/obj", "model/gltf-binary", "model/vnd.usdz+zip", "application/octet-stream")]
    public async Task<IActionResult> GetArtifact(string collectionId, string exchangeUrn, string artifact)
    {
        var (denied, exchange) = await ResolveExchangeAsync(collectionId, exchangeUrn);
        if (denied is not null) { return denied; }

        var file = _conversionService.GetArtifact(exchange, artifact);
        if (file is null) { return NotFound(); }

        // Streams from disk, and range processing lets a client resume an interrupted USDZ
        // download or tail the growing conversion log instead of refetching it whole.
        return PhysicalFile(file.Path, file.ContentType, file.FileName, enableRangeProcessing: true);
    }

    // Checks that the request carries a bearer token with access to the exchange, and resolves the
    // exchange's current version along the way — the same Data Exchange call answers both, so this
    // costs no extra round trip. Returns the error result to send when access is refused, in which
    // case the accompanying identity carries no version and must not be used.
    private async Task<(IActionResult? Denied, ExchangeIdentity Exchange)> ResolveExchangeAsync(
        string collectionId,
        string exchangeUrn)
    {
        var unresolved = new ExchangeIdentity(exchangeUrn, null);

        if (!TryGetBearerToken(out var bearerToken))
        {
            return (Unauthorized(new ProblemDetails
            {
                Title = "Missing bearer token",
                Detail = "Provide an Authorization header in the form 'Bearer {token}'."
            }), unresolved);
        }

        var exchange = await _conversionService.ResolveExchangeAsync(collectionId, exchangeUrn, bearerToken);
        if (exchange is null)
        {
            return (StatusCode(StatusCodes.Status403Forbidden, new ProblemDetails
            {
                Title = "Access denied",
                Detail = "The provided token does not have access to this data exchange.",
                Status = StatusCodes.Status403Forbidden
            }), unresolved);
        }

        return (null, exchange);
    }

    private bool TryGetBearerToken(out string bearerToken)
    {
        bearerToken = string.Empty;

        if (!Request.Headers.TryGetValue("Authorization", out var authorizationHeader)
            || !AuthenticationHeaderValue.TryParse(authorizationHeader.ToString(), out var authorization)
            || !string.Equals(authorization.Scheme, "Bearer", StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrWhiteSpace(authorization.Parameter))
        {
            return false;
        }

        bearerToken = authorization.Parameter;
        return true;
    }
}
