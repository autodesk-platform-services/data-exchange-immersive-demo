using System.Net.Http.Headers;
using Microsoft.AspNetCore.Mvc;
using DataExchangeConversionService.Models;
using DataExchangeConversionService.Services;

namespace DataExchangeConversionService.Controllers;

// A conversion job, addressed by the (project ID, exchange URN) pair it was started for, spelled
// out as two path segments — see JobId. The pair is deterministic, so a client builds the job's URL
// itself rather than having to create a job first to learn where it lives, and a developer testing
// the service pastes in the two values as they appear in ACC rather than encoding them first.
[ApiController]
[Route("api/jobs/{projectId}/{exchangeUrn}")]
public sealed class JobsController : ControllerBase
{
    private readonly ConversionService _conversionService;

    public JobsController(ConversionService conversionService)
    {
        _conversionService = conversionService;
    }

    // Returns the conversion status and the artifacts available for a job. A conversion produced
    // from a version the exchange has since moved past is reported with status "superseded" and
    // carries no artifact URLs — see ConversionService.GetStatus.
    [HttpGet]
    public async Task<IActionResult> GetStatus(string projectId, string exchangeUrn)
    {
        var (failure, exchange) = await ResolveJobAsync(JobId.FromRoute(projectId, exchangeUrn));
        if (failure is not null) { return failure; }

        var status = _conversionService.GetStatus(exchange);
        if (status is null) { return NotFound(); }

        AddPresignedUrls(exchange, status);
        return Ok(status);
    }

    // Starts a conversion and returns immediately while it runs in the background.
    //
    // Idempotent: asking for a conversion that is already running, or already finished, answers
    // 202 with that conversion rather than 409 — the state the caller wants either is being
    // reached or has been. A failed or superseded conversion is replaced, since neither is a
    // result worth keeping. `?force=true` replaces whatever is stored.
    //
    // The 202 carries the job's current state, so a caller learns whether it is waiting on a fresh
    // conversion or can go straight to the artifacts without a second request.
    [HttpPost]
    public async Task<IActionResult> StartConversion(
        string projectId,
        string exchangeUrn,
        [FromQuery] bool force = false)
    {
        var (failure, exchange) = await ResolveJobAsync(JobId.FromRoute(projectId, exchangeUrn));
        if (failure is not null) { return failure; }

        TryGetBearerToken(out var bearerToken);
        var status = _conversionService.StartConversion(exchange, bearerToken, force);
        AddPresignedUrls(exchange, status);

        return Accepted($"/api/jobs/{exchange.Job.UrlPath}", status);
    }

    // Deletes the conversion results for a job. This does not affect the exchange itself or its
    // contents on the Data Exchange service.
    [HttpDelete]
    public async Task<IActionResult> DeleteConversion(string projectId, string exchangeUrn)
    {
        var (failure, exchange) = await ResolveJobAsync(JobId.FromRoute(projectId, exchangeUrn));
        if (failure is not null) { return failure; }

        _conversionService.DeleteObjConversion(exchange.Job);
        return Ok();
    }

    // Returns a single artifact produced by a conversion (e.g. the generated USDZ package).
    //
    // Authorized either by the usual bearer token, or by the `secret` query parameter carried by
    // the presigned URLs in a status response — which is the only way to hand these bytes to
    // something that cannot send an Authorization header, such as a <model-viewer> `src`.
    [HttpGet("artifacts/{artifact}")]
    [Produces("model/obj", "model/mtl", "model/gltf-binary", "model/vnd.usdz+zip", "application/octet-stream")]
    public async Task<IActionResult> GetArtifact(
        string projectId,
        string exchangeUrn,
        string artifact,
        [FromQuery] string? secret)
    {
        var job = JobId.FromRoute(projectId, exchangeUrn);

        if (!string.IsNullOrEmpty(secret))
        {
            // A wrong secret is a 404 rather than a 403: a caller holding an unusable URL learns
            // nothing about whether the job behind it exists.
            if (!_conversionService.IsJobSecretValid(job, secret)) { return NotFound(); }

            var presignedFile = _conversionService.GetPresignedArtifact(job, artifact);
            return presignedFile is null ? NotFound() : StreamArtifact(presignedFile, asAttachment: false);
        }

        var (failure, exchange) = await ResolveJobAsync(job);
        if (failure is not null) { return failure; }

        var file = _conversionService.GetArtifact(exchange, artifact);
        return file is null ? NotFound() : StreamArtifact(file, asAttachment: true);
    }

