import Foundation
import SwiftUI
import GhosttyKit
import os.log

final class PaneManager: ObservableObject {
    @Published var rootPane: PaneNode
    @Published var focusedPaneID: UUID

    /// Called when the focused pane's title changes.
    var onFocusedTitleChange: ((String) -> Void)?
    /// Called when the focused pane's directory changes.
    var onFocusedDirectoryChange: ((String) -> Void)?
    /// Called when the last pane is closed.
    var onLastPaneClosed: (() -> Void)?

    init(directory: String? = nil) {
        let instance = TerminalInstance()
        let id = UUID()
        self.rootPane = .leaf(id: id, backend: instance.backend)
        self.focusedPaneID = id
        setupCallbacks(for: id, instance: instance)
        instance.startShell(in: directory)
        // Keep instance alive — stored via backend reference
        instances[id] = instance
    }

    /// Tracks TerminalInstance per pane for lifecycle (title, directory, process exit)
    private var instances: [UUID: TerminalInstance] = [:]

    var focusedInstance: TerminalInstance? {
        instances[focusedPaneID]
    }

    var focusedBackend: TerminalBackend? {
        rootPane.backend(for: focusedPaneID)
    }

    var currentDirectory: String {
        focusedInstance?.currentDirectory ?? ""
    }

    // MARK: - Split (native Ghostty surfaces)

    @discardableResult
    func splitPane(id: UUID, axis: Axis) -> Bool {
        guard let sourceBackend = rootPane.backend(for: id) as? GhosttyBackend,
              let newBackend = sourceBackend.createSplitSurface() else {
            os_log(.error, "Failed to create split surface")
            return false
        }
        let newInstance = TerminalInstance(existingBackend: newBackend)

        let newPaneID = UUID()
        instances[newPaneID] = newInstance
        setupCallbacks(for: newPaneID, instance: newInstance)

        rootPane = splitNode(rootPane, targetID: id, axis: axis, newBackend: newBackend, newPaneID: newPaneID)
        focusedPaneID = newPaneID
        return true
    }

    @discardableResult
    func splitFocusedPane(axis: Axis) -> Bool {
        splitPane(id: focusedPaneID, axis: axis)
    }

    // MARK: - Close

    @discardableResult
    func closePane(id: UUID) -> Bool {
        if case .leaf(let leafID, let backend) = rootPane, leafID == id {
            backend.terminate()
            instances.removeValue(forKey: id)
            onLastPaneClosed?()
            return false
        }

        if let newRoot = removeNode(rootPane, targetID: id) {
            rootPane = newRoot
            instances.removeValue(forKey: id)
            if !rootPane.leafIDs.contains(focusedPaneID) {
                focusedPaneID = rootPane.leafIDs.first!
            }
            return true
        }
        return true
    }

    // MARK: - Navigation

    enum NavigationDirection {
        case next, previous
    }

    func moveFocus(_ direction: NavigationDirection) {
        let leaves = rootPane.leafIDs
        guard leaves.count > 1, let currentIndex = leaves.firstIndex(of: focusedPaneID) else { return }
        switch direction {
        case .next:
            focusedPaneID = leaves[(currentIndex + 1) % leaves.count]
        case .previous:
            focusedPaneID = leaves[(currentIndex - 1 + leaves.count) % leaves.count]
        }
    }

    // MARK: - Callbacks

    private func setupCallbacks(for paneID: UUID, instance: TerminalInstance) {
        instance.onTitleChange = { [weak self] title in
            Task { @MainActor in
                guard let self else { return }
                if self.focusedPaneID == paneID {
                    self.onFocusedTitleChange?(title)
                }
            }
        }

        instance.onDirectoryChange = { [weak self] dir in
            Task { @MainActor in
                guard let self else { return }
                if self.focusedPaneID == paneID {
                    self.onFocusedDirectoryChange?(dir)
                }
            }
        }

        instance.onProcessTerminated = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.closePane(id: paneID)
            }
        }
    }
}
