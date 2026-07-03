using System.Globalization;
using System.Numerics;

namespace DataExchangeViewingService.Services;

// Streaming reader for a Wavefront OBJ file, shared by the glTF and USDZ post-processors. Mesh
// groups ("g") are discovered on the fly as ReadGroups() is enumerated; referenced .mtl files
// ("mtllib") are fully parsed into memory the first time they're encountered.
//
// Groups are assumed to be self-contained: a group's faces may only reference
// vertices/normals/texture coordinates declared within that same group's own block (between its
// "g" line and the next). This lets a group's vertex pool be dropped as soon as it's been yielded,
// so peak memory is bounded by the largest single group rather than by the whole file. A face that
// references a vertex from a different group means the assumption doesn't hold for this file, and
// ReadGroups throws an ObjParseException rather than silently producing wrong geometry.
//
// Material properties (diffuse color, alpha, texture) are parsed up front: the first time a .mtl
// file is referenced via "mtllib", every "newmtl" block in it is parsed in one pass and kept in
// memory for the lifetime of the reader, so GetMaterial is just a dictionary lookup.
//
// Vertex positions and normals can optionally be rotated on the fly from the Z-up convention used
// by the Data Exchange geometry extraction to the Y-up convention OBJ/glTF/USD viewers assume, so
// callers never need to rewrite the source file to reorient it.
//
// Texture coordinates are exposed exactly as written in the OBJ (bottom-left origin); consumers
// that need a different convention (e.g. glTF's top-left origin) flip the V coordinate themselves.
public sealed class ObjReader : IDisposable
{
    private const string DefaultGroupName = "default";

    private readonly StreamReader _reader;
    private readonly string _baseFolder;
    private readonly bool _convertZUpToYUp;

    private readonly List<Vector3> _positions = [];
    private readonly List<Vector3> _normals = [];
    private readonly List<Vector2> _texCoords = [];
    private int _positionBase;
    private int _normalBase;
    private int _texCoordBase;

    private readonly HashSet<string> _indexedMtlFiles = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, MtlMaterial> _resolvedMaterials = new(StringComparer.OrdinalIgnoreCase);

    public ObjReader(string objPath, bool convertZUpToYUp = false)
    {
        _reader = new StreamReader(objPath);
        _baseFolder = Path.GetDirectoryName(Path.GetFullPath(objPath)) ?? ".";
        _convertZUpToYUp = convertZUpToYUp;
    }

    // Positions/Normals/TexCoords for the group most recently yielded by ReadGroups (or currently
    // being parsed); do not retain references to these lists past the iteration that produced them.
    public IReadOnlyList<Vector3> Positions => _positions;
    public IReadOnlyList<Vector3> Normals => _normals;
    public IReadOnlyList<Vector2> TexCoords => _texCoords;

    // Yields one ObjGroup per "g" boundary in the file (in file order), including a leading
    // default group for any faces that appear before the first "g" line. Groups without faces are
    // skipped. Throws ObjParseException if a face references geometry outside the current group.
    public IEnumerable<ObjGroup> ReadGroups()
    {
        var current = new ObjGroup { Name = DefaultGroupName };
        string? currentMaterial = null;
        string? rawLine;

        while ((rawLine = _reader.ReadLine()) is not null)
        {
            var tokens = SplitTokens(rawLine);
            if (tokens.Length == 0 || tokens[0].StartsWith('#'))
            {
                continue;
            }

            switch (tokens[0])
            {
                case "v":
                    _positions.Add(ParseVertex(tokens));
                    break;

                case "vn":
                    _normals.Add(ParseVertex(tokens));
                    break;

                case "vt":
                    _texCoords.Add(new Vector2(ParseFloat(tokens, 1), ParseFloat(tokens, 2)));
                    break;

                case "g":
                    if (current.Faces.Count > 0)
                    {
                        yield return current;
                    }

                    // Discard the finished group's vertex pool; only its absolute counts (so far)
                    // are kept, to translate the next group's absolute indices into its own
                    // group-local arrays.
                    _positionBase += _positions.Count;
                    _normalBase += _normals.Count;
                    _texCoordBase += _texCoords.Count;
                    _positions.Clear();
                    _normals.Clear();
                    _texCoords.Clear();

                    current = new ObjGroup { Name = tokens.Length > 1 ? string.Join(' ', tokens[1..]) : DefaultGroupName };
                    break;

                case "usemtl":
                    currentMaterial = tokens.Length > 1 ? tokens[1] : null;
                    break;

                case "mtllib":
                    for (var i = 1; i < tokens.Length; i++)
                    {
                        IndexMaterialFile(Path.Combine(_baseFolder, tokens[i]));
                    }
                    break;

                case "f":
                    current.Faces.Add(ParseFace(tokens, currentMaterial, current.Name));
                    break;
            }
        }

        if (current.Faces.Count > 0)
        {
            yield return current;
        }
    }

    // Looks up the named material's already-parsed properties. Returns null if the name is empty
    // or wasn't declared by any indexed .mtl file.
    public MtlMaterial? GetMaterial(string? name)
    {
        if (string.IsNullOrEmpty(name))
        {
            return null;
        }

        return _resolvedMaterials.TryGetValue(name, out var material) ? material : null;
    }

