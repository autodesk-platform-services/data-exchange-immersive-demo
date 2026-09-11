namespace DataExchangeConversionService.Models;

// The identity of a conversion job: the collection and the exchange the job was started for.
//
// The pair travels in the URL as two path segments — `/api/jobs/{collectionId}/{exchangeUrn}` — so
// the two values a developer has in front of them go straight into a URL. They used to be packed
// into one base64url-encoded segment, which meant nothing could be tested without computing the
// encoding first.
//
// The `:` in an exchange URN is legal in a path segment (RFC 3986 lists it among the characters a
// segment may contain), so in practice neither half needs escaping at all. Anything a segment
// cannot hold is percent-encoded by the caller, and the server has decoded it again by the time it
// reaches a route value — with one exception, which FromRoute deals with.
public sealed record JobId(string CollectionId, string ExchangeUrn)
{
    // Separates the two halves in the canonical form. Neither an ACC collection ID ("b.<uuid>")
    // nor a Data Exchange URN can contain it, so the pair cannot be spelled two different ways.
    private const char Separator = '|';

    // The pair as one string. This — not the URL form — is what the on-disk folder name is derived
    // from, so the layout does not depend on how the pair is escaped in a URL.
    public string CanonicalForm => $"{CollectionId}{Separator}{ExchangeUrn}";

    // The pair as the two route values that named it.
    //
    // `%2F` is the one escape the server leaves alone: decoding it would make it indistinguishable
    // from a real segment boundary, so it arrives here still encoded. Undoing it here is what lets
    // an exchange URN containing a '/' be addressed — every other escape is already gone, which is
    // why this is a targeted replacement rather than a second full unescape.
    public static JobId FromRoute(string collectionId, string exchangeUrn)
    {
        return new JobId(UnescapeSlashes(collectionId), UnescapeSlashes(exchangeUrn));
    }

    // The two path segments that address the job, escaped where a character is not legal in one.
    public string UrlPath => $"{EscapeSegment(CollectionId)}/{EscapeSegment(ExchangeUrn)}";

    private static string UnescapeSlashes(string value)
    {
        return value.Replace("%2F", "/", StringComparison.OrdinalIgnoreCase);
    }

    // `:` is put back because it is legal in a path segment and appears in every exchange URN:
    // escaping it would turn every URL the service hands out into `urn%3Aadsk%3A...`, which reads
    // as noise in a status response a developer is looking at.
    private static string EscapeSegment(string value)
    {
        return Uri.EscapeDataString(value).Replace("%3A", ":");
    }
}
