//
//  PreviewModeDefaults.swift
//  DataExchangeViewer
//

import Foundation

/// Persistence for the preview mode, and the one-shot migration off the old mode names.
///
/// Renaming Peek/Place/Enter to Portal/Volume/Immersive changed the *raw values* that were already
/// on disk. Without a migration an existing install reads `"peek"`, fails to decode it, and falls
/// back to the default — silently, and for every key that embedded a mode name. So the rename is
/// paired with a versioned migration rather than left to the fallback.
enum PreviewModeDefaults {
    /// The mode the person last chose, restored on launch.
    static let selectedModeKey = "selectedPreviewMode"
    /// Whether the "pinch and drag to move" hint has been shown to completion. Renamed along with
    /// the mode (`hasSeenPlacedModelManipulationHint`), so its value migrates too.
    static let manipulationHintKey = "hasSeenVolumeManipulationHint"
    /// Bumped when a future rename needs another pass. Stored as an Int rather than a Bool so the
    /// next migration can tell "never migrated" from "migrated to version 1".
    static let migrationVersionKey = "previewModeNamingMigrationVersion"

    static let currentMigrationVersion = 1

    /// Old raw value to new, for the one rename that has happened.
    static let renamedModes = ["peek": PreviewMode.portal, "place": .volume, "enter": .immersive]

    private static let legacyManipulationHintKey = "hasSeenPlacedModelManipulationHint"

    /// Rewrites any pre-rename values in place. Idempotent, and cheap enough to call on every
    /// launch: after the first pass the version check is a single integer read.
    ///
    /// Returns whether it changed anything, which is what the tests assert on.
    @discardableResult
    static func migrate(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.integer(forKey: migrationVersionKey) < currentMigrationVersion else {
            return false
        }

        var didChange = false

        if let stored = defaults.string(forKey: selectedModeKey) {
            if let renamed = renamedModes[stored] {
                defaults.set(renamed.rawValue, forKey: selectedModeKey)
                didChange = true
            } else if PreviewMode(rawValue: stored) == nil {
                // Neither a current nor a known-old name — a value from a build that never
                // shipped, or hand-edited defaults. Drop it so the default mode applies, rather
                // than leaving something undecodable behind for the next migration to puzzle over.
                defaults.removeObject(forKey: selectedModeKey)
                didChange = true
            }
        }

        if defaults.object(forKey: legacyManipulationHintKey) != nil {
            if defaults.object(forKey: manipulationHintKey) == nil {
                defaults.set(defaults.bool(forKey: legacyManipulationHintKey), forKey: manipulationHintKey)
            }
            defaults.removeObject(forKey: legacyManipulationHintKey)
            didChange = true
        }

        defaults.set(currentMigrationVersion, forKey: migrationVersionKey)
        return didChange
    }

    /// The stored mode, or Portal when there is nothing usable on disk. Immersive is deliberately
    /// *not* restored: relaunching straight into a full immersive space with no model loaded yet
    /// would replace someone's surroundings before they asked for anything.
    static func restoredMode(from defaults: UserDefaults = .standard) -> PreviewMode {
        guard let raw = defaults.string(forKey: selectedModeKey),
              let mode = PreviewMode(rawValue: raw),
              mode != .immersive else {
            return .portal
        }
        return mode
    }

    static func store(_ mode: PreviewMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: selectedModeKey)
    }
}
