import AppKit
import PDFKit
import AVKit
import WebKit
import UniformTypeIdentifiers
import Ink
import Highlightr

/// A non-terminal pane leaf that previews a local file with a NATIVE per-type viewer.
///
/// Conforms to `TerminalBackend` so the pane tree / split / close / resize machinery
/// works unchanged — a preview pane is a "degenerate backend" that renders a file and
/// no-ops every terminal method.
///
/// Supported, interactive (scroll / select / copy):
///   - PDF        → PDFKit `PDFView`
///   - Markdown   → bundled marked.js + github-markdown-dark.css + highlight.js +
///                  mermaid.js in a `WKWebView` (GFM tables + diagrams); Ink fallback
///   - Code/text  → Highlightr (highlight.js via JavaScriptCore) → read-only `NSTextView`
///   - Image      → `NSImageView`
///   - Video/audio→ `AVPlayerView`
///   - Anything else → a "preview not supported" placeholder.
final class PreviewBackend: TerminalBackend, NonTerminalBackend {
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

    private static func kind(for url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if let ut = UTType(filenameExtension: ext) {
            if ut.conforms(to: .pdf) { return .pdf }
            if ut.conforms(to: .image) { return .image }
            if ut.conforms(to: .movie) || ut.conforms(to: .audiovisualContent) || ut.conforms(to: .audio) { return .media }
            if ut.conforms(to: .sourceCode) || ut.conforms(to: .text) || ut.conforms(to: .shellScript) { return .code }
        }
        if codeLanguage(for: ext) != nil { return .code }
        return .unsupported
    }

    /// Whether `preview_file` can render this path. The API/MCP layer gates on this and
    /// returns an error (opening NO pane) for unsupported types — nothing is shown.
    static func isSupported(path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        return kind(for: URL(fileURLWithPath: expanded)) != .unsupported
    }

    func load(path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
        fileURL = url
        player?.pause()
        player = nil

        switch Self.kind(for: url) {
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
        // Fit within the pane, never upscale (a 2048² image must not blow up the split).
        v.imageScaling = .scaleProportionallyDown
        v.imageAlignment = .alignCenter
        // The image's intrinsic size must NOT drive the pane layout: the container is
        // returned straight to SwiftUI, which measures its fitting size. Lower hugging /
        // compression resistance so the edge constraints (not the 2048² intrinsic) win.
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
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
        let cfg = WKWebViewConfiguration()
        let ucc = cfg.userContentController
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")  // transparent → our dark container shows through pre-paint
        if #available(macOS 12.0, *) {
            web.underPageBackgroundColor = Self.canvasColor  // avoids white flash before first paint
        }

        let html: String
        if let rendered = Self.markdownHTML(markdown: md) {
            // Primary path: bundled marked + highlight.js + mermaid → GFM tables & diagrams.
            html = rendered
        } else {
            // Fallback (bundled assets missing): Ink, no tables/diagrams.
            let body = MarkdownParser().html(from: md)
            html = "<!doctype html><html><head><meta charset='utf-8'><style>\(Self.markdownCSS)</style></head><body class='markdown-body'>\(body)</body></html>"
        }

        // Block all internet access in the preview, THEN load (defense-in-depth with the
        // DOMPurify sanitize: even surviving markup can't fetch/track/exfiltrate remotely).
        let base = url.deletingLastPathComponent()
        Self.compileNetworkBlock { rule in
            if let rule { ucc.add(rule) }
            web.loadHTMLString(html, baseURL: base)
        }
        install(web, focus: web)
    }

