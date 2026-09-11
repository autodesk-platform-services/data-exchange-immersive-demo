using System.Diagnostics.CodeAnalysis;
using System.Text;

namespace DataExchangeConversionService.Models;

// The identity of a conversion job as it travels in a URL: the collection and the exchange the
// job was started for, packed into a single path segment.
//
// The pair is base64url-encoded rather than spelled out as two path segments because an exchange
// URN is made of characters that are reserved in a path — ':' always, and '/', '+' and '=' in the
// base64 tail of a version URN. Spelling it out made every caller responsible for percent-encoding
// it exactly right, and a caller that got it wrong got a 404 with nothing to explain it. base64url
// output is already safe in a path segment, so no escaping is involved on either side.
public sealed record JobId(string CollectionId, string ExchangeUrn)
{
    // Separates the two halves inside the encoded payload. Neither an ACC collection ID
    // ("b.<uuid>") nor a Data Exchange URN can contain it, so the split back is unambiguous.
    private const char Separator = '|';

    // The pair unencoded. This — not the base64url text — is what the on-disk folder name is
    // derived from, so the layout does not depend on the details of the encoding.
    public string CanonicalForm => $"{CollectionId}{Separator}{ExchangeUrn}";

    public string Value => Encode(CollectionId, ExchangeUrn);

    public static string Encode(string collectionId, string exchangeUrn)
    {
        var payload = Encoding.UTF8.GetBytes($"{collectionId}{Separator}{exchangeUrn}");
        // base64url per RFC 4648 §5: the two characters that are unsafe in a path are swapped out
        // and the '=' padding is dropped, which TryParse restores.
        return Convert.ToBase64String(payload)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    public static bool TryParse([NotNullWhen(true)] string? value, [NotNullWhen(true)] out JobId? job)
    {
        job = null;

        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var base64 = value.Replace('-', '+').Replace('_', '/');
        // Base64 decodes in blocks of four characters, so the padding Encode stripped has to go
        // back on. A remainder of one is not a length any base64 text can have.
        base64 = (base64.Length % 4) switch
        {
            0 => base64,
            2 => base64 + "==",
            3 => base64 + "=",
            _ => null,
        };
        if (base64 is null)
        {
            return false;
        }

        string decoded;
        try
        {
            // Throws on bytes that are not valid UTF-8 rather than substituting replacement
            // characters, so a job ID that decodes to garbage is reported as malformed instead of
            // being turned into a lookup that quietly finds nothing.
            decoded = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false, throwOnInvalidBytes: true)
                .GetString(Convert.FromBase64String(base64));
        }
        catch (FormatException)
        {
            return false;
        }
        catch (ArgumentException)
        {
            // DecoderFallbackException, thrown by the strict UTF-8 decoder above.
            return false;
        }

        // Both halves are required: a job identifies one exchange within one collection, and the
        // Data Exchange SDK cannot resolve an exchange without both.
        var separator = decoded.IndexOf(Separator);
        if (separator <= 0 || separator == decoded.Length - 1)
        {
            return false;
        }

        job = new JobId(decoded[..separator], decoded[(separator + 1)..]);
        return true;
    }
}
