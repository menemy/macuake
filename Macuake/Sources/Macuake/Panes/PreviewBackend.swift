import AppKit
import PDFKit
import AVKit
import WebKit
import UniformTypeIdentifiers
import Ink

/// A non-terminal pane leaf that previews a local file with a NATIVE per-type viewer.
///
/// Conforms to `TerminalBackend` so the pane tree / split / close / resize machinery
/// works unchanged — a preview pane is a "degenerate backend" that renders a file and
/// no-ops every terminal method.
///
/// Supported, interactive (scroll / select / copy):
///   - PDF        → PDFKit `PDFView`
///   - Markdown   → Ink (md→HTML) + GitHub-style CSS in a `WKWebView`
///   - Code/text  → André Simon `highlight` → RTF → read-only `NSTextView`
///   - Image      → `NSImageView`
///   - Video/audio→ `AVPlayerView`
///   - Anything else → a "preview not supported" placeholder.
final class PreviewBackend: TerminalBackend {
    private let container = NSView()
    private var renderer: NSView?
    private var focusTarget: NSView?
    private var player: AVPlayer?
    private(set) var fileURL: URL

    weak var delegate: TerminalBackendDelegate?

    private static let maxTextBytes = 8 * 1024 * 1024

    init(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        self.fileURL = URL(fileURLWithPath: expanded)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.appearance = NSAppearance(named: .darkAqua)
        load(path: path)
    }

    private enum Kind { case pdf, markdown, code, image, media, unsupported }

    private static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    private func kind(for url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if Self.markdownExtensions.contains(ext) { return .markdown }
        if let ut = UTType(filenameExtension: ext) {
            if ut.conforms(to: .pdf) { return .pdf }
            if ut.conforms(to: .image) { return .image }
            if ut.conforms(to: .movie) || ut.conforms(to: .audiovisualContent) || ut.conforms(to: .audio) { return .media }
            if ut.conforms(to: .sourceCode) || ut.conforms(to: .text) || ut.conforms(to: .shellScript) { return .code }
        }
        if Self.highlightSyntax(for: ext) != nil { return .code }
        return .unsupported
    }

    func load(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        fileURL = url
        player?.pause()
        player = nil

        switch kind(for: url) {
        case .pdf:         installPDF(url)
        case .markdown:    installMarkdown(url)
        case .code:        installCode(url)
        case .image:       installImage(url)
        case .media:       installMedia(url)
        case .unsupported: installUnsupported(url)
        }
    }

    // MARK: - Renderers

    private func installPDF(_ url: URL) {
        let v = PDFView()
        v.document = PDFDocument(url: url)
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.appearance = NSAppearance(named: .darkAqua)
        install(v, focus: v)
    }

    private func installImage(_ url: URL) {
        let v = NSImageView()
        v.image = NSImage(contentsOf: url)
        v.imageScaling = .scaleProportionallyUpOrDown
        v.imageAlignment = .alignCenter
        install(v, focus: v)
    }

    private func installMedia(_ url: URL) {
        let p = AVPlayer(url: url)
        player = p
        let v = AVPlayerView()
        v.player = p
        v.controlsStyle = .inline
        v.videoGravity = .resizeAspect
        install(v, focus: v)
    }

    private func installMarkdown(_ url: URL) {
        let md = Self.readText(url)
        let body = MarkdownParser().html(from: md)
        let html = "<!doctype html><html><head><meta charset='utf-8'><style>\(Self.markdownCSS)</style></head><body class='markdown-body'>\(body)</body></html>"
        let web = WKWebView()
        web.setValue(false, forKey: "drawsBackground")  // transparent → our dark container shows through pre-paint
        web.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        install(web, focus: web)
    }

    private func installCode(_ url: URL) {
        let scroll = makeTextScroll()
        let text = scroll.documentView as! NSTextView
        if let attr = Self.highlightToRTF(url: url) {
            text.textStorage?.setAttributedString(attr)
            // The RTF carries its own colors; ensure the view background stays dark.
            text.backgroundColor = .black
        } else {
            // Fallback: plain monospaced text.
            text.string = Self.readText(url)
            text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            text.textColor = NSColor(white: 0.9, alpha: 1)
        }
        install(scroll, focus: text)
    }

