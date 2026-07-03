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
// ObjModel) and rebuild the geometry with SharpGLTF's scene/mesh builders. Both OBJ and glTF use
// a right-handed, Y-up coordinate system, so no axis conversion is required.
public static class GltfConverter
{
    // Converts the given OBJ file into a GLB file. Any MTL libraries referenced by the OBJ
    // (and resolved relative to the OBJ's folder) are used to assign per-primitive materials.
    public static void ConvertObjToGlb(string objPath, string glbPath, ILogger? logger = null)
    {
        var memory = logger is null ? null : new MemoryTelemetry(logger, $"GLB conversion");
        var baseFolder = Path.GetDirectoryName(Path.GetFullPath(objPath)) ?? ".";
        ObjModel obj;
        using (memory?.Step("load OBJ and MTL for GLB"))
        {
            obj = ObjModel.Load(objPath);
        }

        var materialBuilders = new Dictionary<string, MaterialBuilder>(StringComparer.OrdinalIgnoreCase);
        var defaultMaterial = new MaterialBuilder("default")
            .WithDoubleSide(true)
            .WithMetallicRoughnessShader()
            .WithBaseColor(new Vector4(0.8f, 0.8f, 0.8f, 1f))
            .WithMetallicRoughness(0f, 1f);

        var mesh = new MeshBuilder<VertexPositionNormal, VertexTexture1, VertexEmpty>(
            Path.GetFileNameWithoutExtension(objPath));

        using (memory?.Step("build SharpGLTF mesh from OBJ faces"))
        {
            foreach (var face in obj.Faces)
            {
                if (face.Corners.Count < 3)
                {
                    continue;
                }

                var material = ResolveMaterial(face.Material, obj.Materials, materialBuilders, defaultMaterial, baseFolder);
                var primitive = mesh.UsePrimitive(material);

                // Fan-triangulate the (possibly n-gon) face.
                for (var i = 1; i < face.Corners.Count - 1; i++)
                {
                    var a = BuildVertex(obj, face.Corners[0]);
                    var b = BuildVertex(obj, face.Corners[i]);
                    var c = BuildVertex(obj, face.Corners[i + 1]);

                    // Supply a flat face normal whenever the OBJ omitted explicit vertex normals.
                    if (!face.Corners[0].HasNormal || !face.Corners[i].HasNormal || !face.Corners[i + 1].HasNormal)
                    {
                        var faceNormal = ObjModel.ComputeNormal(a.Geometry.Position, b.Geometry.Position, c.Geometry.Position);
                        a = WithNormal(a, faceNormal);
                        b = WithNormal(b, faceNormal);
                        c = WithNormal(c, faceNormal);
                    }

                    primitive.AddTriangle(a, b, c);
                }
            }
        }

        SceneBuilder scene;
        using (memory?.Step("create SharpGLTF scene"))
        {
            scene = new SceneBuilder();
            scene.AddRigidMesh(mesh, Matrix4x4.Identity);
        }

        using (memory?.Step("serialize GLB file"))
        {
            var model = scene.ToGltf2();
            model.SaveGLB(glbPath);
        }
    }

    private static VERTEX BuildVertex(ObjModel obj, ObjCorner corner)
    {
        var position = obj.Positions[corner.Position];
        var normal = corner.HasNormal ? obj.Normals[corner.Normal] : Vector3.UnitY;

        // glTF uses a top-left UV origin while OBJ uses bottom-left, so flip V.
        var texCoord = corner.HasTexCoord
            ? new Vector2(obj.TexCoords[corner.TexCoord].X, 1f - obj.TexCoords[corner.TexCoord].Y)
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
        IReadOnlyDictionary<string, MtlMaterial> materials,
        IDictionary<string, MaterialBuilder> cache,
        MaterialBuilder defaultMaterial,
        string baseFolder)
    {
        if (string.IsNullOrEmpty(materialName) || !materials.TryGetValue(materialName, out var definition))
        {
            return defaultMaterial;
        }

        if (cache.TryGetValue(materialName, out var cached))
        {
            return cached;
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