    // Normalized flat normal for the triangle (a, b, c), falling back to +Y when it's degenerate.
    // Shared by the glTF and USDZ converters, which both need this to fill in missing normals.
    public static Vector3 ComputeNormal(Vector3 a, Vector3 b, Vector3 c)
    {
        var normal = Vector3.Cross(b - a, c - a);
        return normal.LengthSquared() > 1e-12f ? Vector3.Normalize(normal) : Vector3.UnitY;
    }

    // Parses every "newmtl" block in a .mtl file in one pass and caches the results in
    // _resolvedMaterials. A no-op if the file was already indexed.
    private void IndexMaterialFile(string mtlPath)
    {
        if (!File.Exists(mtlPath) || !_indexedMtlFiles.Add(mtlPath))
        {
            return;
        }

        MtlMaterial? material = null;
        string? name = null;

        foreach (var rawLine in File.ReadLines(mtlPath))
        {
            var tokens = SplitTokens(rawLine);
            if (tokens.Length == 0 || tokens[0].StartsWith('#'))
            {
                continue;
            }

            if (tokens[0] == "newmtl")
            {
                if (name is not null)
                {
                    _resolvedMaterials[name] = material!;
                }
                name = tokens.Length > 1 ? tokens[1] : null;
                material = new MtlMaterial();
                continue;
            }

            if (material is null)
            {
                continue;
            }

            switch (tokens[0])
            {
                case "Kd":
                    material.Diffuse = new Vector3(ParseFloat(tokens, 1), ParseFloat(tokens, 2), ParseFloat(tokens, 3));
                    break;

                case "d":
                    material.Alpha = ParseFloat(tokens, 1, 1f);
                    break;

                case "Tr":
                    // "Tr" is transparency, the inverse of dissolve ("d").
                    material.Alpha = 1f - ParseFloat(tokens, 1, 0f);
                    break;

                case "map_Kd":
                    // The texture path is the last token (skips any leading "-o"/"-s" map options).
                    material.DiffuseTexture = tokens[^1];
                    break;
            }
        }

        if (name is not null)
        {
            _resolvedMaterials[name] = material!;
        }
    }

    // Parses a "v"/"vn" line into a vector, applying the optional Z-up-to-Y-up rotation
    // (x, y, z) -> (x, z, -y) on the fly.
    private Vector3 ParseVertex(string[] tokens)
    {
        var x = ParseFloat(tokens, 1);
        var y = ParseFloat(tokens, 2);
        var z = ParseFloat(tokens, 3);
        return _convertZUpToYUp ? new Vector3(x, z, -y) : new Vector3(x, y, z);
    }

    // positionBase/texCoordBase/normalBase (fields) are the absolute OBJ index counts at the start
    // of the current group's vertex pool, letting a corner's absolute (1-based) index be
    // translated into a 0-based index into that group's own (group-local) vertex lists.
    private ObjFace ParseFace(string[] tokens, string? material, string groupName)
    {
        var face = new ObjFace { Material = material };

        for (var i = 1; i < tokens.Length; i++)
        {
            var parts = tokens[i].Split('/');

            var position = ResolveIndex(parts, 0, _positionBase, _positions.Count);
            if (position is null)
            {
                // No position for this corner: a malformed corner, not a self-containment issue.
                continue;
            }
            if (position.Value < 0 || position.Value >= _positions.Count)
            {
                throw SelfContainmentViolation(groupName, tokens[i]);
            }

            var texCoord = ResolveIndex(parts, 1, _texCoordBase, _texCoords.Count);
            if (texCoord is not null && (texCoord.Value < 0 || texCoord.Value >= _texCoords.Count))
            {
                throw SelfContainmentViolation(groupName, tokens[i]);
            }

            var normal = ResolveIndex(parts, 2, _normalBase, _normals.Count);
            if (normal is not null && (normal.Value < 0 || normal.Value >= _normals.Count))
            {
                throw SelfContainmentViolation(groupName, tokens[i]);
            }

            face.Corners.Add(new ObjCorner(position.Value, texCoord ?? -1, normal ?? -1));
        }

        return face;
    }

    private static ObjParseException SelfContainmentViolation(string groupName, string corner) =>
        new($"Group \"{groupName}\" is not self-contained: face corner \"{corner}\" references a vertex, " +
            "texture coordinate, or normal outside this group.");

    // Resolves a 1-based absolute (or negative, end-relative) OBJ index into a 0-based index into
    // the current group's local vertex list. Returns null when the slot is absent/unparseable
    // (a normal, optional omission); a non-null result outside [0, count) means the reference
    // falls outside the current group.
    private static int? ResolveIndex(string[] parts, int slot, int baseOffset, int count)
    {
        if (slot >= parts.Length || string.IsNullOrEmpty(parts[slot]))
        {
            return null;
        }

        if (!int.TryParse(parts[slot], NumberStyles.Integer, CultureInfo.InvariantCulture, out var index))
        {
            return null;
        }

        return index > 0 ? index - 1 - baseOffset : count + index;
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

    public void Dispose() => _reader.Dispose();
}

// A single OBJ group ("g <name>") and the faces declared within it.
public sealed class ObjGroup
{
    public required string Name { get; init; }
    public List<ObjFace> Faces { get; } = [];
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

// Thrown when an OBJ file violates ObjReader's self-contained-groups assumption, or otherwise
// can't be parsed as expected.
public sealed class ObjParseException(string message) : Exception(message);
