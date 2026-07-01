using System.Globalization;
using System.Numerics;
using System.Text;

namespace DataExchangeViewingService.Services;

// Post-processes the OBJ (and optional MTL) artifacts produced by the Data Exchange geometry
// extraction into a single, self-contained USDZ package (*.usdz).
//
// A USDZ file is an (uncompressed) zip archive whose first entry is the default USD layer. We
// reuse the shared ObjModel parser, emit an ASCII USD (*.usda) layer describing the geometry and
// UsdPreviewSurface materials, embed any referenced textures, and pack everything with the
// 64-byte data alignment that the USDZ format mandates. Both OBJ and USD use a right-handed,
// Y-up coordinate system with a bottom-left texture origin, so no coordinate conversion is needed.
public static class UsdzConverter
{
    private static readonly Vector3 DefaultDiffuse = new(0.8f, 0.8f, 0.8f);

    // Converts the given OBJ file into a USDZ package. Any MTL libraries referenced by the OBJ
    // (and resolved relative to the OBJ's folder) drive the generated materials.
    public static void ConvertObjToUsdz(string objPath, string usdzPath, ILogger? logger = null)
    {
        var memory = logger is null ? null : new MemoryTelemetry(logger, $"USDZ conversion");
        var baseFolder = Path.GetDirectoryName(Path.GetFullPath(objPath)) ?? ".";
        ObjModel obj;
        using (memory?.Step("load OBJ and MTL for USDZ"))
        {
            obj = ObjModel.Load(objPath);
        }
        var modelName = Sanitize(Path.GetFileNameWithoutExtension(objPath), "Model");

        // Group faces by material so each becomes a separate USD Mesh, mirroring the per-material
        // primitives produced by the glTF converter.
        List<MeshGroup> groups;
        using (memory?.Step("group OBJ faces by material for USDZ"))
        {
            groups = GroupFacesByMaterial(obj);
        }

        // Resolve the distinct materials used and register the textures they reference.
        var textures = new TextureRegistry(baseFolder);
        Dictionary<string, UsdMaterial> materials;
        using (memory?.Step("resolve USDZ materials and texture references"))
        {
            materials = ResolveMaterials(groups, obj, textures);
        }

        string usda;
        using (memory?.Step("build USDA text layer"))
        {
            usda = BuildUsda(obj, groups, materials, modelName);
        }

        // The default layer must be the archive's first entry.
        var layerName = modelName + ".usda";
        List<UsdzEntry> entries;
        using (memory?.Step("buffer USDA layer and textures for USDZ archive"))
        {
            entries = [new(layerName, Encoding.UTF8.GetBytes(usda))];
            foreach (var (packageName, sourcePath) in textures.Files)
            {
                using (memory?.Step($"read USDZ texture {packageName}"))
                {
                    entries.Add(new UsdzEntry(packageName, File.ReadAllBytes(sourcePath)));
                }
            }
        }

        using (memory?.Step("write USDZ archive"))
        {
            UsdzArchive.Write(usdzPath, entries, logger);
        }
    }

