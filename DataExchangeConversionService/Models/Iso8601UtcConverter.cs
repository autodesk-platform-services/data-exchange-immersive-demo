using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace DataExchangeConversionService.Models;

// Writes timestamps as ISO 8601 in UTC with a trailing 'Z' and second resolution, e.g.
// "2026-09-10T12:04:12Z".
//
// The default converter emits fractional seconds and a numeric offset ("+00:00"). Foundation's
// ISO8601DateFormatter — which is what `JSONDecoder.dateDecodingStrategy = .iso8601` uses, and so
// what the visionOS client reads these with — rejects fractional seconds unless it is explicitly
// told to expect them. Pinning the format here means neither client has to opt into a detail of
// how .NET happens to format a date, and second resolution is ample for a job that takes minutes.
//
// Registered on both serializers that see these models: the MVC one in Program.cs, which writes
// the HTTP responses, and ConversionService's own, which writes metadata.json.
public sealed class Iso8601UtcConverter : JsonConverter<DateTimeOffset>
{
    private const string Format = "yyyy-MM-ddTHH:mm:ss'Z'";

    public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        var text = reader.GetString();
        if (string.IsNullOrWhiteSpace(text))
        {
            throw new JsonException("Expected an ISO 8601 timestamp.");
        }

        // Reads back anything ISO 8601, not just what Write produces, so a metadata.json written
        // by an older build — or by hand — still loads.
        return DateTimeOffset.Parse(
            text,
            CultureInfo.InvariantCulture,
            DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal);
    }

    public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options)
    {
        writer.WriteStringValue(value.ToUniversalTime().ToString(Format, CultureInfo.InvariantCulture));
    }
}
