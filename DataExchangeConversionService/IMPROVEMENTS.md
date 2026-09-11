# Conversion service: review findings and recommendations

Notes from a review of the ASP.NET backend (September 2026), prompted by USDZ artifacts that
load slowly in the web and visionOS clients and occasionally crash the native app. The
conclusion: the problem is mostly the *shape* of the generated USDZ (ASCII layer, two prims per
element, a normal per face corner, no instancing), not its raw triangle count. On the server,
the whole-exchange OBJ download and the two extra passes over that OBJ are what drive memory,
not the Data Exchange SDK by itself.

Items are ordered by expected payoff within each section.

## 1. Make the USDZ compact and cheap to load

### 1.1 Ship a crate (binary) layer, always

`UsdzConverter.TryOptimizeToCrate` shells out to `python` + `usd-core`
(`Scripts/usdz_to_crate.py`). Neither exists on Azure App Service for Windows, and the old
`D:\Python27` / `D:\Python34` folders on the workers are too old for `usd-core`, so the failure
is logged at Information level and the ASCII `.usda` ships. USDZ is a *stored* zip, so the text
size is the file size, and the USD text parser is slower and hungrier than the crate reader.

Rough per-triangle cost (assuming ~1 unique point per 2 triangles):

| Layout                                       | Bytes / triangle |
| -------------------------------------------- | ---------------- |
| ASCII, face-varying normals (today)          | ~120             |
| Crate, face-varying normals                  | ~58              |
| Crate, uniform normals (one per face)        | ~34              |
| Crate, no normals (viewer computes them)     | ~22              |

Options, in order of preference:

1. **Bundle a standalone `usdcat.exe`** built from OpenUSD with Python disabled (see §4) and
   run it in place of the Python script: write `.usda` → `usdcat in.usda -o out.usdc` → pack
   the `.usdc` plus textures with the existing `UsdzArchive.Write` (the `.usdc` must be the
   first entry) → delete both temp layers. This removes the Python dependency *and* the
   extract-and-repack step, and fixes the leftover `.usda` (§3.4).
2. **Bundle the Python embeddable package + `usd-core`** under `tools/python` and launch it by
   full path (`AppContext.BaseDirectory/tools/python/python.exe`). Works on App Service because
   the app can start child processes from its own folder, which the SDK's native helper
   services already rely on. Uncomment `import site` in `python3xx._pth`, install `usd-core`
   into `Lib/site-packages`, publish the folder via a `<Content Include="tools\python\**" ...>`
   item, keep it out of git. Adds ~100 MB to the publish output; needs a 64-bit worker.
3. **Try the SDK's `DownloadCompleteExchangeAsUSD`** (present in SDK 8.0). If it already
   emits crate/USDZ, the hand-written layer and the post-processing step disappear.
4. A Linux sidecar (Function/Container App with `usd-core`) also works but adds a
   hundreds-of-MB network hop each way; the main service must stay on Windows because the SDK
   targets `net10.0-windows`.

Whatever the mechanism: **fail loudly or record `crateOptimized: true|false` in
`metadata.json`** so clients can tell which flavour they got. Silent fallback is how the
current setup hid the problem.

### 1.2 Collapse the prim hierarchy

`WriteGroupXform` wraps every OBJ group in an `Xform` and writes one `Mesh` per material bucket
inside it, so every element costs at least two prims. RealityKit creates one Entity per prim, so
a 20k-element exchange becomes 40k+ entities and 40k+ mesh resources, all parsed on the main
actor. Element count, not triangle count, is what hurts.

- Emit **one `Mesh` per element** and make the mesh itself the named prim (`Mesh` is an
  `Xformable`, so no wrapper `Xform` is needed).
- Bind materials with **`GeomSubset` prims** (`familyName = "materialBind"`) instead of
  splitting into separate meshes. RealityKit maps this to a single entity with a multi-material
  model.

### 1.3 Stop emitting a normal per face corner

`WriteMesh` writes three `faceVarying` normals per triangle even when the OBJ had none and the
converter just computed a flat one. For planar BIM faces use `interpolation = "uniform"` (one
normal per face), or omit normals entirely when the source had none and let the viewer compute
them.

### 1.4 Instance repeated geometry

The OBJ path bakes every instance to world space, so every repeated window/door/bolt is a
separate copy. Exchanges share one geometry asset across instances. Using the element API
(§2.1) instead of the OBJ dump lets the converter write each shared asset once under a
`Prototypes` scope and reference it per element with `references` + `instanceable = true` +
the element's `Transformation`. File size shrinks by the model's repetition factor and
RealityKit shares the mesh resource. Verify on device that instancing is honoured.

### 1.5 Ship a merged LOD

The Swift app already looks for `LOD<n>` sibling groups and finds none. Emit a second variant
that merges all triangles per material into a handful of meshes for cheap display, keeping the
per-element set for explode/measure.

