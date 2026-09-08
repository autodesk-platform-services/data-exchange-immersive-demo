//
//  PreviewModeTests.swift
//  DataExchangeViewerTests
//

import Testing
import Foundation
import RealityKit
import simd
@testable import DataExchangeViewer

/// The rename's migration, which is the part of Portal/Volume/Immersive that can silently do
/// nothing: without it an existing install reads `"peek"`, fails to decode it, falls back to the
/// default, and nobody notices because the default is what a new install shows anyway.
@Suite("Preview mode")
struct PreviewModeTests {
    /// A defaults domain per test, so these never see or disturb the real app's preferences.
    private func makeDefaults() -> UserDefaults {
        let suite = "PreviewModeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func rawValuesAreTheNewNames() {
        #expect(PreviewMode.portal.rawValue == "portal")
        #expect(PreviewMode.volume.rawValue == "volume")
        #expect(PreviewMode.immersive.rawValue == "immersive")
    }

    @Test func onlyPortalWorksWithoutAConvertedModel() {
        #expect(!PreviewMode.portal.requiresModel)
        #expect(PreviewMode.volume.requiresModel)
        #expect(PreviewMode.immersive.requiresModel)
    }

    @Test(arguments: [("peek", PreviewMode.portal), ("place", .volume), ("enter", .immersive)])
    func migratesEachOldModeName(old: String, expected: PreviewMode) {
        let defaults = makeDefaults()
        defaults.set(old, forKey: PreviewModeDefaults.selectedModeKey)

        #expect(PreviewModeDefaults.migrate(in: defaults))
        #expect(defaults.string(forKey: PreviewModeDefaults.selectedModeKey) == expected.rawValue)
    }

    @Test func leavesACurrentNameAlone() {
        let defaults = makeDefaults()
        defaults.set(PreviewMode.volume.rawValue, forKey: PreviewModeDefaults.selectedModeKey)

        PreviewModeDefaults.migrate(in: defaults)
        #expect(defaults.string(forKey: PreviewModeDefaults.selectedModeKey) == "volume")
    }

    /// One-shot: the second pass must not touch anything, or a mode chosen after the migration
    /// could be rewritten by it on the next launch.
    @Test func runsOnlyOnce() {
        let defaults = makeDefaults()
        defaults.set("peek", forKey: PreviewModeDefaults.selectedModeKey)

        #expect(PreviewModeDefaults.migrate(in: defaults))
        #expect(!PreviewModeDefaults.migrate(in: defaults))

        // A later hand-edit of the old value stays put, because the migration is done.
        defaults.set("peek", forKey: PreviewModeDefaults.selectedModeKey)
        #expect(!PreviewModeDefaults.migrate(in: defaults))
        #expect(defaults.string(forKey: PreviewModeDefaults.selectedModeKey) == "peek")
    }

    @Test func migratesTheManipulationHint() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hasSeenPlacedModelManipulationHint")

        #expect(PreviewModeDefaults.migrate(in: defaults))
        #expect(defaults.bool(forKey: PreviewModeDefaults.manipulationHintKey))
        #expect(defaults.object(forKey: "hasSeenPlacedModelManipulationHint") == nil)
    }

    /// An unrecognised value is dropped rather than left for the next migration to puzzle over.
    @Test func discardsAnUnrecognisedStoredMode() {
        let defaults = makeDefaults()
        defaults.set("hologram", forKey: PreviewModeDefaults.selectedModeKey)

        #expect(PreviewModeDefaults.migrate(in: defaults))
        #expect(defaults.string(forKey: PreviewModeDefaults.selectedModeKey) == nil)
    }

    @Test func marksAFreshInstallAsMigrated() {
        let defaults = makeDefaults()
        // Nothing to change, but the version still advances so the next launch skips the work.
        #expect(!PreviewModeDefaults.migrate(in: defaults))
        #expect(
            defaults.integer(forKey: PreviewModeDefaults.migrationVersionKey)
                == PreviewModeDefaults.currentMigrationVersion
        )
    }

    // MARK: - Restoration

    @Test func restoresAStoredMode() {
        let defaults = makeDefaults()
        PreviewModeDefaults.store(.volume, in: defaults)
        #expect(PreviewModeDefaults.restoredMode(from: defaults) == .volume)
    }

    @Test func defaultsToPortalWithNothingStored() {
        #expect(PreviewModeDefaults.restoredMode(from: makeDefaults()) == .portal)
    }

    /// Relaunching straight into a full immersive space — with no model loaded yet — would replace
    /// someone's surroundings before they asked for anything.
    @Test func neverRestoresImmersive() {
        let defaults = makeDefaults()
        PreviewModeDefaults.store(.immersive, in: defaults)
        #expect(PreviewModeDefaults.restoredMode(from: defaults) == .portal)
    }
}

/// Which children the tools treat as parts, and when an export has nothing worth separating.
@MainActor
@Suite("Model hierarchy")
struct ModelHierarchyTests {
    private func entity(_ name: String, children: [Entity] = []) -> Entity {
        let entity = Entity()
        entity.name = name
        for child in children {
            entity.addChild(child)
        }
        return entity
    }

    /// `Entity(contentsOf:)` wraps the stage in a synthetic root, and exports typically nest one
    /// more named group inside that — so "direct children of root" is a one-element list and the
    /// interesting children are two or three levels down.
    @Test func descendsThroughSingleChildWrappers() {
        let storeys = (1...3).map { entity("Level_0\($0)") }
        let assembly = entity("Building", children: storeys)
        let loaded = entity("root", children: [entity("Stage", children: [assembly])])

        #expect(ModelStore.assemblyRoot(of: loaded) === assembly)
    }

