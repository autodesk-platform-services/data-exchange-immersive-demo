using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using DataExchangeViewingService.Services;

namespace DataExchangeViewingService.Controllers;

[ApiController]
[Route("api/exchanges")]
public sealed class ExchangesController : ControllerBase
{
    private readonly ConversionService _conversionService;

    public ExchangesController(ConversionService conversionService)
    {
        _conversionService = conversionService;
    }

    // Returns the conversion status and the artifacts available for an exchange.
    [HttpGet("{exchangeUrn}")]
    public async Task<IActionResult> GetStatus(string exchangeUrn)
    {
        if (await RequireExchangeAccessAsync(exchangeUrn) is { } denied)
        {
            return denied;
        }

        var status = _conversionService.GetStatus(exchangeUrn);
        return status is null ? NotFound() : Ok(status);
    }

    // Starts a new OBJ conversion and returns immediately while it runs in the background.
    [HttpPost("{exchangeUrn}")]
    public async Task<IActionResult> StartConversion(string exchangeUrn)
    {
        if (await RequireExchangeAccessAsync(exchangeUrn) is { } denied)
        {
            return denied;
        }

        TryGetBearerToken(out var bearerToken);
        if (!_conversionService.StartObjConversion(exchangeUrn, bearerToken))
        {
            return Conflict(new ProblemDetails
            {
                Title = "Conversion already in progress",
                Detail = "This exchange is already being processed. Delete the current conversion first if you want to start it again.",
                Status = StatusCodes.Status409Conflict
            });
        }

        return Accepted($"/api/exchanges/{exchangeUrn}");
    }

    // Deletes the conversion results for an exchange. This does not affect the exchange itself or its contents on the Data Exchange service.
    [HttpDelete("{exchangeUrn}")]
    public async Task<IActionResult> DeleteConversion(string exchangeUrn)
    {
        if (await RequireExchangeAccessAsync(exchangeUrn) is { } denied)
        {
            return denied;
        }

        _conversionService.DeleteObjConversion(exchangeUrn);
        return Ok();
    }

    // Returns a single artifact produced by a conversion (e.g. the generated OBJ file).
    [HttpGet("{exchangeUrn}/{artifact}")]
    [Produces("model/obj", "model/gltf-binary", "model/vnd.usdz+zip", "application/octet-stream")]
    public async Task<IActionResult> GetArtifact(string exchangeUrn, string artifact)
    {
        if (await RequireExchangeAccessAsync(exchangeUrn) is { } denied)
        {
            return denied;
        }

        var file = _conversionService.GetArtifact(exchangeUrn, artifact);
        return file is null ? NotFound() : File(file.Content, file.ContentType, file.FileName);
    }

    // Returns an error result unless a bearer token with access to the exchange is present, otherwise null.
    private async Task<IActionResult?> RequireExchangeAccessAsync(string exchangeUrn)
    {
        if (!TryGetBearerToken(out var bearerToken))
        {
            return Unauthorized(new ProblemDetails
            {
                Title = "Missing bearer token",
                Detail = "Provide an Authorization header in the form 'Bearer {token}'."
            });
        }

        if (!await _conversionService.HasAccessAsync(exchangeUrn, bearerToken))
        {
            return StatusCode(StatusCodes.Status403Forbidden, new ProblemDetails
            {
                Title = "Access denied",
                Detail = "The provided token does not have access to this data exchange.",
                Status = StatusCodes.Status403Forbidden
            });
        }

        return null;
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
