import SwiftUI
import AppKit

/// Recursively renders a PaneNode tree as split terminal views.
struct PaneSplitView: View {
    private let explicitNode: PaneNode?
    @ObservedObject var paneManager: PaneManager
    @ObservedObject var tabManager: TabManager
    var theme: TerminalTheme

    /// Root init — reads paneManager.rootPane directly so ForEach cache doesn't stale it.
    init(paneManager: PaneManager, tabManager: TabManager, theme: TerminalTheme) {
        self.explicitNode = nil
        self.paneManager = paneManager
        self.tabManager = tabManager
        self.theme = theme
    }

    /// Recursive init — uses a specific subtree node.
    init(node: PaneNode, paneManager: PaneManager, tabManager: TabManager, theme: TerminalTheme) {
        self.explicitNode = node
        self.paneManager = paneManager
        self.tabManager = tabManager
        self.theme = theme
    }

    private var node: PaneNode {
        explicitNode ?? paneManager.rootPane
    }

    var body: some View {
        switch node {
        case .leaf(let id, let backend):
            ZStack {
                TerminalContentView(backend: backend, theme: theme)

                // Focus indicator when multiple panes exist
                if paneManager.focusedPaneID == id && paneManager.rootPane.leafCount > 1 {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
                        .padding(1)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded {
                paneManager.focusedPaneID = id
                tabManager.focusTerminalInActiveTab()
            })
            .contextMenu {
                Button("Split Right") {
                    paneManager.splitPane(id: id, axis: .horizontal)
                }
                Button("Split Down") {
                    paneManager.splitPane(id: id, axis: .vertical)
                }

                Divider()

                if paneManager.rootPane.leafCount > 1 {
                    Button("Close Pane") {
                        paneManager.closePane(id: id)
                    }

                    Divider()
                }

                Button("New Tab Here") {
                    let dir = paneManager.focusedInstance?.currentDirectory
                    tabManager.addTab(in: dir)
                }
            }

        case .split(_, let axis, let first, let second, let ratio):
            GeometryReader { geo in
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        PaneSplitView(node: first, paneManager: paneManager, tabManager: tabManager, theme: theme)
                            .frame(width: (geo.size.width - 1) * ratio)

                        Rectangle()
                            .fill(Color.gray.opacity(0.4))
                            .frame(width: 1)

                        PaneSplitView(node: second, paneManager: paneManager, tabManager: tabManager, theme: theme)
                    }
                } else {
                    VStack(spacing: 0) {
                        PaneSplitView(node: first, paneManager: paneManager, tabManager: tabManager, theme: theme)
                            .frame(height: (geo.size.height - 1) * ratio)

                        Rectangle()
                            .fill(Color.gray.opacity(0.4))
                            .frame(height: 1)

                        PaneSplitView(node: second, paneManager: paneManager, tabManager: tabManager, theme: theme)
                    }
                }
            }
        }
    }
}
