using System.Globalization;
using System.Numerics;
using System.Text;

namespace DataExchangeViewingService.Services;

// Parsed representation of a Wavefront OBJ file together with the materials declared in any
// referenced MTL libraries. Shared by the glTF and USDZ post-processors so the (fiddly) OBJ/MTL
// parsing lives in a single place.
//
// Texture coordinates are stored exactly as written in the OBJ (bottom-left origin). Consumers
// that need a different convention (e.g. glTF's top-left origin) flip the V coordinate themselves.
public sealed class ObjModel
{
    public List<Vector3> Positions { get; } = [];
    public List<Vector3> Normals { get; } = [];
    public List<Vector2> TexCoords { get; } = [];
    public List<ObjFace> Faces { get; } = [];
    public List<string> MaterialLibraries { get; } = [];
    public Dictionary<string, MtlMaterial> Materials { get; } = new(StringComparer.OrdinalIgnoreCase);

    // Parses the OBJ at the given path along with any MTL libraries it references (resolved
    // relative to the OBJ's folder).
    public static ObjModel Load(string objPath)
    {
        var model = ParseObj(objPath);

        var baseFolder = Path.GetDirectoryName(Path.GetFullPath(objPath)) ?? ".";
        foreach (var library in model.MaterialLibraries)
        {
            var mtlPath = Path.Combine(baseFolder, library);
            if (File.Exists(mtlPath))
            {
                ParseMtl(mtlPath, model.Materials);
            }
        }

        return model;
    }

    // Rewrites the OBJ in place, rotating its geometry from the Z-up convention emitted by the
    // Data Exchange geometry extraction to the Y-up convention that OBJ/glTF/USD viewers assume.
    // Only vertex positions ("v") and normals ("vn") are rotated; every other line (texture
    // coordinates, faces, material directives, comments, blank lines) is copied through verbatim.
    public static void ConvertZUpToYUp(string objPath)
    {
        var tempPath = objPath + ".tmp";
        using (var reader = new StreamReader(objPath))
        using (var writer = new StreamWriter(tempPath))
        {
            string? line;
            while ((line = reader.ReadLine()) is not null)
            {
                writer.WriteLine(RotateZUpLine(line));
            }
        }

        File.Move(tempPath, objPath, overwrite: true);
    }

    // Applies a -90° rotation about the X axis to a single "v"/"vn" line, mapping (x, y, z) to
    // (x, z, -y) so the source's +Z (up) lands on +Y (up). Other lines are returned unchanged.
    private static string RotateZUpLine(string line)
    {
        var tokens = SplitTokens(line);
        if (tokens.Length < 4 || (tokens[0] != "v" && tokens[0] != "vn"))
        {
            return line;
        }

        var x = ParseFloat(tokens, 1);
        var y = ParseFloat(tokens, 2);
        var z = ParseFloat(tokens, 3);

        var sb = new StringBuilder();
        sb.Append(tokens[0]);
        sb.Append(' ').Append(FormatFloat(x));
        sb.Append(' ').Append(FormatFloat(z));
        sb.Append(' ').Append(FormatFloat(-y));

        // Preserve any trailing components (e.g. per-vertex colors, homogeneous w).
        for (var i = 4; i < tokens.Length; i++)
        {
            sb.Append(' ').Append(tokens[i]);
        }

        return sb.ToString();
    }

    private static string FormatFloat(float value) => value.ToString("R", CultureInfo.InvariantCulture);

    private static ObjModel ParseObj(string objPath)
    {
        var data = new ObjModel();
        string? currentMaterial = null;

        foreach (var rawLine in File.ReadLines(objPath))
        {
            var tokens = SplitTokens(rawLine);
            if (tokens.Length == 0 || tokens[0].StartsWith('#'))
            {
                continue;
            }

            switch (tokens[0])
            {
                case "v":
                    data.Positions.Add(new Vector3(
                        ParseFloat(tokens, 1),
                        ParseFloat(tokens, 2),
                        ParseFloat(tokens, 3)));
                    break;

                case "vn":
                    data.Normals.Add(new Vector3(
                        ParseFloat(tokens, 1),
                        ParseFloat(tokens, 2),
                        ParseFloat(tokens, 3)));
                    break;

                case "vt":
                    data.TexCoords.Add(new Vector2(
                        ParseFloat(tokens, 1),
                        ParseFloat(tokens, 2)));
                    break;

                case "f":
                    data.Faces.Add(ParseFace(tokens, data, currentMaterial));
                    break;

                case "usemtl":
                    currentMaterial = tokens.Length > 1 ? tokens[1] : null;
                    break;

                case "mtllib":
                    for (var i = 1; i < tokens.Length; i++)
                    {
                        data.MaterialLibraries.Add(tokens[i]);
                    }
                    break;
            }
        }

        return data;
    }