    private func installUnsupported(_ url: URL) {
        let label = NSTextField(labelWithString: "No preview for .\(url.pathExtension) files")
        label.font = .systemFont(ofSize: 13)
        label.textColor = NSColor(white: 0.6, alpha: 1)
        label.alignment = .center
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        install(host, focus: host)
    }

    // MARK: - Helpers

    private func makeTextScroll() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .black
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = true
        text.backgroundColor = .black
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        return scroll
    }

    private static func readText(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return (try? String(contentsOf: url)) ?? "(unable to read file)"
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxTextBytes)) ?? Data()
        let truncated = data.count >= maxTextBytes
        let body = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "(undecodable)"
        return truncated ? body + "\n\n… (truncated)" : body
    }

    /// Locate the André Simon `highlight` binary (bundled first, then common install paths).
    private static var highlightBinary: String? = {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("highlight/highlight").path,
            "/opt/homebrew/bin/highlight",
            "/usr/local/bin/highlight",
            "/usr/bin/highlight",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Map a file extension to a `highlight` syntax name where the extension alone is ambiguous.
    private static func highlightSyntax(for ext: String) -> String? {
        let map: [String: String] = [
            "swift": "swift", "py": "python", "js": "js", "mjs": "js", "ts": "ts",
            "jsx": "js", "tsx": "ts", "go": "go", "rs": "rust", "rb": "ruby",
            "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "hpp": "cpp", "m": "objc",
            "mm": "objc", "java": "java", "kt": "kotlin", "php": "php", "sh": "bash",
            "bash": "bash", "zsh": "bash", "json": "json", "yml": "yaml", "yaml": "yaml",
            "toml": "toml", "html": "html", "css": "css", "xml": "xml", "sql": "sql",
            "lua": "lua", "pl": "perl", "r": "r", "scala": "scala", "diff": "diff",
            "patch": "diff", "txt": "txt", "conf": "conf", "ini": "ini", "make": "make",
        ]
        return map[ext]
    }

    /// Run `highlight -O rtf` and return an attributed string, or nil if unavailable.
    private static func highlightToRTF(url: URL) -> NSAttributedString? {
        guard let bin = highlightBinary else { return nil }
        let ext = url.pathExtension.lowercased()
        var args = ["-O", "rtf", "--style", "anotherdark", "--font", "Menlo", "--font-size", "12"]
        if let syn = highlightSyntax(for: ext) { args += ["-S", syn] }
        args.append(url.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, !data.isEmpty else { return nil }
        return NSAttributedString(rtf: data, documentAttributes: nil)
    }

    private static let markdownCSS = """
    :root { color-scheme: dark; }
    body { font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
           font-size: 15px; line-height: 1.6; max-width: 760px; margin: 0 auto; padding: 24px;
           color: #e6edf3; background: transparent; -webkit-text-size-adjust: 100%; }
    h1,h2 { border-bottom: 1px solid #30363d; padding-bottom: .3em; margin-top: 1.4em; }
    h1{font-size:2em}h2{font-size:1.5em}h3{font-size:1.25em}
    a { color: #4493f8; text-decoration: none; }
    code { font: 0.9em ui-monospace, SFMono-Regular, Menlo, monospace;
           background: rgba(110,118,129,.4); padding: .2em .4em; border-radius: 6px; }
    pre { background: #161b22; padding: 16px; border-radius: 6px; overflow: auto; }
    pre code { background: none; padding: 0; }
    blockquote { color: #9198a1; border-left: .25em solid #30363d; padding: 0 1em; margin: 0; }
    table { border-collapse: collapse; } th,td { border: 1px solid #30363d; padding: 6px 13px; }
    img { max-width: 100%; }
    hr { border: none; border-top: 1px solid #30363d; }
    """

    private func install(_ newView: NSView, focus: NSView) {
        renderer?.removeFromSuperview()
        renderer = newView
        focusTarget = focus
        newView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(newView)
        NSLayoutConstraint.activate([
            newView.topAnchor.constraint(equalTo: container.topAnchor),
            newView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            newView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            newView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - TerminalBackend (no-ops — this is not a terminal)

    var view: NSView { container }
    var focusableView: NSView { focusTarget ?? container }

    func startProcess(executable: String, execName: String, currentDirectory: String?) {}
    func terminate() { player?.pause(); player = nil }
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