    /// Content rule blocking ALL internet protocols inside the preview WebView. Local
    /// `file://` and inlined assets still work; remote scripts/images/trackers, fetch/XHR
    /// and WebSockets are blocked — nothing leaves the machine.
    private static let networkBlockRules = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp)://"},"action":{"type":"block"}}]"#

    private static func compileNetworkBlock(_ completion: @escaping (WKContentRuleList?) -> Void) {
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "macuake-preview-no-internet",
            encodedContentRuleList: networkBlockRules
        ) { list, _ in
            // Completion is delivered on the main queue — safe to touch the WebView.
            completion(list)
        }
    }

    private func installCode(_ url: URL) {
        let scroll = makeTextScroll()
        let text = scroll.documentView as! NSTextView
        let code = Self.readText(url)
        let lang = Self.codeLanguage(for: url.pathExtension.lowercased())  // nil → auto-detect
        if let hl = Self.highlighter, let attr = hl.highlight(code, as: lang, fastRender: true) {
            text.textStorage?.setAttributedString(attr)
            text.backgroundColor = hl.theme.themeBackgroundColor
        } else {
            // Fallback: plain monospaced text.
            text.string = code
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

    /// Shared syntax highlighter — highlight.js running in-process via JavaScriptCore
    /// (Highlightr). No external binary, no spawned process. `github-dark` matches the
    /// markdown code blocks; Menlo 12 matches the terminal.
    private static let highlighter: Highlightr? = {
        guard let h = Highlightr() else { return nil }
        h.setTheme(to: "github-dark")
        h.theme.setCodeFont(NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular))
        return h
    }()

    /// Map a file extension to a highlight.js language name. Returns nil for extensions we
    /// don't pin (Highlightr then auto-detects). Also used by `kind(for:)` to classify code.
    private static func codeLanguage(for ext: String) -> String? {
        let map: [String: String] = [
            "swift": "swift", "py": "python", "js": "javascript", "mjs": "javascript",
            "ts": "typescript", "jsx": "javascript", "tsx": "typescript", "go": "go",
            "rs": "rust", "rb": "ruby", "c": "c", "h": "c", "cpp": "cpp", "cc": "cpp",
            "hpp": "cpp", "m": "objectivec", "mm": "objectivec", "java": "java",
            "kt": "kotlin", "php": "php", "sh": "bash", "bash": "bash", "zsh": "bash",
            "json": "json", "yml": "yaml", "yaml": "yaml", "toml": "ini", "html": "xml",
            "css": "css", "xml": "xml", "sql": "sql", "lua": "lua", "pl": "perl",
            "r": "r", "scala": "scala", "diff": "diff", "patch": "diff", "txt": "plaintext",
            "conf": "ini", "ini": "ini", "make": "makefile", "mk": "makefile",
        ]
        return map[ext]
    }

    // MARK: - Markdown (bundled-JS pipeline)

    /// GitHub dark canvas color (#0d1117) — used as the WebView's pre-paint background.
    private static let canvasColor = NSColor(srgbRed: 0x0d / 255, green: 0x11 / 255, blue: 0x17 / 255, alpha: 1)

    /// Read a bundled markdown asset (js/css) from `Resources/markdown/`. The assets ship
    /// inside the SPM-generated `Macuake_Macuake.bundle`; we locate that bundle relative to
    /// the executable/app and also accept assets copied straight into a Resources dir — so
    /// it resolves under `swift build`, the dev `.app`, and the release `.app`.
    /// (Avoids `Bundle.module`, which for this executable target resolves to a dependency's
    /// inaccessible accessor.)
    private static func markdownAsset(_ name: String) -> String? {
        let fm = FileManager.default
        var bases: [URL] = []
        if let r = Bundle.main.resourceURL { bases.append(r) }
        bases.append(Bundle.main.bundleURL)
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() { bases.append(exeDir) }

        var dirs: [URL] = []
        for base in bases {
            dirs.append(base.appendingPathComponent("markdown"))
            let pkg = base.appendingPathComponent("Macuake_Macuake.bundle")
            dirs.append(pkg.appendingPathComponent("Resources/markdown"))          // shallow bundle
            dirs.append(pkg.appendingPathComponent("Contents/Resources/markdown"))  // deep bundle
        }
        for dir in dirs {
            let file = dir.appendingPathComponent(name)
            if fm.fileExists(atPath: file.path), let s = try? String(contentsOf: file, encoding: .utf8) { return s }
        }
        return nil
    }

    // Cache asset bodies (mermaid.min.js alone is ~3 MB — read once, reuse every render).
    private static let markedJS = markdownAsset("marked.min.js")
    private static let hljsJS = markdownAsset("highlight.min.js")
    private static let mermaidJS = markdownAsset("mermaid.min.js")
    private static let githubMarkdownCSS = markdownAsset("github-markdown-dark.css")
    private static let hljsCSS = markdownAsset("github-dark.min.css")
    private static let purifyJS = markdownAsset("purify.min.js")

    /// Build a self-contained HTML document that renders `markdown` client-side with
    /// marked (GFM tables), highlight.js (code blocks) and mermaid (diagrams).
    /// Returns nil if any bundled asset is missing (caller falls back to Ink).
    private static func markdownHTML(markdown: String) -> String? {
        guard let marked = markedJS, let hljs = hljsJS, let mermaid = mermaidJS,
              let ghCSS = githubMarkdownCSS, let hlCSS = hljsCSS, let purify = purifyJS else { return nil }

        // JSON-encode the markdown so it embeds safely inside a <script> string literal.
        // JSONEncoder escapes `/` as `\/` (so `</script>` can't close the tag); also guard
        // the JS line-separator code points that JSON leaves raw.
        let raw: String
        if let data = try? JSONEncoder().encode(markdown), let s = String(data: data, encoding: .utf8) {
            raw = s.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                   .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        } else {
            raw = "\"\""
        }

        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(ghCSS)</style>
        <style>\(hlCSS)</style>
        <style>
          html,body { background:#0d1117; margin:0; padding:0; }
          .markdown-body { box-sizing:border-box; max-width:980px; margin:0 auto; padding:32px 28px; background:#0d1117; }
          .mermaid { background:transparent; text-align:center; margin:16px 0; }
        </style>
        </head>
        <body>
        <article id="content" class="markdown-body"></article>
        <script>\(marked)</script>
        <script>\(hljs)</script>
        <script>\(purify)</script>
        <script>\(mermaid)</script>
        <script>
          (function(){
            var RAW = \(raw);
            var el = document.getElementById('content');
            // Sanitize the rendered HTML — strips <script>, event handlers (onerror=…) and
            // javascript: URLs from untrusted markdown. Our own scripts above are trusted
            // (from the bundle, not the content). Network is also blocked at the WebView.
            try { el.innerHTML = DOMPurify.sanitize(marked.parse(RAW)); }
            catch(e){ el.textContent = String(RAW); return; }
            // Promote ```mermaid fenced blocks into <div class="mermaid"> nodes.
            el.querySelectorAll('pre code.language-mermaid').forEach(function(code){
              var div = document.createElement('div');
              div.className = 'mermaid';
              div.textContent = code.textContent;
              code.parentElement.replaceWith(div);
            });
            // Syntax-highlight the remaining fenced code blocks.
            el.querySelectorAll('pre code').forEach(function(code){
              try { hljs.highlightElement(code); } catch(e){}
            });
            try {
              mermaid.initialize({ startOnLoad:false, theme:'dark', securityLevel:'strict' });
              mermaid.run({ querySelector:'.mermaid' });
            } catch(e){}
          })();
        </script>
        </body></html>
        """
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
