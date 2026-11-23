import AppKit
import ImageIO

/// Marker for panes that are NOT terminal sessions (file preview, CDP browser preview).
/// They have no `TerminalInstance`, so they must be excluded from terminal focus
/// traversal and the API session list.
protocol NonTerminalBackend {}

/// A pane that mirrors a Chrome/Chromium tab via the DevTools Protocol screencast
/// (`Page.startScreencast`). It is a *preview* of the agent's browser — frames are
/// decoded and drawn into a layer-backed `NSView`; it is NOT an embedded WebKit browser.
///
/// All networking is Foundation-only (`URLSessionWebSocketTask` + `JSONSerialization`);
/// no third-party dependency and no vendored binary. Input (click/scroll/keys) is
/// forwarded back over CDP so you can take over the tab.
final class CDPScreencastBackend: TerminalBackend, NonTerminalBackend {
    private let screencastView = ScreencastView()
    private let client: CDPScreencastClient
    private(set) var endpoint: String

    weak var delegate: TerminalBackendDelegate?

    /// `endpoint` is a CDP HTTP host:port (e.g. "localhost:9222"). The caller is
    /// responsible for restricting it to loopback.
    init(endpoint: String) {
        self.endpoint = endpoint
        self.client = CDPScreencastClient(endpoint: endpoint)
        screencastView.client = client
        client.onFrame = { [weak self] image in
            self?.screencastView.setFrame(image)
        }
        client.onStatus = { [weak self] status in
            self?.screencastView.setStatus(status)
        }
        client.onViewportNeeded = { [weak screencastView] in
            screencastView?.currentViewport() ?? CGSize(width: 1280, height: 800)
        }
        client.connect()
    }

    // MARK: - TerminalBackend

    var view: NSView { screencastView }
    var focusableView: NSView { screencastView }

    func startProcess(executable: String, execName: String, currentDirectory: String?) {}
    func terminate() { client.disconnect() }
    func applyFont(_ font: NSFont) {}
    func applyColors(foreground: NSColor, background: NSColor, cursor: NSColor, selection: NSColor, ansiColors: [NSColor]) {}
    func showFindBar() {}
    func findNext() {}
    func findPrevious() {}
    func send(text: String) {}

    func readBuffer(lineCount: Int) -> TerminalBufferSnapshot {
        TerminalBufferSnapshot(lines: ["[cdp preview: \(endpoint)]"], rows: 1, cols: 0)
    }

    func createSplitBackend() -> TerminalBackend? { nil }
}

// MARK: - Frame view + input forwarding

/// Layer-backed, flipped (top-left origin, matching CDP) view that draws screencast
/// frames and forwards mouse/keyboard to the CDP client.
private final class ScreencastView: NSView {
    weak var client: CDPScreencastClient?
    private let statusLabel = NSTextField(labelWithString: "Connecting…")
    private var lastViewportSent: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resize
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.textColor = NSColor(white: 0.6, alpha: 1)
        statusLabel.alignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }          // top-left origin like CDP
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setFrame(_ image: CGImage) {
        statusLabel.isHidden = true
        layer?.contents = image
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }

    /// CSS-pixel viewport == our point size (so click coords map 1:1).
    func currentViewport() -> CGSize {
        CGSize(width: max(bounds.width.rounded(), 1), height: max(bounds.height.rounded(), 1))
    }

    override func layout() {
        super.layout()
        let vp = currentViewport()
        if vp != lastViewportSent {
            lastViewportSent = vp
            let scale = window?.backingScaleFactor ?? 2
            client?.setViewport(width: Int(vp.width), height: Int(vp.height), scale: scale)
        }
    }

    // Coordinates: flipped view → top-left origin; viewport == point size → CSS px == point.
    private func cssPoint(_ event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        return (Double(p.x), Double(p.y))
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let (x, y) = cssPoint(e)
        client?.mouse("mousePressed", x: x, y: y, button: "left", clickCount: e.clickCount, buttons: 1)
    }
    override func mouseUp(with e: NSEvent) {
        let (x, y) = cssPoint(e)
        client?.mouse("mouseReleased", x: x, y: y, button: "left", clickCount: e.clickCount, buttons: 0)
    }
    override func mouseDragged(with e: NSEvent) {
        let (x, y) = cssPoint(e); client?.mouse("mouseMoved", x: x, y: y, button: "left", clickCount: 0, buttons: 1)
    }
    override func mouseMoved(with e: NSEvent) {
        let (x, y) = cssPoint(e); client?.mouse("mouseMoved", x: x, y: y, button: "none", clickCount: 0, buttons: 0)
    }
    override func rightMouseDown(with e: NSEvent) {
        let (x, y) = cssPoint(e); client?.mouse("mousePressed", x: x, y: y, button: "right", clickCount: e.clickCount, buttons: 2)
    }
    override func rightMouseUp(with e: NSEvent) {
        let (x, y) = cssPoint(e); client?.mouse("mouseReleased", x: x, y: y, button: "right", clickCount: e.clickCount, buttons: 0)
    }
    override func scrollWheel(with e: NSEvent) {
        let (x, y) = cssPoint(e)
        client?.wheel(x: x, y: y, deltaX: -Double(e.scrollingDeltaX), deltaY: -Double(e.scrollingDeltaY))
    }
    override func keyDown(with e: NSEvent) { client?.key(e, type: "keyDown") }
    override func keyUp(with e: NSEvent) { client?.key(e, type: "keyUp") }

    // Forward in-page editing shortcuts (Cmd+A/C/V/X/Z) to the browser when this pane is
    // focused; let app-level shortcuts (Cmd+T/W/Q, ⌘1…9) fall through to macuake.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods == [.command], let c = event.charactersIgnoringModifiers?.lowercased(),
           ["a", "c", "v", "x", "z"].contains(c) {
            client?.key(event, type: "keyDown")
            client?.key(event, type: "keyUp")
            return true
        }
        return false
    }
}

