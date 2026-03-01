import Foundation
import SwiftUI

/// A binary tree node representing either a single terminal pane or a split.
indirect enum PaneNode: Identifiable {
    case leaf(id: UUID, backend: TerminalBackend)
    case split(id: UUID, axis: Axis, first: PaneNode, second: PaneNode, ratio: CGFloat)

    var id: UUID {
        switch self {
        case .leaf(let id, _): return id
        case .split(let id, _, _, _, _): return id
        }
    }

    /// All leaf pane IDs in order (left-to-right / top-to-bottom).
    var leafIDs: [UUID] {
        switch self {
        case .leaf(let id, _):
            return [id]
        case .split(_, _, let first, let second, _):
            return first.leafIDs + second.leafIDs
        }
    }

    /// Find the backend for a given pane ID.
    func backend(for paneID: UUID) -> TerminalBackend? {
        switch self {
        case .leaf(let id, let b):
            return id == paneID ? b : nil
        case .split(_, _, let first, let second, _):
            return first.backend(for: paneID) ?? second.backend(for: paneID)
        }
    }

    /// Total number of leaf panes.
    var leafCount: Int {
        switch self {
        case .leaf: return 1
        case .split(_, _, let first, let second, _):
            return first.leafCount + second.leafCount
        }
    }

    /// Terminate all backends in this subtree.
    func terminateAll() {
        switch self {
        case .leaf(_, let backend):
            backend.terminate()
        case .split(_, _, let first, let second, _):
            first.terminateAll()
            second.terminateAll()
        }
    }
}

// MARK: - Tree operations (pure functions returning new trees)

/// Insert a new pane next to the target leaf, splitting it along the given axis.
func splitNode(_ node: PaneNode, targetID: UUID, axis: Axis, newBackend: TerminalBackend, newPaneID: UUID) -> PaneNode {
    switch node {
    case .leaf(let id, _) where id == targetID:
        return .split(
            id: UUID(),
            axis: axis,
            first: node,
            second: .leaf(id: newPaneID, backend: newBackend),
            ratio: 0.5
        )
    case .leaf:
        return node
    case .split(let id, let ax, let first, let second, let ratio):
        let newFirst = splitNode(first, targetID: targetID, axis: axis, newBackend: newBackend, newPaneID: newPaneID)
        if newFirst.id != first.id {
            return .split(id: id, axis: ax, first: newFirst, second: second, ratio: ratio)
        }
        let newSecond = splitNode(second, targetID: targetID, axis: axis, newBackend: newBackend, newPaneID: newPaneID)
        return .split(id: id, axis: ax, first: first, second: newSecond, ratio: ratio)
    }
}

/// Remove a leaf node and collapse its parent split.
func removeNode(_ node: PaneNode, targetID: UUID) -> PaneNode? {
    switch node {
    case .leaf(let id, let backend) where id == targetID:
        backend.terminate()
        return nil
    case .leaf:
        return node
    case .split(let id, let axis, let first, let second, let ratio):
        if first.leafIDs.contains(targetID) {
            if let newFirst = removeNode(first, targetID: targetID) {
                return .split(id: id, axis: axis, first: newFirst, second: second, ratio: ratio)
            }
            return second
        }
        if second.leafIDs.contains(targetID) {
            if let newSecond = removeNode(second, targetID: targetID) {
                return .split(id: id, axis: axis, first: first, second: newSecond, ratio: ratio)
            }
            return first
        }
        return node
    }
}
