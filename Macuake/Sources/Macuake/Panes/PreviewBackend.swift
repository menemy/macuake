import AppKit
import Quartz

/// A non-terminal pane leaf that previews a local file via QuickLook.
///
/// It conforms to `TerminalBackend` so the existing pane tree, split/close/resize
/// machinery, and `PaneSplitView` rendering work unchanged — a preview pane is just a
/// "degenerate backend" that renders a `QLPreviewView` and no-ops every terminal method.
/// Rendering happens out-of-process in Apple's sandboxed QuickLook service, which covers
/// PDF, images, video/audio, source code, Office docs, 3D models, archives, and more.
final class PreviewBackend: TerminalBackend {
    private let container = NSView()
    private let previewView: QLPreviewView
    private(set) var fileURL: URL

    weak var delegate: TerminalBackendDelegate?

    init(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        self.fileURL = URL(fileURLWithPath: expanded)
        self.previewView = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        setupView()
        load(path: path)
    }

    private func setupView() {
        previewView.autostarts = true
        previewView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(previewView)
        NSLayoutConstraint.activate([
            previewView.topAnchor.constraint(equalTo: container.topAnchor),
            previewView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            previewView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// Point the preview at a (new) file. Used both at init and to swap the file when an
    /// existing preview pane is reused instead of opening another split.
    func load(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        fileURL = url
        previewView.previewItem = url as NSURL
        previewView.refreshPreviewItem()
    }

    // MARK: - TerminalBackend (no-ops — this is not a terminal)

    var view: NSView { container }

    func startProcess(executable: String, execName: String, currentDirectory: String?) {}
    func terminate() { previewView.close() }
    func applyFont(_ font: NSFont) {}
    func applyColors(foreground: NSColor, background: NSColor, cursor: NSColor, selection: NSColor, ansiColors: [NSColor]) {}
    func showFindBar() {}
    func findNext() {}
    func findPrevious() {}
    func send(text: String) {}

    func readBuffer(lineCount: Int) -> TerminalBufferSnapshot {
        TerminalBufferSnapshot(lines: ["[preview: \(fileURL.lastPathComponent)]"], rows: 1, cols: 0)
    }

    func createSplitBackend() -> TerminalBackend? { nil }
}
