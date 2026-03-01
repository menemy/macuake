import Testing
import AppKit
import SwiftUI
@testable import Macuake

/// Tests for PaneNode tree operations: splitNode, removeNode, and node properties.
/// Uses real GhosttyBackend instances (Ghostty initializes in test process).
@MainActor
@Suite(.serialized)
struct PaneNodeTreeTests {

    // MARK: - Helpers

    private func makeBackend() -> GhosttyBackend {
        GhosttyBackend()
    }

    private func makeLeaf() -> (PaneNode, UUID, GhosttyBackend) {
        let id = UUID()
        let backend = makeBackend()
        return (.leaf(id: id, backend: backend), id, backend)
    }

    // MARK: - PaneNode properties

    @Test func leaf_leafCount_isOne() {
        let (node, _, _) = makeLeaf()
        #expect(node.leafCount == 1)
    }

    @Test func leaf_leafIDs_containsSelf() {
        let (node, id, _) = makeLeaf()
        #expect(node.leafIDs == [id])
    }

    @Test func leaf_backend_returnsCorrect() {
        let (node, id, backend) = makeLeaf()
        #expect(node.backend(for: id) === backend)
    }

    @Test func leaf_backend_invalidID_returnsNil() {
        let (node, _, _) = makeLeaf()
        #expect(node.backend(for: UUID()) == nil)
    }

    @Test func split_leafCount_sumOfChildren() {
        let (leaf1, _, _) = makeLeaf()
        let (leaf2, _, _) = makeLeaf()
        let split = PaneNode.split(id: UUID(), axis: .horizontal, first: leaf1, second: leaf2, ratio: 0.5)
        #expect(split.leafCount == 2)
    }