### 1.6 Single-sided by default

`uniform bool doubleSided = 1` is written on every mesh and doubles fragment work on the
headset. Reserve it for materials with alpha < 1 or geometry with unreliable winding.

### 1.7 Minor

- `WriteMesh` builds the `uvs` list for every mesh even when it is never emitted.
- Float formatting (`0.######`) is fine; it stops mattering once the layer is crate.

## 2. Reduce memory in the extraction pipeline

### 2.1 Replace the all-or-nothing OBJ download with batched element geometry

`ConversionService.RunObjConversionAsync` calls `DownloadCompleteExchangeAsOBJ`, which
materialises the whole exchange before the service sees any of it. The SDK's element API bounds
peak memory to one batch:

1. `client.GetElementDataModelAsync(identifier, ...)` to load the model.
2. Iterate `model.Elements` in batches of a few hundred.
3. `model.GetElementGeometriesAsync(batch, ct, new GeometryOutputOptions { GeometryFilters =
   GeometryFilters.Mesh, MeshOutputFormat = MeshOutputFormat.Mesh })` — in-memory meshes skip
   the OBJ text round trip entirely (`MeshOutputFormat.OBJ` gives per-element OBJ files).
   `GetElementGeometriesWithInstanceTransformAsync` bakes transforms if you do not want
   instancing; use the plain variant plus `Element.Transformation` if you do (§1.4).
4. Write the batch's meshes straight into the USD layer, dispose the returned
   `FileGeometry`/`StreamGeometry`/`MeshGeometry` objects, drop the batch.

Also useful: `GetElementGeometryCounts` sizes the job without downloading;
`SDKOptions.GeometryConfiguration.ConversionBatchSize` tunes the SDK's own batching.

> API names above come from the 8.0.0-alpha.1 XML docs (the only version in the local NuGet
> cache). The project pins `Autodesk.DataExchange` 7.5.0-beta; verify the names against the
> version actually shipped.

### 2.2 Stop parsing the OBJ twice

GLB and USDZ each stream the OBJ independently. Either generate both from one pass (or from the
per-element pass in §2.1), or make GLB opt-in — only the web app's GLB tab consumes it.

### 2.3 SharpGLTF is the likely peak

`GltfConverter` builds every mesh into a `SceneBuilder` with per-vertex dictionaries before
`ToGltf2()` serialises everything: a full managed-object copy of the model. Confirm with the
`MemoryTelemetry` lines in a large exchange's `log.txt`; if confirmed, write the GLB from the
same per-element pass with plain buffers instead of the toolkit builders.

### 2.4 Small-object churn in `ObjReader`

One `List<ObjCorner>` per face and `string.Split` per line means tens of millions of small
allocations for a large model. Span-based parsing into pooled struct arrays fixes most of it;
it matters less once the OBJ round trip is gone.

### 2.5 Forced GCs

`ForceFullGarbageCollection` (LOH compaction + two blocking gen2 collections between steps)
pauses the whole server. Fine as diagnostics; remove with `MemoryTelemetry` once the
investigation is done. For a small App Service plan the durable knobs are workstation GC and
`System.GC.ConserveMemory` in the project file — and not allocating in the first place.

## 3. Backend robustness

1. **Unbounded concurrency.** Every POST spawns a `Task.Run` conversion; two large exchanges
   double the peak. Run conversions through a single background worker (Channel +
   `BackgroundService`) and report a `queued` status.
2. **Stale `running` after a restart.** The fire-and-forget task dies with the process but
   `metadata.json` stays `running`, so every later POST gets 409 until a DELETE. Sweep stale
   entries at startup, or write a heartbeat timestamp and treat old ones as failed.
3. **A fresh SDK `Client` per HTTP request.** `ResolveExchangeAsync` builds one for every
   status poll and artifact GET, each with a network round trip to Data Exchange; the client is
   not disposable and spins up native helper services. Cache the resolved identity per
   (token hash, URN) for ~1 minute.
4. **Leftover `.usda`.** `ConvertObjToUsdz` writes the layer into the output folder and never
   deletes it: doubles disk per exchange, and because artifact lookup only checks
   `File.Exists`, the layer is downloadable. Fixed by the §1.1 flow.
5. **Race on start.** The status check and `StartObjConversion` are not atomic; two concurrent
   POSTs can both pass.
6. **Zip writer truncates silently.** `UsdzArchive.Write` casts sizes/offsets to 32 bits;
   anything over 4 GB produces a corrupt archive. Throw instead.
7. **Version pin mismatch.** csproj references SDK 7.5.0-beta; local cache only has
   8.0.0-alpha.1. Align before relying on the APIs in §2.1.

## 4. Building a standalone `usdcat.exe` (no Python)

