import RealityKit

/// Temporarily removes model colliders while leaving the sibling tool overlay interactive.
/// Restore the exact components, including any collision filters authored in the source file.
@MainActor
final class ModelCollisionOverride {
    private var saved: [(Entity, CollisionComponent)] = []

    func suspend(root: Entity, clipRoot: Entity) {
        restore()
        var entities = [root]
        var queue = [clipRoot]
        while let entity = queue.popLast() {
            entities.append(entity)
            queue.append(contentsOf: entity.children)
        }
        for entity in entities {
            if let collision = entity.components[CollisionComponent.self] {
                saved.append((entity, collision))
                entity.components.remove(CollisionComponent.self)
            }
        }
    }

    func restore() {
        for (entity, collision) in saved { entity.components.set(collision) }
        saved = []
    }
}