    private static ObjFace ParseFace(string[] tokens, ObjModel data, string? material)
    {
        var face = new ObjFace { Material = material };

        for (var i = 1; i < tokens.Length; i++)
        {
            var parts = tokens[i].Split('/');

            var position = ResolveIndex(parts, 0, data.Positions.Count);
            var texCoord = ResolveIndex(parts, 1, data.TexCoords.Count);
            var normal = ResolveIndex(parts, 2, data.Normals.Count);

            // Skip corners without a usable position; out-of-range indices are dropped too.
            if (position < 0 || position >= data.Positions.Count)
            {
                continue;
            }

            // Guard against stale/out-of-range optional indices.
            if (texCoord >= data.TexCoords.Count)
            {
                texCoord = -1;
            }
            if (normal >= data.Normals.Count)
            {
                normal = -1;
            }

            face.Corners.Add(new ObjCorner(position, texCoord, normal));
        }

        return face;
    }

    // Resolves a 1-based (or negative, end-relative) OBJ index into a 0-based array index.
    // Returns -1 when the slot is absent or unparseable.
    private static int ResolveIndex(string[] parts, int slot, int count)
    {
        if (slot >= parts.Length || string.IsNullOrEmpty(parts[slot]))
        {
            return -1;
        }

        if (!int.TryParse(parts[slot], NumberStyles.Integer, CultureInfo.InvariantCulture, out var index))
        {
            return -1;
        }

        return index > 0 ? index - 1 : count + index;
    }

    private static void ParseMtl(string mtlPath, IDictionary<string, MtlMaterial> materials)
    {
        MtlMaterial? current = null;

        foreach (var rawLine in File.ReadLines(mtlPath))
        {
            var tokens = SplitTokens(rawLine);
            if (tokens.Length == 0 || tokens[0].StartsWith('#'))
            {
                continue;
            }

            switch (tokens[0])
            {
                case "newmtl":
                    current = new MtlMaterial();
                    if (tokens.Length > 1)
                    {
                        materials[tokens[1]] = current;
                    }
                    break;

                case "Kd" when current is not null:
                    current.Diffuse = new Vector3(
                        ParseFloat(tokens, 1),
                        ParseFloat(tokens, 2),
                        ParseFloat(tokens, 3));
                    break;

                case "d" when current is not null:
                    current.Alpha = ParseFloat(tokens, 1, 1f);
                    break;

                case "Tr" when current is not null:
                    // "Tr" is transparency, the inverse of dissolve ("d").
                    current.Alpha = 1f - ParseFloat(tokens, 1, 0f);
                    break;

                case "map_Kd" when current is not null:
                    // The texture path is the last token (skips any leading "-o"/"-s" map options).
                    current.DiffuseTexture = tokens[^1];
                    break;
            }
        }
    }

    private static string[] SplitTokens(string line)
    {
        return line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
    }

    private static float ParseFloat(string[] tokens, int index, float fallback = 0f)
    {
        if (index < tokens.Length
            && float.TryParse(tokens[index], NumberStyles.Float, CultureInfo.InvariantCulture, out var value))
        {
            return value;
        }

        return fallback;
    }
}

public sealed class ObjFace
{
    public string? Material { get; set; }
    public List<ObjCorner> Corners { get; } = [];
}

public readonly record struct ObjCorner(int Position, int TexCoord, int Normal)
{
    public bool HasTexCoord => TexCoord >= 0;
    public bool HasNormal => Normal >= 0;
}

public sealed class MtlMaterial
{
    public Vector3 Diffuse { get; set; } = new(0.8f, 0.8f, 0.8f);
    public float Alpha { get; set; } = 1f;
    public string? DiffuseTexture { get; set; }
}
