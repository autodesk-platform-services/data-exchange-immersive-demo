# Product and Engineering Ideas

This backlog captures recommendations from the [visionOS 27 developer research](docs/visionOS-27-developer-research.md). Priorities reflect expected value for an Autodesk Data Exchange viewer, not implementation order mandated by Apple.

visionOS 27 and Xcode 27 are currently beta. Validate API names, availability, performance, and entitlement requirements against the final SDK before committing to production scope.

## P0 — Platform and reliability foundation

### Establish a validated visionOS 27 baseline

- [x] Install Xcode 27 and the visionOS 27 SDK/runtime.
- [x] Reconcile the project-level visionOS 26.5 and target-level visionOS 27.0 deployment settings. Both are now 27.0.
- [x] Decide whether the app should require visionOS 27 or retain visionOS 26 compatibility through availability gates. It requires visionOS 27: this is a demo of what the current platform can do, and availability-gating every spatial API for one release of back-compatibility would cost more than it buys.
- [ ] Migrate toward Swift 6 strict-concurrency validation.
- [x] Add a unit-test target covering the pure logic — placement math, PKCE, cache keys, URN encoding, conversion state, and error presentation. See the app README's Tests section.
- [ ] Add CI builds and a simulator/device validation matrix.

**Value:** Foundational  
**Effort:** Medium

### Harden the USDZ delivery pipeline

- [x] Stream artifacts directly to disk instead of materializing the entire USDZ as `Data`.
- [x] Expose download progress, conversion elapsed time, cancellation, retry, and actionable errors.
- [ ] Report true conversion progress, which needs the service to publish a completion percentage.
- [x] Key cached artifacts by exchange version as well as exchange identity.
- [x] Replace discarded RealityKit loading errors and the HDRI `fatalError` with observable failure states.
- [x] Complete API pagination and define a safe strategy for deeply nested folders. Folder nesting is now walked breadth-first with no depth bound; a folder's `exchanges` field takes no pagination argument in the published schema, so that one gap is reported in the UI instead.
- [ ] Create small, medium, and pathological BIM benchmark assets.
- [ ] Record load time, peak memory, frame time, and thermal behavior on device.

**Value:** Very high  
**Effort:** Medium

## P1 — Professional model review

### Build a USDKit model index

- [ ] Traverse USD prims away from the render-critical path.
- [ ] Capture hierarchy, stable identifiers, names, types, bounds, variants, attributes, and accessibility metadata.
- [ ] Determine which APS identifiers and properties survive the server-side conversion.
- [ ] Map selected RealityKit entities back to the USD/APS index.
- [ ] Add validation for malformed or semantically incomplete packages.

**Value:** Very high  
**Effort:** Medium–large  
**Enables:** Selection, properties, filtering, annotations, collaboration, and AI-grounded queries.

### Add structured inspection tools

- [ ] Select and highlight individual model components.
- [ ] Add a searchable hierarchy and property panel.
- [ ] Add isolate, hide, show-all, and selection-set commands.
- [ ] Add animated explode and collapse controls.
- [ ] Add one or more cross-section planes using `ClippingComponent`.
- [ ] Save and restore viewpoints and review state.
- [ ] Move manipulation/input behavior to meaningful child entities instead of manipulating only the whole model.

**Value:** Very high  
**Effort:** Medium–large  
**Note:** `ClippingComponent` is a visionOS 26 capability used prominently by Apple’s new visionOS 27 structured-model workflow.

### Scale to large exchanges

- [ ] Generate multiple LOD representations during conversion.
- [ ] Attach RealityKit level-of-detail behavior using camera-distance, screen-area, or resolution metrics.
- [ ] Evaluate RealityKit occlusion culling for complex assemblies.
- [ ] Test new USD mesh compression and AVIF texture packaging against RealityKit, Quick Look, and external consumers.
- [ ] Adapt quality to device thermal state.
- [ ] Establish frame-time, memory, load-time, and visual-quality acceptance budgets.

**Value:** Very high  
**Effort:** Large  
**Dependency:** Conversion-service support is likely required.

### Add mixed-immersion review

- [ ] Replace the fixed full-immersion configuration with explicit mixed, progressive, and full choices where appropriate.
- [ ] Add reliable spatial placement and anchoring.
- [ ] Harden scene lifecycle, cancellation, and restoration before adding more scene types.
- [ ] Evaluate physical-space lighting for mixed-context review.
- [ ] Compare soft shadows and baked lightmaps with the existing HDRI studio mode.

**Value:** High  
**Effort:** Medium

### Use projective textures as engineering overlays

- [ ] Project issue locations, grids, measurement regions, or review-status heatmaps onto the model.
- [ ] Define how overlays are anchored to components and persisted.
- [ ] Provide a legible fallback for devices or modes where projective textures are unavailable.

**Value:** High  
**Effort:** Small–medium  
**Dependency:** Stable model selection and annotation identity.

## P2 — System integration and collaboration

### Add an accessory conversion-status widget

- [ ] Create a WidgetKit extension for active conversion, recent exchanges, and failure/retry state.
- [ ] Share only the minimum required metadata through an App Group or equivalent safe store.
- [ ] Keep OAuth credentials and private model metadata out of widget-visible storage.
- [ ] Define timeline refresh and notification behavior.

**Value:** Medium–high  
**Effort:** Medium

### Add bounded Foundation Models assistance