// MARK: - CDP client (Foundation only)

final class CDPScreencastClient {
    var onFrame: ((CGImage) -> Void)?               // delivered on main
    var onStatus: ((String) -> Void)?               // delivered on main
    var onViewportNeeded: (() -> CGSize)?

    private let endpoint: String
    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var nextId = 0
    private var closed = false
    private var generation = 0          // invalidates stale receive/ping callbacks across reconnects
    private let decodeQueue = DispatchQueue(label: "cdp.decode", qos: .userInitiated)
    // Frame coalescing: keep only the newest frame; drop intermediates so a fast-animating
    // page can't pile up decode work and burn CPU. (Ack still fires for every frame.)
    private let frameLock = NSLock()
    private var latestFrameB64: String?
    private var decodeScheduled = false
    // Follow-active-tab: a browser-level socket tracks page targets; the screencast socket
    // re-points to the newest/active tab so links opening new tabs aren't lost.
    private var browserTask: URLSessionWebSocketTask?
    private var browserGen = 0
    private var pageTargets: [String] = []
    private var activeTargetId: String?

    init(endpoint: String) { self.endpoint = endpoint }

    func connect() {
        guard !closed else { return }
        status("Connecting to \(endpoint)…")
        discoverBrowser { [weak self] wsURL in
            guard let self, !self.closed else { return }
            guard let wsURL else { self.scheduleBrowserReconnect(message: "Waiting for Chrome at \(self.endpoint)…"); return }
            self.openBrowserSocket(wsURL)
        }
    }

