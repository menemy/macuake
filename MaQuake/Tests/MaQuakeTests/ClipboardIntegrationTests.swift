import Testing
import AppKit
import GhosttyKit
@testable import Macuake

/// Uses the real engine and clipboard callbacks. Run separately with
/// MACUAKE_TEST_GHOSTTY=1 swift test -Xswiftc -swift-version -Xswiftc 5 --filter ClipboardIntegrationTests.
@MainActor
@Suite(.serialized, .enabled(if: getenv("MACUAKE_TEST_GHOSTTY") != nil))
struct ClipboardIntegrationTests {
    @Test(arguments: [
        "one\ntwo",
        #"""
        ps -eo args | grep [g]unicorn | grep -o -- '--timeout[= ][0-9]*\|-t [0-9]*'
        systemctl cat $(systemctl list-units --type=service | grep -o '[^ ]*gunicorn[^ ]*\|[^ ]*backend[^ ]*' | head -1) | grep -i -e timeout -e '-c ' ; grep -rn '^timeout' /etc/gunicorn* $(ps -eo args | grep [g]unicorn | grep -o -- '-c [^ ]*' | cut -d' ' -f2 | head -1) 2>/dev/null
        """#,
    ])
    func multilinePaste_completesOnRequestingSurface(payload: String) async throws {
        _ = NSApplication.shared
        let requesting = GhosttyBackend()
        requesting.startProcess(executable: "/bin/cat", execName: "cat", currentDirectory: "/tmp")
        defer { requesting.terminate() }
        let surface = try #require(requesting.surface)

        // Keep another surface focused to catch routing based on first responder.
        let other = GhosttyBackend()
        other.startProcess(executable: "/bin/cat", execName: "cat", currentDirectory: "/tmp")
        defer { other.terminate() }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = other.view
        window.makeFirstResponder(other.focusableView)
        defer { window.contentView = nil }

        let pasteboard = NSPasteboard.general
        let savedItems = pasteboard.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        defer {
            pasteboard.clearContents()
            let restored = savedItems.map { contents in
                let item = NSPasteboardItem()
                for (type, data) in contents { item.setData(data, forType: type) }
                return item
            }
            pasteboard.writeObjects(restored)
        }

        // cat never enables bracketed paste, just like a remote shell without it.
        // These lines must pass through paste protection and its confirmation callback.
        let text = "MACUAKE_PASTE_FIRST\n\(payload)\nMACUAKE_PASTE_SECOND\n"
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let handled = "paste_from_clipboard".withCString {
            ghostty_surface_binding_action(surface, $0, UInt(strlen($0)))
        }
        #expect(handled)

        let deadline = Date().addingTimeInterval(3)
        var output = ""
        repeat {
            try await Task.sleep(for: .milliseconds(20))
            GhosttyApp.shared.tick()
            output = requesting.readBuffer(lineCount: 30).lines.joined(separator: "\n")
        } while !output.contains("MACUAKE_PASTE_SECOND") && Date() < deadline

        #expect(output.contains("MACUAKE_PASTE_FIRST"))
        #expect(output.contains("MACUAKE_PASTE_SECOND"))
        #expect(!other.readBuffer(lineCount: 30).lines.joined(separator: "\n").contains("MACUAKE_PASTE_"))
    }
}
