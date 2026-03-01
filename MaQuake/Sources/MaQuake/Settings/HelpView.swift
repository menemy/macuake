import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("macuake")
                    .font(.title2.bold())

                Text("GPU-accelerated drop-down terminal for macOS")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Text("Powered by libghostty (Ghostty terminal engine). Slides from the top of the screen like the Quake console. All terminal rendering, fonts, colors and keybindings are configured via your Ghostty config file.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)

                Divider()

                // MARK: - Why macuake

                VStack(alignment: .leading, spacing: 8) {
                    Text("Why macuake?")
                        .font(.headline)

                    comparisonRow(
                        "vs iTerm2 / Terminal.app",
                        "macuake is always one hotkey away. No Dock icon, no window management. GPU-rendered via Metal — handles massive output from Claude Code without lag."
                    )
                    comparisonRow(
                        "vs Ghostty Quick Terminal",
                        "macuake adds tabs, split panes, socket API for automation, pin mode, and instant mouseDown tab switching. Uses the same libghostty engine."
                    )
                    comparisonRow(
                        "vs cmux",
                        "Similar architecture (libghostty embedded). macuake adds auto-detection of GHOSTTY_RESOURCES_DIR for themes, right-click context menu, and sideshell-compatible API."
                    )
                    comparisonRow(
                        "vs Kitty / WezTerm",
                        "Native macOS app (not cross-platform Electron/GTK). NSPanel floats above all apps, respects Spaces. Metal rendering, not OpenGL."
                    )
                }

                Divider()

                // MARK: - Keyboard shortcuts

                VStack(alignment: .leading, spacing: 12) {
                    helpSection("Terminal") {
                        shortcutRow("Toggle terminal", "⌥ Space")
                        shortcutRow("Hide on click outside", "auto (unpin to enable)")
                        shortcutRow("Pin / Unpin", "⌘ ⇧ P")
                    }

                    helpSection("Tabs") {
                        shortcutRow("New tab", "⌘ T")
                        shortcutRow("Close tab", "⌘ W")
                        shortcutRow("Reopen closed tab", "⌘ ⇧ T")
                        shortcutRow("Next tab", "⌘ ⇧ ]  /  Ctrl Tab")
                        shortcutRow("Previous tab", "⌘ ⇧ [  /  Ctrl ⇧ Tab")
                        shortcutRow("Go to tab 1–8", "⌘ 1 – ⌘ 8")
                        shortcutRow("Go to last tab", "⌘ 9")
                        shortcutRow("Rename tab", "Double-click tab title")
                        shortcutRow("New tab (empty area)", "Double-click tab bar")
                    }

                    helpSection("Split Panes") {
                        shortcutRow("Split horizontal", "⌘ D  /  Right-click menu")
                        shortcutRow("Split vertical", "⌘ ⇧ D  /  Right-click menu")
                        shortcutRow("Next pane", "⌘ ]")
                        shortcutRow("Previous pane", "⌘ [")
                        shortcutRow("Close pane", "⌘ W")
                    }

                    helpSection("Editing") {
                        shortcutRow("Copy", "⌘ C  /  Right-click")
                        shortcutRow("Paste", "⌘ V  /  Right-click")
                        shortcutRow("Select All", "⌘ A")
                        shortcutRow("Clear screen", "⌘ K  /  Ctrl L")
                        shortcutRow("Find in scrollback", "⌘ F")
                    }

                    helpSection("Mouse") {
                        shortcutRow("Select text", "Click + drag")
                        shortcutRow("Open URL", "⌘ + Click")
                        shortcutRow("Right-click menu", "Copy / Paste / Split")
                        shortcutRow("Scroll on tab bar", "Switch tabs")
                        shortcutRow("Drag bottom corner", "Resize terminal")
                        shortcutRow("Middle-click tab", "Close tab")
                    }
                }

                Divider()

                // MARK: - How keyboard input works

                VStack(alignment: .leading, spacing: 8) {
                    Text("How keyboard input works")
                        .font(.headline)

                    Text("macuake passes all keyboard input to the Ghostty engine. Keybindings, Option-as-Alt, themes, fonts — everything is configured via your Ghostty config file. macuake only intercepts Cmd+keys (so they reach the terminal instead of macOS menus) and non-printable keys like arrows and backspace (to prevent system beeps).")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("Ghostty config location:")
                        .font(.system(size: 11, weight: .medium))
                    Text("~/Library/Application Support/com.mitchellh.ghostty/config")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Divider()

                // MARK: - Socket API

                VStack(alignment: .leading, spacing: 8) {
                    Text("Socket API")
                        .font(.headline)

                    Text("macuake exposes a Unix socket API at /tmp/macuake.sock for automation. Compatible with sideshell MCP tools. Enable in Settings.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("Actions: state, list, toggle, show, hide, pin, unpin, new-tab, focus, close-session, execute, read, paste, control-char, clear, split, set-appearance")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    Text("Example:")
                        .font(.system(size: 11, weight: .medium))
                    Text("echo '{\"action\":\"execute\",\"command\":\"ls\"}' | nc -U /tmp/macuake.sock")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Divider()

                // MARK: - MCP Server

                VStack(alignment: .leading, spacing: 8) {
                    Text("MCP Server")
                        .font(.headline)

                    Text("macuake includes a built-in MCP (Model Context Protocol) server. AI tools like Claude Desktop, Cursor, and Claude Code can control your terminal via HTTP.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("Enable MCP in Settings → API. Default mode is \"Ask on first request\".")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Text("Endpoint: http://localhost:\(MCPHTTPServer.defaultPort)/mcp")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    Text("Claude Desktop config (~/.claude/claude_desktop_config.json):")
                        .font(.system(size: 11, weight: .medium))
                    Text("""
                    {
                      "mcpServers": {
                        "macuake": {
                          "url": "http://localhost:\(MCPHTTPServer.defaultPort)/mcp"
                        }
                      }
                    }
                    """)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(6)

                    Text("Cursor config (.cursor/mcp.json):")
                        .font(.system(size: 11, weight: .medium))
                    Text("""
                    {
                      "mcpServers": {
                        "macuake": {
                          "url": "http://localhost:\(MCPHTTPServer.defaultPort)/mcp"
                        }
                      }
                    }
                    """)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(6)

                    Text("17 tools: state, list, toggle, show, hide, pin, unpin, new_tab, focus, close_session, execute, read, paste, control_char, clear, split, set_appearance")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Divider()

                // MARK: - Recommended config

                DisclosureGroup("Recommended Ghostty Config") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste into your Ghostty config file. These are suggestions — macuake works with any Ghostty config.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)

                        ZStack(alignment: .topTrailing) {
                            Text(Self.ghosttyConfigSnippet)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.primary)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.black.opacity(0.3))
                                .cornerRadius(6)

                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(Self.ghosttyConfigSnippet, forType: .string)
                            }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .padding(6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
    }

    private static let ghosttyConfigSnippet = """
    # Option key works as Alt/Meta (for Alt+B, Alt+F word navigation)
    macos-option-as-alt = true

    # Auto-copy selected text to system clipboard
    copy-on-select = clipboard

    # Shell integration (terminal title, working directory tracking)
    shell-integration = detect

    # Large scrollback for Claude Code output
    scrollback-limit = 100000

    # Font (install: brew install font-jetbrains-mono-nerd-font)
    font-family = JetBrainsMono Nerd Font
    font-size = 14
    font-thicken = true

    # Theme and colors
    theme = deep
    window-colorspace = display-p3

    # Shift+Arrow text selection in terminal viewport
    keybind = performable:shift+arrow_left=adjust_selection:left
    keybind = performable:shift+arrow_right=adjust_selection:right
    keybind = performable:shift+arrow_up=adjust_selection:up
    keybind = performable:shift+arrow_down=adjust_selection:down
    keybind = performable:shift+home=adjust_selection:home
    keybind = performable:shift+end=adjust_selection:end
    """

    // MARK: - View helpers

    private func helpSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 2)
            content()
        }
    }

    private func shortcutRow(_ label: String, _ shortcut: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Spacer()
            Text(shortcut)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private func comparisonRow(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}