    private static List<MeshGroup> GroupFacesByMaterial(ObjModel obj)
    {
        var byKey = new Dictionary<string, MeshGroup>(StringComparer.Ordinal);
        var ordered = new List<MeshGroup>();

        foreach (var face in obj.Faces)
        {
            if (face.Corners.Count < 3)
            {
                continue;
            }

            // Faces referencing an unknown (or no) material fall back to a shared default bucket.
            var key = face.Material is not null && obj.Materials.ContainsKey(face.Material)
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

    private static Dictionary<string, UsdMaterial> ResolveMaterials(
        IEnumerable<MeshGroup> groups,
        ObjModel obj,
        TextureRegistry textures)
    {
        var resolved = new Dictionary<string, UsdMaterial>(StringComparer.Ordinal);
        var usedNames = new HashSet<string>(StringComparer.Ordinal);

        foreach (var group in groups)
        {
            if (resolved.ContainsKey(group.MaterialKey))
            {
                continue;
            }

            var definition = group.MaterialKey.Length > 0 ? obj.Materials[group.MaterialKey] : null;
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

        return resolved;
    }

    private static string BuildUsda(
        ObjModel obj,
        IReadOnlyList<MeshGroup> groups,
        IReadOnlyDictionary<string, UsdMaterial> materials,
        string modelName)
    {
        var sb = new StringBuilder();
        sb.Append("#usda 1.0\n");
        sb.Append("(\n");
        sb.Append($"    defaultPrim = \"{modelName}\"\n");
        sb.Append("    metersPerUnit = 1\n");
        sb.Append("    upAxis = \"Y\"\n");
        sb.Append(")\n\n");

        sb.Append($"def Xform \"{modelName}\"\n");
        sb.Append("{\n");

        for (var i = 0; i < groups.Count; i++)
        {
            AppendMesh(sb, obj, groups[i], materials[groups[i].MaterialKey], $"mesh_{i}", modelName);
        }

        sb.Append("    def Scope \"Materials\"\n");
        sb.Append("    {\n");
        foreach (var material in materials.Values)
        {
            AppendMaterial(sb, material, modelName);
        }
        sb.Append("    }\n");

        sb.Append("}\n");
        return sb.ToString();
    }

    private static void AppendMesh(
        StringBuilder sb,
        ObjModel obj,
        MeshGroup group,
        UsdMaterial material,
        string meshName,
        string modelName)
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
            var faceNormal = ComputeFaceNormal(obj, face);
            faceVertexCounts.Add(face.Corners.Count);

            foreach (var corner in face.Corners)
            {
                if (!localIndex.TryGetValue(corner.Position, out var index))
                {
                    index = points.Count;
                    localIndex[corner.Position] = index;
                    points.Add(obj.Positions[corner.Position]);
                }
                faceVertexIndices.Add(index);

                normals.Add(corner.HasNormal ? obj.Normals[corner.Normal] : faceNormal);

                if (corner.HasTexCoord)
                {
                    anyTexCoord = true;
                    uvs.Add(obj.TexCoords[corner.TexCoord]);
                }
                else
                {
                    uvs.Add(Vector2.Zero);
                }
            }
        }

        var emitTexCoords = anyTexCoord || material.Texture is not null;

        sb.Append($"    def Mesh \"{meshName}\"\n");
        sb.Append("    {\n");
        sb.Append("        uniform bool doubleSided = 1\n");
        sb.Append($"        int[] faceVertexCounts = {FormatInts(faceVertexCounts)}\n");
        sb.Append($"        int[] faceVertexIndices = {FormatInts(faceVertexIndices)}\n");
        sb.Append($"        point3f[] points = {FormatVec3(points)}\n");
        sb.Append($"        normal3f[] normals = {FormatVec3(normals)} (\n");
        sb.Append("            interpolation = \"faceVarying\"\n");
        sb.Append("        )\n");
        if (emitTexCoords)
        {
            sb.Append($"        texCoord2f[] primvars:st = {FormatVec2(uvs)} (\n");
            sb.Append("            interpolation = \"faceVarying\"\n");
            sb.Append("        )\n");
        }
        sb.Append($"        rel material:binding = </{modelName}/Materials/{material.Name}>\n");
        sb.Append("    }\n");
    }

    private static void AppendMaterial(StringBuilder sb, UsdMaterial material, string modelName)
    {
        var basePath = $"/{modelName}/Materials/{material.Name}";

        sb.Append($"        def Material \"{material.Name}\"\n");
        sb.Append("        {\n");
        sb.Append($"            token outputs:surface.connect = <{basePath}/surfaceShader.outputs:surface>\n\n");

        sb.Append("            def Shader \"surfaceShader\"\n");
        sb.Append("            {\n");
        sb.Append("                uniform token info:id = \"UsdPreviewSurface\"\n");
        if (material.Texture is not null)
        {
            sb.Append($"                color3f inputs:diffuseColor.connect = <{basePath}/diffuseTexture.outputs:rgb>\n");
        }
        else
        {
            sb.Append($"                color3f inputs:diffuseColor = {FormatColor(material.Diffuse)}\n");
        }
        sb.Append("                float inputs:metallic = 0\n");
        sb.Append($"                float inputs:opacity = {F(material.Alpha)}\n");
        sb.Append("                float inputs:roughness = 1\n");
        sb.Append("                int inputs:useSpecularWorkflow = 0\n");
        sb.Append("                token outputs:surface\n");
        sb.Append("            }\n");

        if (material.Texture is not null)
        {
            sb.Append("\n            def Shader \"stReader\"\n");
            sb.Append("            {\n");
            sb.Append("                uniform token info:id = \"UsdPrimvarReader_float2\"\n");
            sb.Append("                token inputs:varname = \"st\"\n");
            sb.Append("                float2 outputs:result\n");
            sb.Append("            }\n");

            sb.Append("\n            def Shader \"diffuseTexture\"\n");
            sb.Append("            {\n");
            sb.Append("                uniform token info:id = \"UsdUVTexture\"\n");
            sb.Append($"                asset inputs:file = @{material.Texture}@\n");
            sb.Append($"                float2 inputs:st.connect = <{basePath}/stReader.outputs:result>\n");
            sb.Append("                float3 outputs:rgb\n");
            sb.Append("            }\n");
        }

        sb.Append("        }\n");
    }

    private static Vector3 ComputeFaceNormal(ObjModel obj, ObjFace face)
    {
        // Use the explicit normals when present; otherwise derive a flat normal from the first
        // three corners (sufficient for the planar faces produced by the extraction).
        if (face.Corners.Count >= 3
            && (!face.Corners[0].HasNormal || !face.Corners[1].HasNormal || !face.Corners[2].HasNormal))
        {
            var a = obj.Positions[face.Corners[0].Position];
            var b = obj.Positions[face.Corners[1].Position];
            var c = obj.Positions[face.Corners[2].Position];
            var normal = Vector3.Cross(b - a, c - a);
            if (normal.LengthSquared() > 1e-12f)
            {
                return Vector3.Normalize(normal);
            }
        }

        return Vector3.UnitY;
    }

    private static string FormatInts(IReadOnlyList<int> values)
    {
        var sb = new StringBuilder("[");
        for (var i = 0; i < values.Count; i++)
        {
            if (i > 0)
            {
                sb.Append(", ");
            }
            sb.Append(values[i].ToString(CultureInfo.InvariantCulture));
        }
        return sb.Append(']').ToString();
    }

    private static string FormatVec3(IReadOnlyList<Vector3> values)
    {
        var sb = new StringBuilder("[");
        for (var i = 0; i < values.Count; i++)
        {
            if (i > 0)
            {
                sb.Append(", ");
            }
            sb.Append($"({F(values[i].X)}, {F(values[i].Y)}, {F(values[i].Z)})");
        }
        return sb.Append(']').ToString();
    }

    private static string FormatVec2(IReadOnlyList<Vector2> values)
    {
        var sb = new StringBuilder("[");
        for (var i = 0; i < values.Count; i++)
        {
            if (i > 0)
            {
                sb.Append(", ");
            }
            sb.Append($"({F(values[i].X)}, {F(values[i].Y)})");
        }
        return sb.Append(']').ToString();
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

    private sealed record UsdzEntry(string Name, byte[] Data);

    // Minimal writer for the "stored" (uncompressed) zip flavour required by USDZ: every file's
    // data must begin on a 64-byte boundary, which we achieve by padding each local header's
    // extra field.
    private static class UsdzArchive
    {
        private const int Alignment = 64;
        private static readonly uint[] CrcTable = BuildCrcTable();

        public static void Write(string path, IReadOnlyList<UsdzEntry> entries, ILogger? logger = null)
        {
            var memory = logger is null ? null : new MemoryTelemetry(logger, $"USDZ archive");
            using var stream = new FileStream(path, FileMode.Create, FileAccess.Write);
            using var writer = new BinaryWriter(stream, Encoding.UTF8, leaveOpen: true);

            var nameBytes = new byte[entries.Count][];
            var crcs = new uint[entries.Count];
            var localOffsets = new long[entries.Count];

            using (memory?.Step("write USDZ local file entries"))
            {
                for (var i = 0; i < entries.Count; i++)
                {
                    nameBytes[i] = Encoding.UTF8.GetBytes(entries[i].Name);
                    crcs[i] = Crc32(entries[i].Data);
                    localOffsets[i] = stream.Position;

                    // data offset = header (30) + file name + extra field; pad the extra field so it
                    // lands on a 64-byte boundary.
                    var beforeExtra = stream.Position + 30 + nameBytes[i].Length;
                    var padding = (int)((Alignment - (beforeExtra % Alignment)) % Alignment);

                    writer.Write(0x04034b50u);                  // local file header signature
                    writer.Write((ushort)20);                   // version needed to extract
                    writer.Write((ushort)0);                    // general purpose bit flag
                    writer.Write((ushort)0);                    // compression method (stored)
                    writer.Write((ushort)0);                    // last mod file time
                    writer.Write((ushort)0);                    // last mod file date
                    writer.Write(crcs[i]);                      // crc-32
                    writer.Write((uint)entries[i].Data.Length); // compressed size
                    writer.Write((uint)entries[i].Data.Length); // uncompressed size
                    writer.Write((ushort)nameBytes[i].Length);  // file name length
                    writer.Write((ushort)padding);              // extra field length (alignment pad)
                    writer.Write(nameBytes[i]);
                    if (padding > 0)
                    {
                        writer.Write(new byte[padding]);
                    }
                    writer.Write(entries[i].Data);
                }
            }

            var centralStart = stream.Position;
            using (memory?.Step("write USDZ central directory"))
            {
                for (var i = 0; i < entries.Count; i++)
                {
                    writer.Write(0x02014b50u);                  // central directory header signature
                    writer.Write((ushort)20);                   // version made by
                    writer.Write((ushort)20);                   // version needed to extract
                    writer.Write((ushort)0);                    // general purpose bit flag
                    writer.Write((ushort)0);                    // compression method (stored)
                    writer.Write((ushort)0);                    // last mod file time
                    writer.Write((ushort)0);                    // last mod file date
                    writer.Write(crcs[i]);                      // crc-32
                    writer.Write((uint)entries[i].Data.Length); // compressed size
                    writer.Write((uint)entries[i].Data.Length); // uncompressed size
                    writer.Write((ushort)nameBytes[i].Length);  // file name length
                    writer.Write((ushort)0);                    // extra field length
                    writer.Write((ushort)0);                    // file comment length
                    writer.Write((ushort)0);                    // disk number start
                    writer.Write((ushort)0);                    // internal file attributes
                    writer.Write((uint)0);                      // external file attributes
                    writer.Write((uint)localOffsets[i]);        // relative offset of local header
                    writer.Write(nameBytes[i]);
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

        private static uint Crc32(byte[] data)
        {
            var crc = 0xFFFFFFFFu;
            foreach (var b in data)
            {
                crc = CrcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
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
