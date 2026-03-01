import Foundation
import AppKit
import SwiftUI
import GhosttyKit

/// Unix domain socket server for external control (sideshell-compatible API).
/// Listens at /tmp/macuake.sock, accepts JSON requests, returns JSON responses.
/// Uses a serial queue to process requests one at a time, preventing race conditions.
final class ControlServer {
    let socketPath: String
    private var serverSocket: Int32 = -1
    private var readSource: DispatchSourceRead?
    private weak var windowController: WindowController?
    /// Serial queue ensures requests are processed one at a time.
    private let requestQueue = DispatchQueue(label: "com.macuake.api")

    /// API access: "ask" = prompt on first request, "enabled", "disabled"
    @MainActor static var accessState: String {
        get { UserDefaults.standard.string(forKey: "apiAccess") ?? "ask" }
        set { UserDefaults.standard.set(newValue, forKey: "apiAccess") }
    }

    init(windowController: WindowController, socketPath: String = "/tmp/macuake.sock", startImmediately: Bool = true) {
        self.socketPath = socketPath
        self.windowController = windowController
        if startImmediately { start() }
    }

    deinit {
        stop()
    }

    // MARK: - Socket lifecycle

    private func start() {
        unlink(socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard socketPath.utf8.count < pathLen else {
            print("ControlServer: socket path too long (\(socketPath.utf8.count) >= \(pathLen))")
            close(serverSocket)
            serverSocket = -1
            return
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                let dest = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                _ = strlcpy(dest, cstr, pathLen)
            }
        }

        let bindOK = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindOK == 0 else {
            close(serverSocket)
            serverSocket = -1
            return
        }

        // Owner-only access (sideshell runs as same user)
        chmod(socketPath, 0o700)

        listen(serverSocket, 5)
        _ = fcntl(serverSocket, F_SETFL, O_NONBLOCK)
        _ = fcntl(serverSocket, F_SETFD, FD_CLOEXEC)

        let source = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: .global())
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
            }
        }
        source.resume()
        readSource = source
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        unlink(socketPath)
    }

    // MARK: - Connection handling

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverSocket, sockPtr, &len)
            }
        }
        guard clientFD >= 0 else { return }

        // Serial queue: requests processed one at a time, no race conditions
        requestQueue.async { [weak self] in
            defer { close(clientFD) }

            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(clientFD, &buffer, buffer.count)
            guard n > 0, let request = String(bytes: buffer[0..<n], encoding: .utf8) else { return }

            let semaphore = DispatchSemaphore(value: 0)
            var response = ""

            DispatchQueue.main.async {
                guard let self else {
                    response = jsonError("server gone")
                    semaphore.signal()
                    return
                }
                self.checkAccessThenHandle(request.trimmingCharacters(in: .whitespacesAndNewlines)) { result in
                    response = result
                    semaphore.signal()
                }
            }

            semaphore.wait()

            if let data = (response + "\n").data(using: .utf8) {
                data.withUnsafeBytes { ptr in
                    _ = write(clientFD, ptr.baseAddress!, data.count)
                }
            }
        }
    }

    // MARK: - Access control

    @MainActor
    private func checkAccessThenHandle(_ raw: String, completion: @escaping (String) -> Void) {
        let state = Self.accessState
        if state == "enabled" {
            completion(handleRequest(raw))
            return
        }
        if state == "disabled" {
            completion(jsonError("API access disabled"))
            return
        }
        // First time — ask user
        let alert = NSAlert()
        alert.messageText = "Allow API Access?"
        alert.informativeText = "An external process is trying to control macuake via the socket API. Allow this?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.alertStyle = .warning

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Self.accessState = "enabled"
            completion(handleRequest(raw))
        } else {
            Self.accessState = "disabled"
            completion(jsonError("API access denied"))
        }
    }

    // MARK: - Request router

    @MainActor
    func handleRequest(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = json["action"] as? String else {
            return jsonError("invalid JSON request")
        }

        guard let wc = windowController else {
            return jsonError("not ready")
        }

        switch action {
        case "list":          return handleList(wc, includePanes: json["include-panes"] as? Bool ?? false)
        case "state":         return handleState(wc)
        case "toggle":        wc.toggle(); return jsonOK()
        case "show":          wc.show(); return jsonOK()
        case "hide":          wc.hide(); return jsonOK()
        case "pin":           wc.isPinned = true; return jsonOK()
        case "unpin":         wc.isPinned = false; return jsonOK()
        case "new-tab":       return handleNewTab(json, wc)
        case "focus":         return handleFocus(json, wc)
        case "close-session": return handleClose(json, wc)
        case "execute":       return handleExecute(json, wc)
        case "read":          return handleRead(json, wc)
        case "paste":         return handlePaste(json, wc)
        case "control-char":  return handleControlChar(json, wc)
        case "clear":         return handleClear(json, wc)
        case "split":         return handleSplit(json, wc)
        case "set-appearance": return handleSetAppearance(json, wc)
        default:              return jsonError("unknown action: \(action)")
        }
    }

    // MARK: - Handlers

    @MainActor
    private func handleList(_ wc: WindowController, includePanes: Bool = false) -> String {
        let tabs = wc.tabManager.tabs.enumerated().map { (i, tab) -> [String: Any] in
            var info: [String: Any] = [
                "session_id": tab.id.uuidString,
                "index": i,
                "title": tab.title,
                "active": i == wc.tabManager.activeTabIndex,
                "cwd": tab.instance?.currentDirectory ?? ""
            ]
            if includePanes, let pm = tab.paneManager {
                info["panes"] = serializePaneTree(pm.rootPane)
                info["focused_pane_id"] = pm.focusedPaneID.uuidString
                info["pane_count"] = pm.rootPane.leafIDs.count
            }
            return info
        }
        return jsonOK(["tabs": tabs, "count": tabs.count])
    }

    @MainActor
    private func handleState(_ wc: WindowController) -> String {
        let data: [String: Any] = [
            "visible": wc.state == .visible,
            "pinned": wc.isPinned,
            "tab_count": wc.tabManager.tabs.count,
            "active_tab_index": wc.tabManager.activeTabIndex,
            "active_session_id": wc.tabManager.activeTab?.id.uuidString ?? "",
            "width_percent": wc.widthPercent,
            "height_percent": wc.heightPercent
        ]
        return jsonOK(data)
    }

    @MainActor
    private func handleNewTab(_ json: [String: Any], _ wc: WindowController) -> String {
        let dir = json["directory"] as? String
        wc.tabManager.addTab(in: dir)
        let tab = wc.tabManager.tabs.last!
        return jsonOK(["session_id": tab.id.uuidString])
    }

    @MainActor
    private func handleFocus(_ json: [String: Any], _ wc: WindowController) -> String {
        // Focus a pane within a tab
        if let paneID = json["pane-id"] as? String, let uuid = UUID(uuidString: paneID) {
            let tab = resolveTab(json, wc) ?? wc.tabManager.activeTab
            guard let tab, let pm = tab.paneManager else {
                return jsonError("no active terminal tab")
            }
            guard pm.rootPane.leafIDs.contains(uuid) else {
                return jsonError("pane not found: \(paneID)")
            }
            pm.focusedPaneID = uuid
            return jsonOK(["session_id": tab.id.uuidString, "pane_id": uuid.uuidString])
        }
        // Focus a tab
        if let sessionID = json["session_id"] as? String {
            guard let idx = wc.tabManager.tabs.firstIndex(where: { $0.id.uuidString == sessionID }) else {
                return jsonError("session not found: \(sessionID)")
            }
            wc.tabManager.selectTab(at: idx)
            return jsonOK()
        }
        if let index = json["index"] as? Int {
            wc.tabManager.selectTab(at: index)
            return jsonOK()
        }
        // Pane navigation by direction
        if let direction = json["direction"] as? String {
            guard let tab = wc.tabManager.activeTab, let pm = tab.paneManager else {
                return jsonError("no active terminal tab")
            }
            pm.moveFocus(direction == "prev" ? .previous : .next)
            return jsonOK(["session_id": tab.id.uuidString, "pane_id": pm.focusedPaneID.uuidString])
        }
        return jsonError("provide session_id, index, pane-id, or direction")
    }

    @MainActor
    private func handleClose(_ json: [String: Any], _ wc: WindowController) -> String {
        // Close a specific pane
        if let paneID = json["pane-id"] as? String, let uuid = UUID(uuidString: paneID) {
            let tab = resolveTab(json, wc) ?? wc.tabManager.activeTab
            guard let tab, let pm = tab.paneManager else {
                return jsonError("no active terminal tab")
            }
            pm.closePane(id: uuid)
            return jsonOK(["session_id": tab.id.uuidString, "pane_count": pm.rootPane.leafIDs.count])
        }
        // Close a tab
        let sessionID = json["session_id"] as? String
        if let sid = sessionID {
            guard let tab = wc.tabManager.tabs.first(where: { $0.id.uuidString == sid }) else {
                return jsonError("session not found: \(sid)")
            }
            wc.tabManager.closeTab(id: tab.id)
        } else {
            if let tab = wc.tabManager.activeTab {
                wc.tabManager.closeTab(id: tab.id)
            }
        }
        return jsonOK()
    }

    @MainActor
    private func handleExecute(_ json: [String: Any], _ wc: WindowController) -> String {
        guard let command = json["command"] as? String else {
            return jsonError("missing command")
        }
        let tab = resolveTab(json, wc)
        guard let tab else { return jsonError("session not found") }
        guard let instance = tab.instance else { return jsonError("not a terminal tab") }

        // Send command as paste text, then press Enter as a key event.
        // ghostty_surface_text triggers bracketed paste mode — the shell
        // won't execute until Enter is pressed outside the paste brackets.
        instance.backend.send(text: command)
        if let gb = instance.backend as? GhosttyBackend {
            // keyCode 36 = Return key, text "\r"
            gb.sendKeyPress(keyCode: 36, text: "\r")
        }
        return jsonOK(["session_id": tab.id.uuidString])
    }

    @MainActor
    private func handleRead(_ json: [String: Any], _ wc: WindowController) -> String {
        let tab = resolveTab(json, wc)
        guard let tab else { return jsonError("session not found") }
        guard let instance = tab.instance else { return jsonError("not a terminal tab") }

        let lineCount = min(max(json["lines"] as? Int ?? 20, 1), 10000)
        let snapshot = instance.backend.readBuffer(lineCount: lineCount)

        return jsonOK([
            "session_id": tab.id.uuidString,
            "lines": snapshot.lines,
            "rows": snapshot.rows,
            "cols": snapshot.cols
        ])
    }

    @MainActor
    private func handlePaste(_ json: [String: Any], _ wc: WindowController) -> String {
        guard let text = json["text"] as? String else {
            return jsonError("missing text")
        }
        let tab = resolveTab(json, wc)
        guard let tab else { return jsonError("session not found") }
        guard let instance = tab.instance else { return jsonError("not a terminal tab") }

        instance.backend.send(text: text)
        return jsonOK(["session_id": tab.id.uuidString])
    }

    @MainActor
    private func handleControlChar(_ json: [String: Any], _ wc: WindowController) -> String {
        guard let key = json["key"] as? String else {
            return jsonError("missing key")
        }
        let tab = resolveTab(json, wc)
        guard let tab else { return jsonError("session not found") }
        guard let instance = tab.instance else { return jsonError("not a terminal tab") }

        guard let gb = instance.backend as? GhosttyBackend else {
            return jsonError("backend does not support key events")
        }
        // Send as key events, not paste — control chars must bypass bracketed paste
        switch key {
        case "c":     gb.sendKeyPress(keyCode: 8,  text: "\u{03}")
        case "d":     gb.sendKeyPress(keyCode: 2,  text: "\u{04}")
        case "z":     gb.sendKeyPress(keyCode: 6,  text: "\u{1A}")
        case "a":     gb.sendKeyPress(keyCode: 0,  text: "\u{01}")
        case "e":     gb.sendKeyPress(keyCode: 14, text: "\u{05}")
        case "k":     gb.sendKeyPress(keyCode: 40, text: "\u{0B}")
        case "l":     gb.sendKeyPress(keyCode: 37, text: "\u{0C}")
        case "u":     gb.sendKeyPress(keyCode: 32, text: "\u{15}")
        case "w":     gb.sendKeyPress(keyCode: 13, text: "\u{17}")
        case "enter": gb.sendKeyPress(keyCode: 36, text: "\r")
        case "esc":   gb.sendKeyPress(keyCode: 53, text: "\u{1B}")
        case "tab":   gb.sendKeyPress(keyCode: 48, text: "\t")
        default:      return jsonError("unknown key: \(key)")
        }
        return jsonOK(["session_id": tab.id.uuidString])
    }

    @MainActor
    private func handleClear(_ json: [String: Any], _ wc: WindowController) -> String {
        let tab = resolveTab(json, wc)
        guard let tab else { return jsonError("session not found") }
        guard let instance = tab.instance else { return jsonError("not a terminal tab") }
        if let gb = instance.backend as? GhosttyBackend {
            gb.sendKeyPress(keyCode: 37, text: "\u{0C}")
        }
        return jsonOK(["session_id": tab.id.uuidString])
    }

    @MainActor
    private func handleSplit(_ json: [String: Any], _ wc: WindowController) -> String {
        guard let direction = json["direction"] as? String,
              direction == "h" || direction == "v" else {
            return jsonError("provide direction: \"h\" or \"v\"")
        }
        guard let tab = resolveTab(json, wc) ?? wc.tabManager.activeTab,
              let pm = tab.paneManager else {
            return jsonError("no active terminal tab")
        }
        let axis: Axis = direction == "h" ? .horizontal : .vertical
        pm.splitFocusedPane(axis: axis)
        return jsonOK(["session_id": tab.id.uuidString])
    }

    @MainActor
    private func serializePaneTree(_ node: PaneNode) -> [String: Any] {
        switch node {
        case .leaf(let id, _):
            return ["type": "leaf", "pane_id": id.uuidString]
        case .split(_, let axis, let first, let second, let ratio):
            return [
                "type": "split",
                "axis": axis == .horizontal ? "horizontal" : "vertical",
                "ratio": ratio,
                "first": serializePaneTree(first),
                "second": serializePaneTree(second)
            ]
        }
    }

    @MainActor
    private func handleSetAppearance(_ json: [String: Any], _ wc: WindowController) -> String {
        if let title = json["title"] as? String {
            if let tab = resolveTab(json, wc) {
                wc.tabManager.renameTab(id: tab.id, name: title.isEmpty ? nil : title)
                return jsonOK(["session_id": tab.id.uuidString])
            }
            return jsonError("session not found")
        }
        return jsonError("provide title")
    }

    // MARK: - Helpers

    @MainActor
    private func resolveTab(_ json: [String: Any], _ wc: WindowController) -> Tab? {
        if let sid = json["session_id"] as? String {
            return wc.tabManager.tabs.first(where: { $0.id.uuidString == sid })
        }
        return wc.tabManager.activeTab
    }
}

// MARK: - JSON helpers

func jsonOK(_ data: [String: Any] = [:]) -> String {
    var result: [String: Any] = ["ok": true]
    for (k, v) in data { result[k] = v }
    guard let json = try? JSONSerialization.data(withJSONObject: result),
          let str = String(data: json, encoding: .utf8) else {
        return "{\"ok\":true}"
    }
    return str
}

func jsonError(_ message: String) -> String {
    let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
    return "{\"ok\":false,\"error\":\"\(escaped)\"}"
}
