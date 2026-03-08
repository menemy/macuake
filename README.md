# macuake

> **Alpha** — Quake-style drop-down terminal for macOS, powered by [Ghostty](https://ghostty.org).

One hotkey. Instant terminal. `Option+Space` slides it down from the top of any screen.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange?logo=swift)
![License: MIT](https://img.shields.io/badge/License-MIT-blue)

## Features

- **GPU-accelerated** — GhosttyKit Metal renderer. True color, ligatures, GPU text shaping.
- **Hotkey toggle** — `Option+Space` (customizable) from any app. No Dock icon.
- **Tabs & split panes** — multiple sessions with horizontal/vertical splits.
- **Ghostty themes** — use any Ghostty config for fonts, colors, opacity, keybindings.
- **MCP server** — built-in HTTP server (port 19876) with 17 tools. Control from Claude Code, Cursor, or any MCP client.
- **Socket API** — Unix socket at `/tmp/macuake.sock` for scripting.
- **Auto-updates** — Sparkle integration with EdDSA-signed releases.
- **Multi-display** — follows cursor across screens, notch-aware.

## Install

Download from [Releases](https://github.com/menemy/macuake/releases), or:

```bash
curl -LO https://github.com/menemy/macuake/releases/latest/download/Macuake.dmg
open Macuake.dmg
# Drag to /Applications
```

### Build from source

Requires: macOS 14+, Swift 5.9+, [Zig 0.15.2](https://ziglang.org/download/) (for GhosttyKit).

```bash
git clone --recursive https://github.com/menemy/macuake.git
cd macuake
./scripts/build-ghostty.sh   # build GhosttyKit xcframework
swift build                   # debug build
```

## Usage

Launch macuake — it lives in the menu bar (no Dock icon). Press `Option+Space` to toggle.

| Shortcut | Action |
|----------|--------|
| `Option+Space` | Toggle terminal |
| `Cmd+T` | New tab |
| `Cmd+W` | Close tab |
| `Cmd+D` | Split horizontal |
| `Cmd+Shift+D` | Split vertical |
| `Cmd+]` / `Cmd+[` | Next / previous pane |
| `Cmd+1`..`9` | Switch to tab N |
| `Cmd+,` | Settings |

### Ghostty config

macuake uses your Ghostty config (`~/.config/ghostty/config`). Open it from Settings or:

```bash
echo '{"action":"state"}' | nc -U /tmp/macuake.sock
```

## MCP Server

Add to Claude Code:

```bash
claude mcp add --transport http macuake http://localhost:19876/mcp
```

17 tools available: `state`, `list`, `toggle`, `show`, `hide`, `pin`, `unpin`, `new_tab`, `focus`, `close_session`, `execute`, `read`, `paste`, `control_char`, `clear`, `split`, `set_appearance`.

### Pane support

```bash
# List tabs with pane tree
claude> list(include_panes=true)

# Focus a specific pane
claude> focus(pane_id="...")

# Navigate panes
claude> focus(direction="next")

# Close a pane (not the whole tab)
claude> close_session(pane_id="...")
```

## Socket API

See [API.md](API.md) for the full reference.

```bash
# Execute a command
echo '{"action":"execute","command":"ls -la"}' | nc -U /tmp/macuake.sock

# Read terminal output
echo '{"action":"read","lines":50}' | nc -U /tmp/macuake.sock

# Split pane
echo '{"action":"split","direction":"h"}' | nc -U /tmp/macuake.sock
```

## Architecture

```
MaQuake/Sources/MaQuake/
├── API/              # ControlServer (socket API)
├── MCP/              # MCPHTTPServer (MCP over HTTP)
├── Panes/            # PaneManager, PaneNode tree
├── Settings/         # SettingsView, HelpView
├── Tabs/             # TabManager, TabBarView
├── Terminal/         # GhosttyApp, GhosttyBackend, GhosttyTerminalView
├── Updates/          # SparkleUpdater
└── Window/           # WindowController, TerminalPanel, ScreenDetector
```

- **GhosttyKit** — vendored xcframework, GPU Metal terminal engine
- **KeyboardShortcuts** — global hotkey (sindresorhus)
- **Sparkle** — auto-updates
- **SPM** project (not Xcode), `swift build` / `swift test`

## License

MIT
