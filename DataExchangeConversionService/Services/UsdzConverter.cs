using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Numerics;
using System.Text;

namespace DataExchangeViewingService.Services;

// Post-processes the OBJ (and optional MTL) artifacts produced by the Data Exchange geometry
// extraction into a single, self-contained USDZ package (*.usdz).
//
// A USDZ file is an (uncompressed) zip archive whose first entry is the default USD layer. We
// reuse the shared ObjReader parser, emit an ASCII USD (*.usda) layer describing the geometry and
// UsdPreviewSurface materials, embed any referenced textures, and pack everything with the
// 64-byte data alignment that the USDZ format mandates. Both OBJ and USD use a right-handed,
// Y-up coordinate system with a bottom-left texture origin, so no coordinate conversion is needed
// once the OBJ has been reoriented (see convertZUpToYUp).
public static class UsdzConverter
{
    private static readonly Vector3 DefaultDiffuse = new(0.8f, 0.8f, 0.8f);

    // Converts the given OBJ file into a USDZ package. Any MTL libraries referenced by the OBJ
    // (and resolved relative to the OBJ's folder) drive the generated materials. Each OBJ group
    // ("g") becomes its own named child Xform, further split into per-material Mesh prims. When
    // convertZUpToYUp is set, vertex positions/normals are rotated from Z-up to Y-up on the fly as
    // they're read.
    public static void ConvertObjToUsdz(string objPath, string usdzPath, bool convertZUpToYUp = true, ILogger? logger = null, string? logPath = null)
    {
        var memory = logger is null ? null : new MemoryTelemetry(logger, $"USDZ conversion", logPath);
        var baseFolder = Path.GetDirectoryName(Path.GetFullPath(objPath)) ?? ".";
        var modelName = Sanitize(Path.GetFileNameWithoutExtension(objPath), "Model");

        // The default layer must be the archive's first entry.
        var layerName = modelName + ".usda";
        var usdzFolder = Path.GetDirectoryName(Path.GetFullPath(usdzPath)) ?? ".";
        var usdaPath = Path.Combine(usdzFolder, layerName);
        var textures = new TextureRegistry(baseFolder);

        using (memory?.Step("stream OBJ groups into USDA text layer"))
        {
            WriteUsda(usdaPath, objPath, convertZUpToYUp, textures, modelName);
        }

        List<UsdzEntry> entries;
        using (memory?.Step("resolve USDA layer and textures for USDZ archive"))
        {
            entries = [new(layerName, usdaPath)];
            foreach (var (packageName, sourcePath) in textures.Files)
            {
                entries.Add(new UsdzEntry(packageName, sourcePath));
            }
        }

        using (memory?.Step("write USDZ archive"))
        {
            UsdzArchive.Write(usdzPath, entries, logger, logPath);
        }

        using (memory?.Step("optimize USDZ archive to crate format"))
        {
            TryOptimizeToCrate(usdzPath, logger, logPath);
        }
    }

