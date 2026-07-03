using System.Numerics;
using SharpGLTF.Geometry;
using SharpGLTF.Geometry.VertexTypes;
using SharpGLTF.Materials;
using SharpGLTF.Scenes;

// Vertex layout used throughout the converter: position + normal geometry, a single UV channel,
// and no skinning. Aliased here to keep the (verbose) generic signatures readable.
using VERTEX = SharpGLTF.Geometry.VertexBuilder<
    SharpGLTF.Geometry.VertexTypes.VertexPositionNormal,
    SharpGLTF.Geometry.VertexTypes.VertexTexture1,
    SharpGLTF.Geometry.VertexTypes.VertexEmpty>;

namespace DataExchangeViewingService.Services;

// Post-processes the OBJ (and optional MTL) artifacts produced by the Data Exchange
// geometry extraction into a single, self-contained binary glTF (*.glb) file.
//
// SharpGLTF does not read Wavefront OBJ directly, so we parse the OBJ/MTL ourselves (see
// ObjReader) and rebuild the geometry with SharpGLTF's scene/mesh builders. Both OBJ and glTF use
// a right-handed, Y-up coordinate system, so no axis conversion is required once the OBJ has been
// reoriented (see convertZUpToYUp).
public static class GltfConverter
{
    // Converts the given OBJ file into a GLB file. Any MTL libraries referenced by the OBJ
    // (and resolved relative to the OBJ's folder) are used to assign per-primitive materials.
    // Each OBJ group ("g") becomes its own named node/mesh in the resulting glTF, split further
    // into per-material primitives. When convertZUpToYUp is set, vertex positions/normals are
    // rotated from Z-up to Y-up on the fly as they're read.
    public static void ConvertObjToGlb(string objPath, string glbPath, bool convertZUpToYUp = true, ILogger? logger = null, string? logPath = null)
    {
        var memory = logger is null ? null : new MemoryTelemetry(logger, $"GLB conversion", logPath);
        var baseFolder = Path.GetDirectoryName(Path.GetFullPath(objPath)) ?? ".";

        var materialBuilders = new Dictionary<string, MaterialBuilder>(StringComparer.OrdinalIgnoreCase);
        var defaultMaterial = new MaterialBuilder("default")
            .WithDoubleSide(true)
            .WithMetallicRoughnessShader()
            .WithBaseColor(new Vector4(0.8f, 0.8f, 0.8f, 1f))
            .WithMetallicRoughness(0f, 1f);

        var scene = new SceneBuilder();

        using (memory?.Step("stream OBJ groups into SharpGLTF meshes"))
        using (var reader = new ObjReader(objPath, convertZUpToYUp))
        {
            foreach (var group in reader.ReadGroups())
            {
                var mesh = new MeshBuilder<VertexPositionNormal, VertexTexture1, VertexEmpty>(group.Name);

                foreach (var face in group.Faces)
                {
                    if (face.Corners.Count < 3)
                    {
                        continue;
                    }

                    var material = ResolveMaterial(face.Material, reader, materialBuilders, defaultMaterial, baseFolder);
                    var primitive = mesh.UsePrimitive(material);

                    // Fan-triangulate the (possibly n-gon) face.
                    for (var i = 1; i < face.Corners.Count - 1; i++)
                    {
                        var a = BuildVertex(reader, face.Corners[0]);
                        var b = BuildVertex(reader, face.Corners[i]);
                        var c = BuildVertex(reader, face.Corners[i + 1]);

                        // Supply a flat face normal whenever the OBJ omitted explicit vertex normals.
                        if (!face.Corners[0].HasNormal || !face.Corners[i].HasNormal || !face.Corners[i + 1].HasNormal)
                        {
                            var faceNormal = ObjReader.ComputeNormal(a.Geometry.Position, b.Geometry.Position, c.Geometry.Position);
                            a = WithNormal(a, faceNormal);
                            b = WithNormal(b, faceNormal);
                            c = WithNormal(c, faceNormal);
                        }

                        primitive.AddTriangle(a, b, c);
                    }
                }

                scene.AddRigidMesh(mesh, new NodeBuilder(group.Name));
            }
        }

        using (memory?.Step("serialize GLB file"))
        {
            var model = scene.ToGltf2();
            model.SaveGLB(glbPath);
        }
    }

    private static VERTEX BuildVertex(ObjReader reader, ObjCorner corner)
    {
        var position = reader.Positions[corner.Position];
        var normal = corner.HasNormal ? reader.Normals[corner.Normal] : Vector3.UnitY;

        // glTF uses a top-left UV origin while OBJ uses bottom-left, so flip V.
        var texCoord = corner.HasTexCoord
            ? new Vector2(reader.TexCoords[corner.TexCoord].X, 1f - reader.TexCoords[corner.TexCoord].Y)
            : Vector2.Zero;

        return new VERTEX(new VertexPositionNormal(position, normal), new VertexTexture1(texCoord));
    }

    private static VERTEX WithNormal(VERTEX vertex, Vector3 normal)
    {
        var geometry = vertex.Geometry;
        geometry.Normal = normal;
        return new VERTEX(geometry, vertex.Material);
    }

    private static MaterialBuilder ResolveMaterial(
        string? materialName,
        ObjReader reader,
        IDictionary<string, MaterialBuilder> cache,
        MaterialBuilder defaultMaterial,
        string baseFolder)
    {
        if (string.IsNullOrEmpty(materialName))
        {
            return defaultMaterial;
        }

        if (cache.TryGetValue(materialName, out var cached))
        {
            return cached;
        }

        var definition = reader.GetMaterial(materialName);
        if (definition is null)
        {
            return defaultMaterial;
        }

        var color = new Vector4(definition.Diffuse, definition.Alpha);
        var builder = new MaterialBuilder(materialName)
            .WithDoubleSide(true)
            .WithMetallicRoughnessShader()
            .WithMetallicRoughness(0f, 1f);

        var texturePath = definition.DiffuseTexture is null
            ? null
            : Path.Combine(baseFolder, definition.DiffuseTexture);

        if (texturePath is not null && File.Exists(texturePath))
        {
            builder.WithBaseColor(texturePath, color);
        }
        else
        {
            builder.WithBaseColor(color);
        }

        if (definition.Alpha < 1f)
        {
            builder.WithAlpha(AlphaMode.BLEND);
        }

        cache[materialName] = builder;
        return builder;
    }
}