    @Test func stopsAtGeometryEvenWhenItIsAnOnlyChild() {
        let mesh = ModelEntity(mesh: .generateBox(size: 1))
        mesh.name = "Slab"
        let loaded = entity("root", children: [mesh])
        #expect(ModelStore.assemblyRoot(of: loaded) === mesh)
    }

    @Test func namedSubassembliesAreNotFlattened() {
        let assembly = entity("Building", children: [
            entity("Level_01"), entity("Level_02"), entity("Roof")
        ])
        #expect(!ModelStore.isFlattened(assembly))
    }

    /// The flattened export this warns about: everything parented to the root as `Part_001…Part_n`.
    /// It renders correctly and leaves both tools with nothing meaningful to operate on.
    @Test func generatedChildNamesCountAsFlattened() {
        let assembly = entity("root", children: (1...40).map { entity("Part_\($0)") })
        #expect(ModelStore.isFlattened(assembly))
    }

    @Test func aSingleChildCountsAsFlattened() {
        #expect(ModelStore.isFlattened(entity("root", children: [entity("Building")])))
    }

    /// A handful of generated names among real ones is normal in a CAD export and shouldn't
    /// disqualify the model.
    @Test func aMinorityOfGeneratedNamesIsStillAnAssembly() {
        var children = (1...8).map { entity("Level_0\($0)") }
        children.append(entity("Mesh_1"))
        children.append(entity("Mesh_2"))
        #expect(!ModelStore.isFlattened(entity("root", children: children)))
    }

    @Test(arguments: ["Part_001", "Mesh12", "node-3", "object 7", "", "Geom_0"])
    func recognisesGeneratedNames(name: String) {
        #expect(ModelStore.isGeneratedName(name))
    }

    @Test(arguments: ["Level_01", "Roof", "Curtain Wall", "Part of the porch", "Mesh"])
    func leavesAuthoredNamesAlone(name: String) {
        #expect(!ModelStore.isGeneratedName(name))
    }

    /// The authoring convention: an empty Xform named `entryPoint` beats a centroid for any
    /// building with a front door, and costs the exporter one prim.
    @Test func prefersAnAuthoredEntryPoint() {
        let entry = entity("entryPoint")
        entry.position = SIMD3<Float>(3, 0, -7)
        let content = entity("Building", children: [entity("Level_01", children: [entry])])
        let root = entity("modelRoot", children: [content])

        let resolved = ModelStore.resolveEntryPoint(
            in: content,
            relativeTo: root,
            bounds: BoundingBox(min: SIMD3<Float>(-50, 0, -50), max: SIMD3<Float>(50, 30, 50))
        )
        #expect(resolved ≈ SIMD3<Float>(3, 0, -7))
    }

    @Test func fallsBackToTheGroundFloorCentroid() {
        let content = entity("Building", children: [entity("Level_01")])
        let root = entity("modelRoot", children: [content])
        let bounds = BoundingBox(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(40, 24, 20))

        let resolved = ModelStore.resolveEntryPoint(in: content, relativeTo: root, bounds: bounds)
        #expect(resolved ≈ SIMD3<Float>(20, 0, 10))
    }
}

/// Detection of authored level-of-detail groups. The conversion service emits none today, so this
/// covers the plumbing rather than any current artifact.
@MainActor
@Suite("Level of detail")
struct LevelOfDetailTests {
    @Test(arguments: [("LOD0", 0), ("lod1", 1), ("LOD_2", 2), ("lod-10", 10)])
    func parsesLevelNames(name: String, expected: Int) {
        #expect(LevelOfDetail.levelIndex(of: name) == expected)
    }

    @Test(arguments: ["Level_01", "LOD", "lodge", "LODx", "Roof"])
    func rejectsNamesThatArentLevels(name: String) {
        #expect(LevelOfDetail.levelIndex(of: name) == nil)
    }

    @Test func findsGroupsAndOrdersThemMostDetailedFirst() {
        let parent = Entity()
        parent.name = "Facade"
        for index in [2, 0, 1] {
            let level = Entity()
            level.name = "LOD\(index)"
            parent.addChild(level)
        }
        let root = Entity()
        root.addChild(parent)

        let groups = LevelOfDetail.groups(in: root)
        #expect(groups.count == 1)
        #expect(groups.first?.levels.count == 3)
        #expect(groups.first?.levels.first?.first?.name == "LOD0")
        #expect(groups.first?.levels.last?.first?.name == "LOD2")
    }

    /// Today's artifacts, and the reason `apply` is a no-op on them.
    @Test func findsNothingInAnExportWithoutLevels() {
        let root = Entity()
        let building = Entity()
        building.name = "Building"
        for index in 1...3 {
            let storey = Entity()
            storey.name = "Level_0\(index)"
            building.addChild(storey)
        }
        root.addChild(building)

        #expect(LevelOfDetail.groups(in: root).isEmpty)
    }

    /// A lone `LOD0` is not a set of levels to switch between.
    @Test func ignoresASingleLevel() {
        let parent = Entity()
        let level = Entity()
        level.name = "LOD0"
        parent.addChild(level)
        #expect(LevelOfDetail.groups(in: parent).isEmpty)
    }
}