- [ ] Summarize conversion logs and suggest deterministic recovery actions.
- [ ] Translate natural-language model filters into a constrained local query representation.
- [ ] Optionally extract exchange or component identifiers from images using built-in vision tools.
- [ ] Ground answers in the USD/APS index and label generated output.
- [ ] Provide a complete non-AI fallback for unavailable devices, languages, regions, or services.
- [ ] Add evaluation cases and regression tests for prompts and structured output.

**Value:** Medium–high  
**Effort:** Medium  
**Constraint:** Generated output must never be treated as authoritative BIM data.

### Expose safe App Intents

- [ ] Make recent exchanges and conversion status discoverable to Siri and Apple Intelligence.
- [ ] Add intents to open an exchange or resume its last review state.
- [ ] Avoid exposing private exchange metadata on a locked or shared device.

**Value:** Medium  
**Effort:** Small–medium  
**Dependency:** Stable exchange identifiers and scene routing.

### Prototype SharePlay design review

- [ ] Synchronize selected component, viewpoint, explode amount, clipping plane, and annotations.
- [ ] Transfer identifiers and review state rather than duplicating raw model geometry.
- [ ] Define conflict handling, late joining, restoration, and model-version mismatch behavior.

**Value:** High  
**Effort:** Large  
**Dependency:** Stable local selection and review-state models. SharePlay itself predates visionOS 27.

### Adopt Reality Composer Pro 3 selectively

- [ ] Author a polished studio or review environment.
- [ ] Create improved portal materials and reusable annotation affordances.
- [ ] Bake lightmaps for static authored surroundings.
- [ ] Evaluate Script Graph or custom plug-ins only where they reduce maintenance.
- [ ] Keep downloaded APS models dynamic rather than manually embedding them in an authored scene.

**Value:** Medium  
**Effort:** Medium

## P3 — Strategic experiments

Each experiment should have a time box and a measurable go/no-go criterion.

### Gaussian-splat reality context

- [ ] Render a captured room or site around the precise BIM model.
- [ ] Select or build a splat ingestion/conversion pipeline; RealityKit does not load arbitrary splat formats automatically.
- [ ] Measure overdraw, splat count, memory, and GPU compatibility.
- [ ] Design lighting and grounding around the fact that scene lights do not illuminate splats.

**Value:** Medium  
**Effort:** Large

### macOS Spatial Preview companion

- [ ] Prototype sending an APS exchange from a Mac directly to Quick Look on Vision Pro.
- [ ] Include viewpoints, variants, annotations, manipulation, and progress reporting.
- [ ] Evaluate automatic optimization versus unmodified USD delivery.
- [ ] Explore the built-in SharePlay workflow.

**Value:** High strategic  
**Effort:** Extra large  
**Constraint:** Spatial Preview is a macOS 27 framework, not an API embedded directly in this visionOS-only target.

### Foveated streaming for extreme scenes

- [ ] Define the model-size or fidelity threshold at which local LOD/compressed USDZ is insufficient.
- [ ] Benchmark a workstation or cloud renderer using an OpenXR/CloudXR-compatible pipeline.
- [ ] Combine streamed rendering with native SwiftUI/RealityKit controls and review state.
- [ ] Measure latency, network degradation, visual quality, cost, and recovery behavior.

**Value:** High strategic  
**Effort:** Extra large  
**Note:** Foveated Streaming was introduced in visionOS 26.4; it is not a visionOS 27-only feature.

### Object-anchored digital twins

- [ ] Identify a concrete workflow involving a physical asset, scale model, or construction mock-up.
- [ ] Train and test high-frame-rate reference-object tracking.
- [ ] Choose deliberately between rendered and uncorrected metric coordinate spaces.
- [ ] Add ARKit World Sensing capability, permissions, calibration, and physical-device tests.

**Value:** Conditional  
**Effort:** Extra large

### Custom tracked spatial accessory

- [ ] Define a workflow that genuinely benefits from a tracked tool or controller.
- [ ] Evaluate reference hardware availability, infrared constellation design, IMU/BLE integration, inputs, and haptics.
- [ ] Build the Create ML training and calibration pipeline.
- [ ] Test tracking loss, occlusion, low light, reconnects, and atomic accessory-set updates.

**Value:** Conditional  
**Effort:** Extra large  
**Constraint:** Requires dedicated hardware and physical-device testing.

## Defer unless product scope changes

- Real-time cloth simulation.
- Character skin, eye, and hair rendering.
- Behavior trees, navigation meshes, and autonomous agents.
- Custom acoustic reverb meshes and coordinated audio, unless acoustic review or training becomes a goal.
- Apple Immersive Video production and playback features.
- Immersive web environments, unless a web sibling is planned.
- Visual Fidelity monitoring, unless the app enters a licensed, safety-sensitive enterprise workflow.
- Migration to Unity, Unreal, Godot, or another engine; the existing native SwiftUI/RealityKit architecture remains appropriate.

## Recommended sequence

1. Validate Xcode/SDK 27 and harden delivery, caching, errors, and tests. *(Done, apart from CI and the Swift 6 strict-concurrency migration.)*
2. Implement the USDKit index and structured inspection MVP.
3. Add LOD/compression/occlusion and establish on-device performance budgets.
4. Add mixed immersion, lighting, and projective overlays.
5. Add the widget, bounded AI assistance, and App Intents.
6. Add SharePlay and a selective Reality Composer Pro environment.
7. Fund Gaussian splats, Spatial Preview, foveated streaming, and tracked-hardware work as separate product bets.
