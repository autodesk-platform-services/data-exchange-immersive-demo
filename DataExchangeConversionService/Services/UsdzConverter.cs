using System.Text;

namespace DataExchangeConversionService.Services;

// Bundles the native USD folder produced by the Data Exchange SDK into a single,
// self-contained USDZ package while preserving all package-relative asset paths.
public static class UsdzConverter
{
    private static readonly HashSet<string> UsdLayerExtensions =
        new(StringComparer.OrdinalIgnoreCase) { ".usd", ".usda", ".usdc" };

    public static void BundleUsdFolder(
        string usdFolderPath,
        string usdzPath,
        ILogger? logger = null,
        string? logPath = null)
    {
        var rootPath = Path.GetFullPath(usdFolderPath);
        if (!Directory.Exists(rootPath))
        {
            throw new DirectoryNotFoundException($"The USD folder '{rootPath}' does not exist.");
        }

        var files = Directory
            .EnumerateFiles(rootPath, "*", SearchOption.AllDirectories)
            .Select(sourcePath => new UsdzEntry(
                Path.GetRelativePath(rootPath, sourcePath).Replace(Path.DirectorySeparatorChar, '/'),
                sourcePath))
            .OrderBy(entry => entry.Name, StringComparer.Ordinal)
            .ToList();

        if (files.Count == 0)
        {
            throw new InvalidOperationException($"The USD folder '{rootPath}' is empty.");
        }

        // USDZ readers treat the first archive entry as the default layer. Prefer a layer at the
        // folder root, then the shallowest nested layer, while keeping selection deterministic.
        var defaultLayer = files
            .Where(entry => UsdLayerExtensions.Contains(Path.GetExtension(entry.Name)))
            .OrderBy(entry => entry.Name.Count(character => character == '/'))
            .ThenBy(entry => entry.Name, StringComparer.Ordinal)
            .FirstOrDefault()
            ?? throw new InvalidOperationException($"The USD folder '{rootPath}' contains no USD layer.");

        files.Remove(defaultLayer);
        files.Insert(0, defaultLayer);

        Log(logger, logPath, $"Bundling {files.Count} USD assets with default layer '{defaultLayer.Name}'.");
        UsdzArchive.Write(usdzPath, files);
    }

    private static void Log(ILogger? logger, string? logPath, string message)
    {
        logger?.LogInformation(message);
        if (!string.IsNullOrWhiteSpace(logPath))
        {
            File.AppendAllText(logPath, $"{DateTimeOffset.UtcNow:O} {message}{Environment.NewLine}");
        }
    }

    private sealed record UsdzEntry(string Name, string SourcePath);

    private readonly record struct UsdzEntryInfo(byte[] NameBytes, uint Crc, long Length, long LocalOffset);

    // Minimal writer for the stored (uncompressed) ZIP flavor required by USDZ. Each file's data
    // starts on a 64-byte boundary by padding its local header's extra field.
    private static class UsdzArchive
    {
        private const int Alignment = 64;
        private static readonly uint[] CrcTable = BuildCrcTable();

        public static void Write(string path, IReadOnlyList<UsdzEntry> entries)
        {
            using var stream = new FileStream(path, FileMode.Create, FileAccess.Write);
            using var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true);
            var infos = new UsdzEntryInfo[entries.Count];

            for (var i = 0; i < entries.Count; i++)
            {
                var entry = entries[i];
                var nameBytes = Encoding.UTF8.GetBytes(entry.Name);
                var length = new FileInfo(entry.SourcePath).Length;
                var crc = Crc32(entry.SourcePath);
                var localOffset = stream.Position;
                var beforeExtra = stream.Position + 30 + nameBytes.Length;
                var padding = (int)((Alignment - (beforeExtra % Alignment)) % Alignment);

                writer.Write(0x04034b50u);
                writer.Write((ushort)20);
                writer.Write((ushort)0);
                writer.Write((ushort)0);
                writer.Write((ushort)0);
                writer.Write((ushort)0);
                writer.Write(crc);
                writer.Write(checked((uint)length));
                writer.Write(checked((uint)length));
                writer.Write(checked((ushort)nameBytes.Length));
                writer.Write(checked((ushort)padding));
                writer.Write(nameBytes);
                if (padding > 0)
                {
                    writer.Write(new byte[padding]);
                }

                using (var source = new FileStream(entry.SourcePath, FileMode.Open, FileAccess.Read, FileShare.Read))
                {
                    source.CopyTo(stream);
                }

                infos[i] = new UsdzEntryInfo(nameBytes, crc, length, localOffset);
            }

            var centralStart = stream.Position;
            foreach (var info in infos)
            {
                writer.Write(0x02014b50u);
                writer.Write((ushort)20);
                writer.Write((ushort)20);
                writer.Write((ushort)0);
                writer.Write((ushort)0);
                writer.Write((ushort)0);
                writer.Write((ushort)0);
                writer.Write(info.Crc);
                writer.Write(checked((uint)info.Length));
                writer.Write(checked((uint)info.Length));
                writer.Write(checked((ushort)info.NameBytes.Length));
                writer.Write((ushort)0);
                writer.Write((ushort)0);
                writer.Write((ushort)0);
                writer.Write((ushort)0);
                writer.Write((uint)0);
                writer.Write(checked((uint)info.LocalOffset));
                writer.Write(info.NameBytes);
            }
            var centralEnd = stream.Position;

            writer.Write(0x06054b50u);
            writer.Write((ushort)0);
            writer.Write((ushort)0);
            writer.Write(checked((ushort)entries.Count));
            writer.Write(checked((ushort)entries.Count));
            writer.Write(checked((uint)(centralEnd - centralStart)));
            writer.Write(checked((uint)centralStart));
            writer.Write((ushort)0);
        }

        private static uint Crc32(string path)
        {
            var crc = 0xFFFFFFFFu;
            Span<byte> buffer = stackalloc byte[8192];
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            int bytesRead;
            while ((bytesRead = stream.Read(buffer)) > 0)
            {
                foreach (var value in buffer[..bytesRead])
                {
                    crc = CrcTable[(crc ^ value) & 0xFF] ^ (crc >> 8);
                }
            }

            return crc ^ 0xFFFFFFFFu;
        }

        private static uint[] BuildCrcTable()
        {
            var table = new uint[256];
            for (var i = 0u; i < 256u; i++)
            {
                var value = i;
                for (var bit = 0; bit < 8; bit++)
                {
                    value = (value & 1) != 0 ? 0xEDB88320u ^ (value >> 1) : value >> 1;
                }

                table[i] = value;
            }

            return table;
        }
    }
}