    @Test func split_leafIDs_ordered() {
        let id1 = UUID(), id2 = UUID()
        let b1 = makeBackend(), b2 = makeBackend()
        let split = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: id1, backend: b1),
            second: .leaf(id: id2, backend: b2),
            ratio: 0.5
        )
        #expect(split.leafIDs == [id1, id2])
    }

    @Test func nestedSplit_leafIDs_orderedDepthFirst() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let b1 = makeBackend(), b2 = makeBackend(), b3 = makeBackend()
        let inner = PaneNode.split(
            id: UUID(), axis: .vertical,
            first: .leaf(id: id2, backend: b2),
            second: .leaf(id: id3, backend: b3),
            ratio: 0.5
        )
        let outer = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: id1, backend: b1),
            second: inner,
            ratio: 0.5
        )
        #expect(outer.leafIDs == [id1, id2, id3])
        #expect(outer.leafCount == 3)
    }

    @Test func split_backend_findsInEitherSubtree() {
        let id1 = UUID(), id2 = UUID()
        let b1 = makeBackend(), b2 = makeBackend()
        let split = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: id1, backend: b1),
            second: .leaf(id: id2, backend: b2),
            ratio: 0.5
        )
        #expect(split.backend(for: id1) === b1)
        #expect(split.backend(for: id2) === b2)
        #expect(split.backend(for: UUID()) == nil)
    }

    // MARK: - splitNode

    @Test func splitNode_leafMatchesTarget_returnsSplit() {
        let (leaf, id, _) = makeLeaf()
        let newBackend = makeBackend()
        let newID = UUID()

        let result = splitNode(leaf, targetID: id, axis: .horizontal, newBackend: newBackend, newPaneID: newID)

        #expect(result.leafCount == 2)
        #expect(result.leafIDs == [id, newID])
    }

    @Test func splitNode_leafNotMatching_returnsUnchanged() {
        let (leaf, id, _) = makeLeaf()
        let newBackend = makeBackend()
        let result = splitNode(leaf, targetID: UUID(), axis: .horizontal, newBackend: newBackend, newPaneID: UUID())

        #expect(result.leafCount == 1)
        #expect(result.leafIDs == [id])
    }

    @Test func splitNode_preservesOriginalLeafID() {
        let (leaf, id, backend) = makeLeaf()
        let newBackend = makeBackend()
        let newID = UUID()

        let result = splitNode(leaf, targetID: id, axis: .vertical, newBackend: newBackend, newPaneID: newID)

        // Original leaf should still be findable
        #expect(result.backend(for: id) === backend)
        #expect(result.backend(for: newID) === newBackend)
    }

    @Test func splitNode_createsNewSplitUUID() {
        let (leaf, id, _) = makeLeaf()
        let newBackend = makeBackend()

        let result = splitNode(leaf, targetID: id, axis: .horizontal, newBackend: newBackend, newPaneID: UUID())

        // Split node should have a new UUID, different from the leaf
        #expect(result.id != id)
    }

    @Test func splitNode_ratio_isHalf() {
        let (leaf, id, _) = makeLeaf()
        let newBackend = makeBackend()
        let result = splitNode(leaf, targetID: id, axis: .horizontal, newBackend: newBackend, newPaneID: UUID())

        if case .split(_, _, _, _, let ratio) = result {
            #expect(ratio == 0.5)
        } else {
            #expect(Bool(false), "Expected split node")
        }
    }

    @Test func splitNode_targetInFirstSubtree_onlyFirstModified() {
        let id1 = UUID(), id2 = UUID()
        let b1 = makeBackend(), b2 = makeBackend()
        let tree = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: id1, backend: b1),
            second: .leaf(id: id2, backend: b2),
            ratio: 0.5
        )

        let newBackend = makeBackend()
        let newID = UUID()
        let result = splitNode(tree, targetID: id1, axis: .vertical, newBackend: newBackend, newPaneID: newID)

        #expect(result.leafCount == 3)
        #expect(result.leafIDs == [id1, newID, id2])
    }

    @Test func splitNode_targetInSecondSubtree_onlySecondModified() {
        let id1 = UUID(), id2 = UUID()
        let b1 = makeBackend(), b2 = makeBackend()
        let tree = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: id1, backend: b1),
            second: .leaf(id: id2, backend: b2),
            ratio: 0.5
        )

        let newBackend = makeBackend()
        let newID = UUID()
        let result = splitNode(tree, targetID: id2, axis: .vertical, newBackend: newBackend, newPaneID: newID)

        #expect(result.leafCount == 3)
        #expect(result.leafIDs == [id1, id2, newID])
    }

    @Test func splitNode_deepNesting_correctlyRecurses() {
        // Create a 3-level deep tree and split the deepest leaf
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let b1 = makeBackend(), b2 = makeBackend(), b3 = makeBackend()
        let inner = PaneNode.split(
            id: UUID(), axis: .vertical,
            first: .leaf(id: id2, backend: b2),
            second: .leaf(id: id3, backend: b3),
            ratio: 0.5
        )
        let outer = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: id1, backend: b1),
            second: inner,
            ratio: 0.5
        )

        let newBackend = makeBackend()
        let newID = UUID()
        let result = splitNode(outer, targetID: id3, axis: .horizontal, newBackend: newBackend, newPaneID: newID)

        #expect(result.leafCount == 4)
        #expect(result.leafIDs == [id1, id2, id3, newID])
    }

    // MARK: - removeNode

    @Test func removeNode_onlyLeaf_returnsNil() {
        let (leaf, id, _) = makeLeaf()
        let result = removeNode(leaf, targetID: id)
        #expect(result == nil)
    }

    @Test func removeNode_leafNotMatching_returnsUnchanged() {
        let (leaf, id, _) = makeLeaf()
        let result = removeNode(leaf, targetID: UUID())
        #expect(result != nil)
        #expect(result?.leafIDs == [id])
    }

    @Test func removeNode_firstOfTwo_collapsesToSecond() {
        let id1 = UUID(), id2 = UUID()
        let b1 = makeBackend(), b2 = makeBackend()
        let tree = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: id1, backend: b1),
            second: .leaf(id: id2, backend: b2),
            ratio: 0.5
        )

        let result = removeNode(tree, targetID: id1)
        #expect(result != nil)
        #expect(result?.leafCount == 1)
        #expect(result?.leafIDs == [id2])
    }

    @Test func removeNode_secondOfTwo_collapsesToFirst() {
        let id1 = UUID(), id2 = UUID()
        let b1 = makeBackend(), b2 = makeBackend()
        let tree = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: id1, backend: b1),
            second: .leaf(id: id2, backend: b2),
            ratio: 0.5
        )

        let result = removeNode(tree, targetID: id2)
        #expect(result != nil)
        #expect(result?.leafCount == 1)
        #expect(result?.leafIDs == [id1])
    }

    @Test func removeNode_fromThreeLeaves_rebuildsCorrectly() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let b1 = makeBackend(), b2 = makeBackend(), b3 = makeBackend()
        let inner = PaneNode.split(
            id: UUID(), axis: .vertical,
            first: .leaf(id: id2, backend: b2),
            second: .leaf(id: id3, backend: b3),
            ratio: 0.5
        )
        let tree = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: id1, backend: b1),
            second: inner,
            ratio: 0.5
        )

        // Remove middle leaf
        let result = removeNode(tree, targetID: id2)
        #expect(result != nil)
        #expect(result?.leafCount == 2)
        #expect(result?.leafIDs == [id1, id3])
    }

    @Test func removeNode_deeplyNested_collapseCorrectly() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID(), id4 = UUID()
        let b1 = makeBackend(), b2 = makeBackend(), b3 = makeBackend(), b4 = makeBackend()

        let innerRight = PaneNode.split(
            id: UUID(), axis: .vertical,
            first: .leaf(id: id3, backend: b3),
            second: .leaf(id: id4, backend: b4),
            ratio: 0.5
        )
        let innerLeft = PaneNode.split(
            id: UUID(), axis: .vertical,
            first: .leaf(id: id1, backend: b1),
            second: .leaf(id: id2, backend: b2),
            ratio: 0.5
        )
        let tree = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: innerLeft,
            second: innerRight,
            ratio: 0.5
        )

        // Remove id2 from left inner → left collapses to just id1
        let result = removeNode(tree, targetID: id2)
        #expect(result != nil)
        #expect(result?.leafCount == 3)
        #expect(result?.leafIDs == [id1, id3, id4])
    }

    @Test func removeNode_nonExistentTarget_returnsUnchanged() {
        let id1 = UUID(), id2 = UUID()
        let b1 = makeBackend(), b2 = makeBackend()
        let tree = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: id1, backend: b1),
            second: .leaf(id: id2, backend: b2),
            ratio: 0.5
        )

        let result = removeNode(tree, targetID: UUID())
        #expect(result != nil)
        #expect(result?.leafCount == 2)
        #expect(result?.leafIDs == [id1, id2])
    }

    // MARK: - terminateAll

    @Test func terminateAll_singleLeaf_noCrash() {
        let (leaf, _, _) = makeLeaf()
        leaf.terminateAll()
        // Main assertion: no crash
    }

    @Test func terminateAll_multipleLeaves_noCrash() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let b1 = makeBackend(), b2 = makeBackend(), b3 = makeBackend()
        let inner = PaneNode.split(
            id: UUID(), axis: .vertical,
            first: .leaf(id: id2, backend: b2),
            second: .leaf(id: id3, backend: b3),
            ratio: 0.5
        )
        let tree = PaneNode.split(
            id: UUID(), axis: .horizontal,
            first: .leaf(id: id1, backend: b1),
            second: inner,
            ratio: 0.5
        )
        tree.terminateAll()
        // Main assertion: no crash
    }

    // MARK: - Node identity

    @Test func splitNode_axis_preserved() {
        let (leaf, id, _) = makeLeaf()
        let newBackend = makeBackend()

        let resultH = splitNode(leaf, targetID: id, axis: .horizontal, newBackend: newBackend, newPaneID: UUID())
        if case .split(_, let axis, _, _, _) = resultH {
            #expect(axis == .horizontal)
        }

        let (leaf2, id2, _) = makeLeaf()
        let resultV = splitNode(leaf2, targetID: id2, axis: .vertical, newBackend: makeBackend(), newPaneID: UUID())
        if case .split(_, let axis, _, _, _) = resultV {
            #expect(axis == .vertical)
        }
    }

    @Test func paneNode_id_isAccessible() {
        let leafID = UUID()
        let leaf = PaneNode.leaf(id: leafID, backend: makeBackend())
        #expect(leaf.id == leafID)

        let splitID = UUID()
        let split = PaneNode.split(id: splitID, axis: .horizontal, first: leaf, second: leaf, ratio: 0.5)
        #expect(split.id == splitID)
    }
}
