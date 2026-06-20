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

    /// Minimum pane size in points.
    private let minPaneSize: CGFloat = 40

    var body: some View {
        switch node {
        case .leaf(let id, let backend):
            if backend is NonTerminalBackend {
                // Preview / CDP panes own their interactions (scroll, click, etc.) — don't
                // attach the terminal tap-gesture / context menu / hit-shape, which would
                // steal right-click and drag from the hosted view. Just a close ✕.
                leafContent(id: id, backend: backend)
                    .overlay(alignment: .topTrailing) {
                        Button {
                            paneManager.closePane(id: id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 15))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color.white, Color.black.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .help("Close preview")
                    }
            } else {
                leafContent(id: id, backend: backend)
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
            }

        case .split(let splitID, let axis, let first, let second, let ratio):
            GeometryReader { geo in
                if axis == .horizontal {
                    let firstWidth = (geo.size.width - 1) * ratio
                    HStack(spacing: 0) {
                        PaneSplitView(node: first, paneManager: paneManager, tabManager: tabManager, theme: theme)
                            .frame(width: firstWidth)

                        SplitDivider(axis: .horizontal)
                            .gesture(DragGesture(coordinateSpace: .named("split-\(splitID)"))
                                .onChanged { value in
                                    let newRatio = value.location.x / geo.size.width
                                    let clamped = min(max(newRatio, minPaneSize / geo.size.width), 1 - minPaneSize / geo.size.width)
                                    paneManager.updateSplitRatio(splitID: splitID, ratio: clamped)
                                }
                                .onEnded { _ in NSCursor.arrow.set() }
                            )
                            .onTapGesture(count: 2) {
                                paneManager.updateSplitRatio(splitID: splitID, ratio: 0.5)
                            }

                        PaneSplitView(node: second, paneManager: paneManager, tabManager: tabManager, theme: theme)
                    }
                } else {
                    let firstHeight = (geo.size.height - 1) * ratio
                    VStack(spacing: 0) {
                        PaneSplitView(node: first, paneManager: paneManager, tabManager: tabManager, theme: theme)
                            .frame(height: firstHeight)

                        SplitDivider(axis: .vertical)
                            .gesture(DragGesture(coordinateSpace: .named("split-\(splitID)"))
                                .onChanged { value in
                                    let newRatio = value.location.y / geo.size.height
                                    let clamped = min(max(newRatio, minPaneSize / geo.size.height), 1 - minPaneSize / geo.size.height)
                                    paneManager.updateSplitRatio(splitID: splitID, ratio: clamped)
                                }
                                .onEnded { _ in NSCursor.arrow.set() }
                            )
                            .onTapGesture(count: 2) {
                                paneManager.updateSplitRatio(splitID: splitID, ratio: 0.5)
                            }

                        PaneSplitView(node: second, paneManager: paneManager, tabManager: tabManager, theme: theme)
                    }
                }
            }
            .coordinateSpace(name: "split-\(splitID)")
        }
    }

    /// The terminal/preview view plus the focus indicator, shared by both leaf branches.
    @ViewBuilder
    private func leafContent(id: String, backend: TerminalBackend) -> some View {
        ZStack {
            TerminalContentView(backend: backend, theme: theme)

            // Focus indicator when multiple panes exist
            if paneManager.focusedPaneID == id && paneManager.rootPane.leafCount > 1 {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
                    .padding(1)
            }
        }
    }
}

/// Draggable divider between split panes.
/// Visible line is 1pt, but hit target is 7pt wide for easy grabbing.
private struct SplitDivider: View {
    let axis: Axis

    var body: some View {
        ZStack {
            // Invisible hit target
            Rectangle()
                .fill(Color.clear)
                .frame(
                    width: axis == .horizontal ? 7 : nil,
                    height: axis == .vertical ? 7 : nil
                )
                .contentShape(Rectangle())

            // Visible divider line
            Rectangle()
                .fill(Color.gray.opacity(0.4))
                .frame(
                    width: axis == .horizontal ? 1 : nil,
                    height: axis == .vertical ? 1 : nil
                )
        }
        .frame(
            width: axis == .horizontal ? 7 : nil,
            height: axis == .vertical ? 7 : nil
        )
        // AppKit cursor rects manage the resize cursor reliably — including during
        // a drag, and they reset it when the pointer leaves — unlike onHover
        // push/pop, which gets unbalanced mid-drag and leaves the cursor stuck.
        .background(ResizeCursorView(axis: axis))
    }
}

/// Hosts an AppKit cursor rect so the resize cursor shows over the divider and
/// reliably resets when the pointer leaves or a drag ends.
private struct ResizeCursorView: NSViewRepresentable {
    let axis: Axis

    func makeNSView(context: Context) -> CursorRectView {
        let view = CursorRectView()
        view.cursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
        return view
    }

    func updateNSView(_ nsView: CursorRectView, context: Context) {
        nsView.cursor = axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    final class CursorRectView: NSView {
        var cursor: NSCursor = .arrow
        private var trackingArea: NSTrackingArea?

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea { removeTrackingArea(existing) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.cursorUpdate, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        // .cursorUpdate fires on pointer movement (unlike cursor rects, which only
        // re-evaluate on click) — so the resize cursor is set on enter and AppKit
        // restores the default when the pointer leaves, even right after a drag.
        override func cursorUpdate(with event: NSEvent) {
            cursor.set()
        }
    }
}