    // Best-effort post-process that re-encodes the USDZ package's ASCII default layer as a
    // binary crate (.usdc) layer via Scripts/usdz_to_crate.py, which is smaller and loads
    // faster. The target machine may not have Python or its usd-core dependency installed, so
    // any failure here is logged and swallowed rather than failing the overall conversion.
    private static void TryOptimizeToCrate(string usdzPath, ILogger? logger, string? logPath)
    {
        var scriptPath = Path.Combine(AppContext.BaseDirectory, "Scripts", "usdz_to_crate.py");
        if (!File.Exists(scriptPath))
        {
            return;
        }

        try
        {
            var startInfo = new ProcessStartInfo("python")
            {
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            startInfo.ArgumentList.Add(scriptPath);
            startInfo.ArgumentList.Add(usdzPath);

            using var process = Process.Start(startInfo);
            if (process is null)
            {
                LogOptimizationSkipped(logger, logPath, "the Python process could not be started");
                return;
            }

            // Drain both streams concurrently before blocking on exit, since the child could
            // otherwise deadlock writing to a full stdout/stderr pipe that nobody is reading yet.
            var stderrTask = process.StandardError.ReadToEndAsync();
            process.StandardOutput.ReadToEndAsync();
            process.WaitForExit();

            if (process.ExitCode != 0)
            {
                var stderr = stderrTask.GetAwaiter().GetResult().Trim();
                LogOptimizationSkipped(logger, logPath, $"python exited with code {process.ExitCode} ({stderr})");
            }
        }
        catch (Exception ex) when (ex is Win32Exception or IOException)
        {
            LogOptimizationSkipped(logger, logPath, $"Python is not available ({ex.Message})");
        }
    }

    private static void LogOptimizationSkipped(ILogger? logger, string? logPath, string reason)
    {
        var message = $"USDZ crate optimization was not possible: {reason}.";
        logger?.LogInformation(message);
        if (!string.IsNullOrWhiteSpace(logPath))
        {
            File.AppendAllText(logPath, $"{DateTimeOffset.UtcNow:O} {message}{Environment.NewLine}");
        }
    }

    private static List<MeshGroup> GroupFacesByMaterial(IReadOnlyList<ObjFace> faces, ObjReader reader)
    {
        var byKey = new Dictionary<string, MeshGroup>(StringComparer.Ordinal);
        var ordered = new List<MeshGroup>();

        foreach (var face in faces)
        {
            if (face.Corners.Count < 3)
            {
                continue;
            }

            // Faces referencing an unknown (or no) material fall back to a shared default bucket.
            var key = face.Material is not null && reader.GetMaterial(face.Material) is not null
                ? face.Material
                : string.Empty;

            if (!byKey.TryGetValue(key, out var group))
            {
                group = new MeshGroup(key);
                byKey[key] = group;
                ordered.Add(group);
            }

            group.Faces.Add(face);
        }

        return ordered;
    }

    // Registers any materials used by these mesh groups that haven't already been resolved.
    private static void ResolveMaterials(
        IEnumerable<MeshGroup> groups,
        ObjReader reader,
        TextureRegistry textures,
        Dictionary<string, UsdMaterial> resolved,
        HashSet<string> usedNames)
    {
        foreach (var group in groups)
        {
            if (resolved.ContainsKey(group.MaterialKey))
            {
                continue;
            }

            var definition = group.MaterialKey.Length > 0 ? reader.GetMaterial(group.MaterialKey) : null;
            var name = UniqueName(
                Sanitize(group.MaterialKey.Length > 0 ? group.MaterialKey : "defaultMaterial", "material"),
                usedNames);

            var texture = definition?.DiffuseTexture is { } relativePath
                ? textures.Register(relativePath)
                : null;

            resolved[group.MaterialKey] = new UsdMaterial(
                name,
                definition?.Diffuse ?? DefaultDiffuse,
                definition?.Alpha ?? 1f,
                texture);
        }
    }

    private static void WriteUsda(
        string path,
        string objPath,
        bool convertZUpToYUp,
        TextureRegistry textures,
        string modelName)
    {
        using var writer = new StreamWriter(path, append: false, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
        writer.Write("#usda 1.0\n");
        writer.Write("(\n");
        writer.Write($"    defaultPrim = \"{modelName}\"\n");
        writer.Write("    metersPerUnit = 1\n");
        writer.Write("    upAxis = \"Y\"\n");
        writer.Write(")\n\n");

        writer.Write($"def Xform \"{modelName}\"\n");
        writer.Write("{\n");

        var materials = new Dictionary<string, UsdMaterial>(StringComparer.Ordinal);
        var usedMaterialNames = new HashSet<string>(StringComparer.Ordinal);
        var usedGroupNames = new HashSet<string>(StringComparer.Ordinal);

        using (var reader = new ObjReader(objPath, convertZUpToYUp))
        {
            foreach (var group in reader.ReadGroups())
            {
                var meshGroups = GroupFacesByMaterial(group.Faces, reader);
                ResolveMaterials(meshGroups, reader, textures, materials, usedMaterialNames);

                var xformName = UniqueName(Sanitize(group.Name, "group"), usedGroupNames);
                WriteGroupXform(writer, reader, meshGroups, materials, modelName, xformName);
            }
        }

        writer.Write("    def Scope \"Materials\"\n");
        writer.Write("    {\n");
        foreach (var material in materials.Values)
        {
            WriteMaterial(writer, material, modelName);
        }
        writer.Write("    }\n");

        writer.Write("}\n");
    }

    private static void WriteGroupXform(
        TextWriter writer,
        ObjReader reader,
        IReadOnlyList<MeshGroup> meshGroups,
        IReadOnlyDictionary<string, UsdMaterial> materials,
        string modelName,
        string xformName)
    {
        writer.Write($"    def Xform \"{xformName}\"\n");
        writer.Write("    {\n");

        for (var i = 0; i < meshGroups.Count; i++)
        {
            WriteMesh(writer, reader, meshGroups[i], materials[meshGroups[i].MaterialKey], $"mesh_{i}", modelName, "        ");
        }

        writer.Write("    }\n");
    }

    private static void WriteMesh(
        TextWriter writer,
        ObjReader reader,
        MeshGroup group,
        UsdMaterial material,
        string meshName,
        string modelName,
        string indent)
    {
        // Build a self-contained vertex set for this material group. Positions are de-duplicated
        // per group; normals and UVs are face-varying (one value per face corner).
        var localIndex = new Dictionary<int, int>();
        var points = new List<Vector3>();
        var faceVertexCounts = new List<int>();
        var faceVertexIndices = new List<int>();
        var normals = new List<Vector3>();
        var uvs = new List<Vector2>();
        var anyTexCoord = false;

        foreach (var face in group.Faces)
        {
            var faceNormal = ComputeFaceNormal(reader.Positions, face);
            faceVertexCounts.Add(face.Corners.Count);

            foreach (var corner in face.Corners)
            {
                if (!localIndex.TryGetValue(corner.Position, out var index))
                {
                    index = points.Count;
                    localIndex[corner.Position] = index;
                    points.Add(reader.Positions[corner.Position]);
                }
                faceVertexIndices.Add(index);

                normals.Add(corner.HasNormal ? reader.Normals[corner.Normal] : faceNormal);

                if (corner.HasTexCoord)
                {
                    anyTexCoord = true;
                    uvs.Add(reader.TexCoords[corner.TexCoord]);
                }
                else
                {
                    uvs.Add(Vector2.Zero);
                }
            }
        }

        var emitTexCoords = anyTexCoord || material.Texture is not null;
        var body = indent + "    ";

        writer.Write($"{indent}def Mesh \"{meshName}\"\n");
        writer.Write($"{indent}{{\n");
        writer.Write($"{body}uniform bool doubleSided = 1\n");
        writer.Write($"{body}int[] faceVertexCounts = ");
        WriteInts(writer, faceVertexCounts);
        writer.Write('\n');
        writer.Write($"{body}int[] faceVertexIndices = ");
        WriteInts(writer, faceVertexIndices);
        writer.Write('\n');
        writer.Write($"{body}point3f[] points = ");
        WriteVec3(writer, points);
        writer.Write('\n');
        writer.Write($"{body}normal3f[] normals = ");
        WriteVec3(writer, normals);
        writer.Write(" (\n");
        writer.Write($"{body}    interpolation = \"faceVarying\"\n");
        writer.Write($"{body})\n");
        if (emitTexCoords)
        {
            writer.Write($"{body}texCoord2f[] primvars:st = ");
            WriteVec2(writer, uvs);
            writer.Write(" (\n");
            writer.Write($"{body}    interpolation = \"faceVarying\"\n");
            writer.Write($"{body})\n");
        }
        writer.Write($"{body}rel material:binding = </{modelName}/Materials/{material.Name}>\n");
        writer.Write($"{indent}}}\n");
    }

    private static void WriteMaterial(TextWriter writer, UsdMaterial material, string modelName)
    {
        var basePath = $"/{modelName}/Materials/{material.Name}";

        writer.Write($"        def Material \"{material.Name}\"\n");
        writer.Write("        {\n");
        writer.Write($"            token outputs:surface.connect = <{basePath}/surfaceShader.outputs:surface>\n\n");

        writer.Write("            def Shader \"surfaceShader\"\n");
        writer.Write("            {\n");
        writer.Write("                uniform token info:id = \"UsdPreviewSurface\"\n");
        if (material.Texture is not null)
        {
            writer.Write($"                color3f inputs:diffuseColor.connect = <{basePath}/diffuseTexture.outputs:rgb>\n");
        }
        else
        {
            writer.Write($"                color3f inputs:diffuseColor = {FormatColor(material.Diffuse)}\n");
        }
        writer.Write("                float inputs:metallic = 0\n");
        writer.Write($"                float inputs:opacity = {F(material.Alpha)}\n");
        writer.Write("                float inputs:roughness = 1\n");
        writer.Write("                int inputs:useSpecularWorkflow = 0\n");
        writer.Write("                token outputs:surface\n");
        writer.Write("            }\n");

        if (material.Texture is not null)
        {
            writer.Write("\n            def Shader \"stReader\"\n");
            writer.Write("            {\n");
            writer.Write("                uniform token info:id = \"UsdPrimvarReader_float2\"\n");
            writer.Write("                token inputs:varname = \"st\"\n");
            writer.Write("                float2 outputs:result\n");
            writer.Write("            }\n");

            writer.Write("\n            def Shader \"diffuseTexture\"\n");
            writer.Write("            {\n");
            writer.Write("                uniform token info:id = \"UsdUVTexture\"\n");
            writer.Write($"                asset inputs:file = @{material.Texture}@\n");
            writer.Write($"                float2 inputs:st.connect = <{basePath}/stReader.outputs:result>\n");
            writer.Write("                float3 outputs:rgb\n");
            writer.Write("            }\n");
        }

        writer.Write("        }\n");
    }

    private static Vector3 ComputeFaceNormal(IReadOnlyList<Vector3> positions, ObjFace face)
    {
        // Use the explicit normals when present; otherwise derive a flat normal from the first
        // three corners (sufficient for the planar faces produced by the extraction).
        if (face.Corners.Count >= 3
            && (!face.Corners[0].HasNormal || !face.Corners[1].HasNormal || !face.Corners[2].HasNormal))
        {
            var a = positions[face.Corners[0].Position];
            var b = positions[face.Corners[1].Position];
            var c = positions[face.Corners[2].Position];
            return ObjReader.ComputeNormal(a, b, c);
        }

        return Vector3.UnitY;
    }

    private static void WriteInts(TextWriter writer, IReadOnlyList<int> values)
    {
        writer.Write('[');
        for (var i = 0; i < values.Count; i++)
        {
            if (i > 0)
            {
                writer.Write(", ");
            }
            writer.Write(values[i].ToString(CultureInfo.InvariantCulture));
        }
        writer.Write(']');
    }

    private static void WriteVec3(TextWriter writer, IReadOnlyList<Vector3> values)
    {
        writer.Write('[');
        for (var i = 0; i < values.Count; i++)
        {
            if (i > 0)
            {
                writer.Write(", ");
            }
            writer.Write($"({F(values[i].X)}, {F(values[i].Y)}, {F(values[i].Z)})");
        }
        writer.Write(']');
    }

    private static void WriteVec2(TextWriter writer, IReadOnlyList<Vector2> values)
    {
        writer.Write('[');
        for (var i = 0; i < values.Count; i++)
        {
            if (i > 0)
            {
                writer.Write(", ");
            }
            writer.Write($"({F(values[i].X)}, {F(values[i].Y)})");
        }
        writer.Write(']');
    }

    private static string FormatColor(Vector3 color) => $"({F(color.X)}, {F(color.Y)}, {F(color.Z)})";

    private static string F(float value) => value.ToString("0.######", CultureInfo.InvariantCulture);

    // Turns an arbitrary string into a valid USD identifier ([A-Za-z_][A-Za-z0-9_]*).
    private static string Sanitize(string value, string fallback)
    {
        var sb = new StringBuilder(value.Length);
        foreach (var ch in value)
        {
            sb.Append(char.IsLetterOrDigit(ch) && ch < 128 ? ch : '_');
        }

        var result = sb.ToString();
        if (result.Length == 0)
        {
            return fallback;
        }

        return char.IsDigit(result[0]) ? "_" + result : result;
    }

    private static string UniqueName(string name, HashSet<string> used)
    {
        var candidate = name;
        var suffix = 1;
        while (!used.Add(candidate))
        {
            candidate = $"{name}_{suffix++}";
        }
        return candidate;
    }

    private sealed class MeshGroup(string materialKey)
    {
        public string MaterialKey { get; } = materialKey;
        public List<ObjFace> Faces { get; } = [];
    }

    private sealed record UsdMaterial(string Name, Vector3 Diffuse, float Alpha, string? Texture);

    // Maps texture source files onto unique, valid entry names inside the USDZ package.
    private sealed class TextureRegistry(string baseFolder)
    {
        private readonly Dictionary<string, string> _bySourcePath = new(StringComparer.OrdinalIgnoreCase);
        private readonly HashSet<string> _packageNames = new(StringComparer.OrdinalIgnoreCase);

        public IEnumerable<(string PackageName, string SourcePath)> Files =>
            _bySourcePath.Select(pair => (pair.Value, pair.Key));

        // Registers the texture (if it exists on disk) and returns its package-relative name,
        // or null when the file is missing.
        public string? Register(string relativePath)
        {
            var sourcePath = Path.Combine(baseFolder, relativePath);
            if (!File.Exists(sourcePath))
            {
                return null;
            }

            if (_bySourcePath.TryGetValue(sourcePath, out var existing))
            {
                return existing;
            }

            var fileName = Path.GetFileName(relativePath);
            var name = Sanitize(Path.GetFileNameWithoutExtension(fileName), "texture")
                + Path.GetExtension(fileName).ToLowerInvariant();

            var unique = name;
            var suffix = 1;
            while (!_packageNames.Add(unique))
            {
                unique = $"{Path.GetFileNameWithoutExtension(name)}_{suffix++}{Path.GetExtension(name)}";
            }

            _bySourcePath[sourcePath] = unique;
            return unique;
        }
    }

    private sealed record UsdzEntry(string Name, string SourcePath);

    private readonly record struct UsdzEntryInfo(byte[] NameBytes, uint Crc, long Length, long LocalOffset);

    // Minimal writer for the "stored" (uncompressed) zip flavour required by USDZ: every file's
    // data must begin on a 64-byte boundary, which we achieve by padding each local header's
    // extra field.
    private static class UsdzArchive
    {
        private const int Alignment = 64;
        private static readonly uint[] CrcTable = BuildCrcTable();

        public static void Write(string path, IReadOnlyList<UsdzEntry> entries, ILogger? logger = null, string? logPath = null)
        {
            var memory = logger is null ? null : new MemoryTelemetry(logger, $"USDZ archive", logPath);
            using var stream = new FileStream(path, FileMode.Create, FileAccess.Write);
            using var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true);

            var infos = new UsdzEntryInfo[entries.Count];

            using (memory?.Step("write USDZ local file entries"))
            {
                for (var i = 0; i < entries.Count; i++)
                {
                    var entry = entries[i];
                    var nameBytes = Encoding.UTF8.GetBytes(entry.Name);
                    var length = new FileInfo(entry.SourcePath).Length;
                    var crc = Crc32(entry.SourcePath);
                    var localOffset = stream.Position;

                    // data offset = header (30) + file name + extra field; pad the extra field so it
                    // lands on a 64-byte boundary.
                    var beforeExtra = stream.Position + 30 + nameBytes.Length;
                    var padding = (int)((Alignment - (beforeExtra % Alignment)) % Alignment);

                    writer.Write(0x04034b50u);                  // local file header signature
                    writer.Write((ushort)20);                   // version needed to extract
                    writer.Write((ushort)0);                    // general purpose bit flag
                    writer.Write((ushort)0);                    // compression method (stored)
                    writer.Write((ushort)0);                    // last mod file time
                    writer.Write((ushort)0);                    // last mod file date
                    writer.Write(crc);                          // crc-32
                    writer.Write((uint)length);                 // compressed size
                    writer.Write((uint)length);                 // uncompressed size
                    writer.Write((ushort)nameBytes.Length);     // file name length
                    writer.Write((ushort)padding);              // extra field length (alignment pad)
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
            }

            var centralStart = stream.Position;
            using (memory?.Step("write USDZ central directory"))
            {
                for (var i = 0; i < entries.Count; i++)
                {
                    var info = infos[i];
                    writer.Write(0x02014b50u);                  // central directory header signature
                    writer.Write((ushort)20);                   // version made by
                    writer.Write((ushort)20);                   // version needed to extract
                    writer.Write((ushort)0);                    // general purpose bit flag
                    writer.Write((ushort)0);                    // compression method (stored)
                    writer.Write((ushort)0);                    // last mod file time
                    writer.Write((ushort)0);                    // last mod file date
                    writer.Write(info.Crc);                     // crc-32
                    writer.Write((uint)info.Length);            // compressed size
                    writer.Write((uint)info.Length);            // uncompressed size
                    writer.Write((ushort)info.NameBytes.Length);// file name length
                    writer.Write((ushort)0);                    // extra field length
                    writer.Write((ushort)0);                    // file comment length
                    writer.Write((ushort)0);                    // disk number start
                    writer.Write((ushort)0);                    // internal file attributes
                    writer.Write((uint)0);                      // external file attributes
                    writer.Write((uint)info.LocalOffset);       // relative offset of local header
                    writer.Write(info.NameBytes);
                }
            }
            var centralEnd = stream.Position;

            writer.Write(0x06054b50u);                      // end of central directory signature
            writer.Write((ushort)0);                        // number of this disk
            writer.Write((ushort)0);                        // disk where central directory starts
            writer.Write((ushort)entries.Count);            // central directory records on this disk
            writer.Write((ushort)entries.Count);            // total central directory records
            writer.Write((uint)(centralEnd - centralStart));// size of central directory
            writer.Write((uint)centralStart);               // offset of central directory
            writer.Write((ushort)0);                        // comment length
        }

        private static uint Crc32(string path)
        {
            var crc = 0xFFFFFFFFu;
            Span<byte> buffer = stackalloc byte[8192];
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            int bytesRead;
            while ((bytesRead = stream.Read(buffer)) > 0)
            {
                foreach (var b in buffer[..bytesRead])
                {
                    crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
                }
            }
            return crc ^ 0xFFFFFFFFu;
        }

        private static uint[] BuildCrcTable()
        {
            var table = new uint[256];
            for (var i = 0u; i < 256u; i++)
            {
                var c = i;
                for (var k = 0; k < 8; k++)
                {
                    c = (c & 1) != 0 ? 0xEDB88320u ^ (c >> 1) : c >> 1;
                }
                table[i] = c;
            }
            return table;
        }
    }
}
