using System.Security.Cryptography;

namespace DataExchangeConversionService.Models;

// One file produced by a conversion, as described to clients.
//
// Clients used to receive a bare file name and work the rest out themselves. Both apps picked
// their model by string suffix — `endsWith(".usdz")` in the web app, `hasSuffix(ext)` in the
// visionOS one — and neither could know how large a download would be until the response headers
// arrived, which is why the visionOS progress bar started out indeterminate on a download that can
// run to several hundred megabytes.
public sealed class ConversionArtifact
{
    public string Name { get; set; } = string.Empty;

    // What the file is for, so a client selects one by meaning rather than by parsing its name.
    public string Type { get; set; } = ArtifactTypes.Unknown;

    public string ContentType { get; set; } = ArtifactTypes.DefaultContentType;

    // Bytes on disk, so a client can show a determinate progress bar from the first byte and size
    // its cache before committing to the download.
    public long Size { get; set; }

    // "sha256:<lowercase hex>". Lets a client cache confirm that what it stored is what the
    // service sent, and tell two conversions of the same exchange apart by content.
    public string? Checksum { get; set; }

    // Describes a file that has been fully written. Called at the point each artifact is
    // finalised, so the size and digest describe the finished file rather than a partial one.
    public static ConversionArtifact Describe(string path)
    {
        var info = new FileInfo(path);
        var (type, contentType) = ArtifactTypes.For(info.Name);

        return new ConversionArtifact
        {
            Name = info.Name,
            Type = type,
            ContentType = contentType,
            Size = info.Length,
            Checksum = ComputeChecksum(path),
        };
    }

    // Streamed rather than loaded, because these files run to hundreds of megabytes and the whole
    // point of the artifact pipeline is to not hold one in the managed heap.
    private static string ComputeChecksum(string path)
    {
        using var stream = File.OpenRead(path);
        return $"sha256:{Convert.ToHexStringLower(SHA256.HashData(stream))}";
    }
}

// The single place that decides what a produced file is and how it is served. Both the artifact
// descriptions above and the artifact download read from it, so a client cannot be told one
// content type in the status and sent another with the bytes.
public static class ArtifactTypes
{
    public const string Unknown = "unknown";
    public const string DefaultContentType = "application/octet-stream";

    public static (string Type, string ContentType) For(string fileName)
    {
        return Path.GetExtension(fileName).ToLowerInvariant() switch
        {
            ".obj" => ("obj", "model/obj"),
            ".mtl" => ("mtl", "model/mtl"),
            ".glb" => ("glb", "model/gltf-binary"),
            ".usdz" => ("usdz", "model/vnd.usdz+zip"),
            // The only .txt a conversion produces is its own log.
            ".txt" => ("log", "text/plain"),
            _ => (Unknown, DefaultContentType),
        };
    }
}