    // Streams from disk, and range processing lets a client resume an interrupted USDZ download or
    // tail the growing conversion log instead of refetching it whole.
    //
    // A presigned URL exists to be embedded in something that renders it, so it is served inline;
    // passing a file name would set `Content-Disposition: attachment`, which is the right answer
    // for a deliberate download over the bearer-token path but not for a <model> `src`.
    private IActionResult StreamArtifact(Artifact file, bool asAttachment)
    {
        return asAttachment
            ? PhysicalFile(file.Path, file.ContentType, file.FileName, enableRangeProcessing: true)
            : PhysicalFile(file.Path, file.ContentType, enableRangeProcessing: true);
    }

    // Gives the log — and every artifact — an absolute URL carrying the job's secret, so a client
    // never has to build one, and the only place the secret appears is a response the caller had to
    // be authorized to read.
    private void AddPresignedUrls(ExchangeIdentity exchange, ConversionMetadata status)
    {
        var secret = _conversionService.GetJobSecret(exchange.Job);
        if (secret is null) { return; }

        var jobUrl = $"{Request.Scheme}://{Request.Host}/api/jobs/{exchange.Job.UrlPath}";
        var query = $"?secret={Uri.EscapeDataString(secret)}";

        // Offered whatever state the job is in: the log is most worth reading when the conversion
        // failed or has been superseded.
        status.LogUrl = $"{jobUrl}/log{query}";

        // A superseded conversion's artifacts are not served, so URLs for them would only 404.
        if (!ConversionService.IsUsable(status)) { return; }

        foreach (var artifact in status.Artifacts)
        {
            artifact.Url = $"{jobUrl}/artifacts/{Uri.EscapeDataString(artifact.Name)}{query}";
        }
    }

    // Returns the conversion log, which is readable whatever state the job is in — including
    // failed and superseded, where it is the only thing that explains what happened.
    //
    // Authorized the same two ways as an artifact: the usual bearer token, or the `secret` carried
    // by the presigned `logUrl` in a status response.
    [HttpGet("log")]
    [Produces("text/plain")]
    public async Task<IActionResult> GetLog(string projectId, string exchangeUrn, [FromQuery] string? secret)
    {
        var job = JobId.FromRoute(projectId, exchangeUrn);

        if (!string.IsNullOrEmpty(secret))
        {
            if (!_conversionService.IsJobSecretValid(job, secret)) { return NotFound(); }
        }
        else
        {
            var (failure, _) = await ResolveJobAsync(job);
            if (failure is not null) { return failure; }
        }

        var log = _conversionService.GetLog(job);
        // Served inline, and with range processing, so a client can tail the growing log instead of
        // refetching it whole on every poll.
        return log is null ? NotFound() : StreamArtifact(log, asAttachment: false);
    }

    // Checks that the request carries a bearer token with access to the exchange the URL names, and
    // resolves that exchange's current version along the way — the same Data Exchange call answers
    // both, so this costs no extra round trip. Returns the error result to send when the job cannot
    // be resolved, in which case the accompanying identity carries no version and must not be used.
    //
    // A URL naming an exchange that does not exist and one naming an exchange the token cannot read
    // are the same 403: only the exchange itself can tell the two apart, and asking it is what just
    // failed. A missing or blank path segment never reaches here — such a URL matches no route.
    private async Task<(IActionResult? Failure, ExchangeIdentity Exchange)> ResolveJobAsync(JobId job)
    {
        var unresolved = new ExchangeIdentity(job, null, null);

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
