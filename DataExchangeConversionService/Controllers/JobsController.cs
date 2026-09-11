using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using DataExchangeConversionService.Models;
using DataExchangeConversionService.Services;

namespace DataExchangeConversionService.Controllers;

// A conversion job, addressed by the base64url-encoded (collection ID, exchange URN) pair it was
// started for — see JobId. The pair is deterministic, so a client computes the job ID itself
// rather than having to create a job first to learn where it lives.
[ApiController]
[Route("api/jobs")]
public sealed class JobsController : ControllerBase
{
    private readonly ConversionService _conversionService;

    public JobsController(ConversionService conversionService)
    {
        _conversionService = conversionService;
    }

    // Returns the conversion status and the artifacts available for a job. A conversion produced
    // from a version the exchange has since moved past is reported as 404, the same as no
    // conversion at all — see ConversionService.GetStatus.
    [HttpGet("{jobId}")]
    public async Task<IActionResult> GetStatus(string jobId)
    {
        var (failure, exchange) = await ResolveJobAsync(jobId);
        if (failure is not null) { return failure; }

        var status = _conversionService.GetStatus(exchange);
        return status is null ? NotFound() : Ok(status);
    }

    // Starts a new conversion and returns immediately while it runs in the background.
    [HttpPost("{jobId}")]
    public async Task<IActionResult> StartConversion(string jobId)
    {
        var (failure, exchange) = await ResolveJobAsync(jobId);
        if (failure is not null) { return failure; }

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
        _conversionService.StartObjConversion(exchange, bearerToken);

        return Accepted($"/api/jobs/{exchange.Job.Value}");
    }

    // Deletes the conversion results for a job. This does not affect the exchange itself or its
    // contents on the Data Exchange service.
    [HttpDelete("{jobId}")]
    public async Task<IActionResult> DeleteConversion(string jobId)
    {
        var (failure, exchange) = await ResolveJobAsync(jobId);
        if (failure is not null) { return failure; }

        _conversionService.DeleteObjConversion(exchange.Job);
        return Ok();
    }

    // Returns a single artifact produced by a conversion (e.g. the generated USDZ package).
    [HttpGet("{jobId}/artifacts/{artifact}")]
    [Produces("model/obj", "model/gltf-binary", "model/vnd.usdz+zip", "application/octet-stream")]
    public async Task<IActionResult> GetArtifact(string jobId, string artifact)
    {
        var (failure, exchange) = await ResolveJobAsync(jobId);
        if (failure is not null) { return failure; }

        var file = _conversionService.GetArtifact(exchange, artifact);
        if (file is null) { return NotFound(); }

        // Streams from disk, and range processing lets a client resume an interrupted USDZ
        // download or tail the growing conversion log instead of refetching it whole.
        return PhysicalFile(file.Path, file.ContentType, file.FileName, enableRangeProcessing: true);
    }

    // Decodes the job ID, checks that the request carries a bearer token with access to the
    // exchange it names, and resolves that exchange's current version along the way — the same
    // Data Exchange call answers both, so this costs no extra round trip. Returns the error result
    // to send when the job cannot be resolved, in which case the accompanying identity carries no
    // version and must not be used.
    private async Task<(IActionResult? Failure, ExchangeIdentity Exchange)> ResolveJobAsync(string jobId)
    {
        if (!JobId.TryParse(jobId, out var job))
        {
            return (BadRequest(new ProblemDetails
            {
                Title = "Malformed job ID",
                Detail = "A job ID is the base64url encoding of '{collectionId}|{exchangeUrn}'.",
                Status = StatusCodes.Status400BadRequest
            }), new ExchangeIdentity(new JobId(string.Empty, string.Empty), null));
        }

        var unresolved = new ExchangeIdentity(job, null);

        if (!TryGetBearerToken(out var bearerToken))
        {
            return (Unauthorized(new ProblemDetails
            {
                Title = "Missing bearer token",
                Detail = "Provide an Authorization header in the form 'Bearer {token}'."
            }), unresolved);
        }

        var exchange = await _conversionService.ResolveExchangeAsync(job, bearerToken);
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