    func disconnect() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil); task = nil
        browserTask?.cancel(with: .goingAway, reason: nil); browserTask = nil
    }

    // MARK: - Browser socket: track targets, follow the active/newest tab

    /// Browser-level CDP endpoint (controls all tabs) from /json/version.
    private func discoverBrowser(_ completion: @escaping (URL?) -> Void) {
        guard let verURL = URL(string: "http://\(endpoint)/json/version") else { completion(nil); return }
        session.dataTask(with: verURL) { data, _, _ in
            guard let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ws = obj["webSocketDebuggerUrl"] as? String, let url = URL(string: ws)
            else { completion(nil); return }
            completion(url)
        }.resume()
    }

    private func openBrowserSocket(_ url: URL) {
        browserGen += 1
        let gen = browserGen
        let t = session.webSocketTask(with: url)
        browserTask = t
        t.resume()
        browserReceiveLoop(generation: gen)
        // Chrome emits Target.targetCreated for every existing + future target.
        sendBrowser("Target.setDiscoverTargets", ["discover": true])
        scheduleBrowserPing(generation: gen)
    }

    private func browserReceiveLoop(generation gen: Int) {
        browserTask?.receive { [weak self] result in
            guard let self, !self.closed, gen == self.browserGen else { return }
            switch result {
            case .failure:
                self.scheduleBrowserReconnect(message: "Reconnecting…")
            case .success(let message):
                if case .string(let s) = message { self.handleBrowser(s) }
                self.browserReceiveLoop(generation: gen)
            }
        }
    }

    private func handleBrowser(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = obj["method"] as? String,
              let params = obj["params"] as? [String: Any] else { return }
        switch method {
        case "Target.targetCreated", "Target.targetInfoChanged":
            guard let info = params["targetInfo"] as? [String: Any],
                  (info["type"] as? String) == "page",
                  let tid = info["targetId"] as? String else { return }
            if ((info["url"] as? String) ?? "").hasPrefix("devtools://") { return }
            if !pageTargets.contains(tid) { pageTargets.append(tid) }
            // A newly created page (e.g. a target=_blank click) becomes the active tab.
            if method == "Target.targetCreated" || activeTargetId == nil { setActive(tid) }
        case "Target.targetDestroyed":
            guard let tid = params["targetId"] as? String else { return }
            pageTargets.removeAll { $0 == tid }
            if tid == activeTargetId {
                activeTargetId = nil
                if let next = pageTargets.last { setActive(next) }
                else { task?.cancel(with: .goingAway, reason: nil); task = nil; status("No browser tab") }
            }
        default: break
        }
    }

    /// Point the screencast socket at `targetId` (the active tab).
    private func setActive(_ targetId: String) {
        guard targetId != activeTargetId else { return }
        activeTargetId = targetId
        guard let pageURL = URL(string: "ws://\(endpoint)/devtools/page/\(targetId)") else { return }
        task?.cancel(with: .goingAway, reason: nil)
        openSocket(pageURL)
    }

    private func scheduleBrowserReconnect(message: String) {
        guard !closed else { return }
        status(message)
        browserTask?.cancel(with: .goingAway, reason: nil); browserTask = nil
        task?.cancel(with: .goingAway, reason: nil); task = nil
        browserGen += 1; generation += 1
        pageTargets.removeAll(); activeTargetId = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.connect() }
    }

    private func scheduleBrowserPing(generation gen: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.closed, gen == self.browserGen, let t = self.browserTask else { return }
            t.sendPing { _ in }
            self.scheduleBrowserPing(generation: gen)
        }
    }

    private func sendBrowser(_ method: String, _ params: [String: Any] = [:]) {
        nextId += 1
        let msg: [String: Any] = ["id": nextId, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        browserTask?.send(.string(str)) { _ in }
    }

    /// Page keepalive — idle screencast sockets get dropped without periodic pings.
    private func schedulePing(generation gen: Int) {
        DispatchQueue.global().asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.closed, gen == self.generation, let task = self.task else { return }
            task.sendPing { _ in }
            self.schedulePing(generation: gen)
        }
    }

    // MARK: - Page socket: the actual screencast

    private func openSocket(_ url: URL) {
        generation += 1
        let gen = generation
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop(generation: gen)
        send("Page.enable")
        let vp = onViewportNeeded?() ?? CGSize(width: 1280, height: 800)
        applyViewport(width: Int(vp.width), height: Int(vp.height), scale: 2)
        startScreencast()
        schedulePing(generation: gen)
        status("")
    }

    private func receiveLoop(generation gen: Int) {
        task?.receive { [weak self] result in
            guard let self, !self.closed, gen == self.generation else { return }
            switch result {
            case .failure:
                // Page socket dropped (idle/navigated). Re-attach to the active tab if it
                // still exists; otherwise browser target events will drive the next switch.
                if let tid = self.activeTargetId, self.pageTargets.contains(tid) {
                    self.status("Reconnecting…")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        guard let self, !self.closed, self.activeTargetId == tid,
                              let url = URL(string: "ws://\(self.endpoint)/devtools/page/\(tid)") else { return }
                        self.openSocket(url)
                    }
                }
            case .success(let message):
                if case .string(let s) = message { self.handle(s) }
                self.receiveLoop(generation: gen)
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard obj["method"] as? String == "Page.screencastFrame",
              let params = obj["params"] as? [String: Any],
              let b64 = params["data"] as? String, let sid = params["sessionId"] as? Int else { return }
        // Ack immediately (Chrome won't send the next frame until acked).
        send("Page.screencastFrameAck", ["sessionId": sid])
        // Coalesce: stash the newest frame; decode one at a time, dropping any that piled up.
        frameLock.lock()
        latestFrameB64 = b64
        let needsKick = !decodeScheduled
        if needsKick { decodeScheduled = true }
        frameLock.unlock()
        if needsKick { decodeQueue.async { [weak self] in self?.drainFrames() } }
    }

    private func drainFrames() {
        while true {
            frameLock.lock()
            let b64 = latestFrameB64
            latestFrameB64 = nil
            if b64 == nil { decodeScheduled = false; frameLock.unlock(); return }
            frameLock.unlock()
            guard let b64, let data = Data(base64Encoded: b64),
                  let src = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
            DispatchQueue.main.async { [weak self] in self?.onFrame?(cg) }
        }
    }

    // MARK: commands

    private func send(_ method: String, _ params: [String: Any] = [:]) {
        nextId += 1
        let msg: [String: Any] = ["id": nextId, "method": method, "params": params]
        guard let data = try? JSONSerialization.data(withJSONObject: msg),
              let str = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(str)) { _ in }
    }

    private func startScreencast() {
        // Local browser → no bandwidth concern; high quality. Frame resolution is the
        // viewport × deviceScaleFactor (set via setDeviceMetricsOverride), so retina-sharp.
        // everyNthFrame caps source FPS (~30 on a 60 fps page) to keep CPU sane; coalescing
        // drops any remaining backlog.
        send("Page.startScreencast", ["format": "jpeg", "quality": 92, "everyNthFrame": 2])
    }

    private func applyViewport(width: Int, height: Int, scale: CGFloat) {
        guard width > 0, height > 0 else { return }
        send("Emulation.setDeviceMetricsOverride", [
            "width": width, "height": height, "deviceScaleFactor": Double(scale), "mobile": false,
        ])
    }

    func setViewport(width: Int, height: Int, scale: CGFloat) {
        applyViewport(width: width, height: height, scale: scale)
    }

    func mouse(_ type: String, x: Double, y: Double, button: String, clickCount: Int, buttons: Int) {
        send("Input.dispatchMouseEvent", [
            "type": type, "x": x, "y": y, "button": button, "clickCount": clickCount, "buttons": buttons,
        ])
    }

    func wheel(x: Double, y: Double, deltaX: Double, deltaY: Double) {
        send("Input.dispatchMouseEvent", [
            "type": "mouseWheel", "x": x, "y": y, "deltaX": deltaX, "deltaY": deltaY,
        ])
    }

    func key(_ event: NSEvent, type: String) {
        let mods = Self.cdpModifiers(event.modifierFlags)
        var params: [String: Any] = ["type": type, "modifiers": mods]
        if let (key, code, vk) = Self.specialKeys[event.keyCode] {
            params["key"] = key
            params["code"] = code
            params["windowsVirtualKeyCode"] = vk
        } else {
            let chars = event.charactersIgnoringModifiers ?? event.characters ?? ""
            guard !chars.isEmpty else { return }
            params["key"] = event.characters ?? chars
            // windowsVirtualKeyCode from the unmodified char (A=65, 1=49, …) so shortcuts
            // like Cmd+A register correctly.
            if let u = Character(chars).uppercased().unicodeScalars.first, u.value >= 32, u.value < 127 {
                params["windowsVirtualKeyCode"] = Int(u.value)
            }
            // Send text only for actual typing (no Cmd/Ctrl) — otherwise Cmd+A would type "a".
            let isShortcut = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)
            if !isShortcut, let text = event.characters { params["text"] = text }
            // macOS editing shortcuts (Cmd+A/C/V/X/Z) only fire in Chrome when dispatched
            // with the `commands` field — a bare modifier+key does nothing (verified).
            if type == "keyDown", event.modifierFlags.contains(.command),
               let c = (event.charactersIgnoringModifiers ?? "").lowercased().first.map(String.init),
               let editCommand = Self.editCommands[c] {
                params["commands"] = [editCommand]
            }
        }
        send("Input.dispatchKeyEvent", params)
    }

    private static let editCommands: [String: String] = [
        "a": "selectAll", "c": "copy", "v": "paste", "x": "cut", "z": "undo",
    ]

    /// NSEvent modifier flags → CDP modifier bitmask (Alt=1, Ctrl=2, Meta=4, Shift=8).
    private static func cdpModifiers(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.option) { m |= 1 }
        if f.contains(.control) { m |= 2 }
        if f.contains(.command) { m |= 4 }
        if f.contains(.shift) { m |= 8 }
        return m
    }

    /// keyCode → (key, code, windowsVirtualKeyCode) for non-printable keys.
    private static let specialKeys: [UInt16: (String, String, Int)] = [
        36: ("Enter", "Enter", 13),
        48: ("Tab", "Tab", 9),
        51: ("Backspace", "Backspace", 8),
        53: ("Escape", "Escape", 27),
        117: ("Delete", "Delete", 46),
        123: ("ArrowLeft", "ArrowLeft", 37),
        124: ("ArrowRight", "ArrowRight", 39),
        125: ("ArrowDown", "ArrowDown", 40),
        126: ("ArrowUp", "ArrowUp", 38),
    ]

    private func status(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(text) }
    }
}