Recent OpenUSD tags (24.x+) ship `usdcat` as a C++ program and no longer need Boost when
Python is disabled. Output is a relocatable folder; only `bin` and `lib` need to ship (~30–50
MB). Keep the relative layout — the DLL finds its plugin registry at `lib/usd/**/plugInfo.json`.

```
usd/
  bin/usdcat.exe
  lib/usd_ms.dll          monolithic USD library
  lib/tbb12.dll           oneTBB runtime
  lib/usd/**/             plugInfo.json + resources, must stay next to the dll
```

### 4.1 Prerequisites (build machine only)

Visual Studio 2022 or 2026 with the **Desktop development with C++** workload, CMake ≥ 3.26
(≥ 4.1 for the "Visual Studio 18 2026" generator), Git, Python 3 (only to run the build script).

### 4.2 Open the x64 toolchain prompt

The "x64 Native Tools Command Prompt for VS 20xx" shortcut is created by the installer once the
C++ workload is present; if it is missing, install the workload (Installer → Modify → Desktop
development with C++). Pick the **x64** variant, not "Developer Command Prompt" (x86 default).

Alternatives:

```powershell
# Developer PowerShell, switched to x64
Enter-VsDevShell -VsInstallPath "C:\Program Files\Microsoft Visual Studio\18\Community" -DevCmdArguments "-arch=x64 -host_arch=x64"
```

```bat
:: Locate the install, then call vcvars64 directly from any prompt
"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
```

Verify with `cl` (x64 banner) and `cmake --version`.

### 4.3 Build

```powershell
git clone --branch v25.05 --depth 1 https://github.com/PixarAnimationStudios/OpenUSD.git
python OpenUSD\build_scripts\build_usd.py --no-python --no-imaging --no-tests --no-examples --no-tutorials --no-docs --build-monolithic --build-variant release C:\usd
```

- `--no-python` drops bindings and usdview; `--no-imaging` drops Hydra/OpenSubdiv/OIIO (most of
  the build time and all awkward deps); `--build-monolithic` yields one `usd_ms.dll`. Only
  oneTBB remains, downloaded and built by the script. Expect 15–30 min locally, ~40 min on a
  GitHub Actions `windows-latest` runner (build once, publish `bin` + `lib` as an artifact; do
  not commit binaries).
- **VS 2026 caveat:** an older OpenUSD tag may not detect VS 2026. Pass
  `--generator "Visual Studio 18 2026"` explicitly, or install the "MSVC v143 – VS 2022 C++
  x64/x86 build tools" component and build with `--build-args` adding `-T v143`.

Test from a clean shell with no Python/USD on PATH:

```powershell
C:\usd\bin\usdcat.exe model.usda -o model.usdc
```

(Output format is inferred from the `-o` extension.)

### 4.4 Wire it in

```csharp
var usdcatPath = Path.Combine(AppContext.BaseDirectory, "tools", "usd", "bin", "usdcat.exe");
var startInfo = new ProcessStartInfo(usdcatPath)
{
    RedirectStandardError = true,
    UseShellExecute = false,
    CreateNoWindow = true,
};
startInfo.ArgumentList.Add(usdaPath);
startInfo.ArgumentList.Add("-o");
startInfo.ArgumentList.Add(usdcPath);
```

```xml
<ItemGroup>
  <Content Include="tools\usd\**" CopyToPublishDirectory="PreserveNewest" LinkBase="tools\usd" />
</ItemGroup>
```

Treat a non-zero exit code as a failed conversion (or record it in metadata).

### 4.5 Runtime notes

- 64-bit worker required (App Service → Configuration → General settings → Platform).
- Links the VC++ 2022 runtime dynamically; App Service workers have it. If start-up fails with a
  missing DLL, add `vcruntime140.dll`, `vcruntime140_1.dll`, `msvcp140.dll` to `bin`.
- `usdcat` loads the whole text layer to write crate, so a several-hundred-MB `.usda` briefly
  costs a few times that in the *child* process — separate from the .NET heap but still
  counted against the plan.
- OpenUSD is under a modified Apache 2.0 license; ship its `LICENSE.txt` in the tools folder.
- Alternative to `usdcat`: a ~30-line C++ program linked against the same build that calls
  `SdfLayer::FindOrOpen(usda)->Export(usdc)`.

## 5. Client-side notes (for context)

Not backend work, but they compound the file-shape problem:

- The USDZ parse in the Swift app (`Entity(contentsOf:)` in `USDzEntityCache`) is inherently
  main-actor; fewer prims shortens the UI stall directly.
- `MeasureTool.prepare()` builds one static-mesh collider per `ModelComponent` across the whole
  model on first activation — the prime hang/crash candidate on a large model.
- The web app fetches the whole artifact into an in-memory Blob for both the `<model-viewer>`
  GLB tab and the Safari `<model>` USDZ tab; both benefit from smaller files.
