/* ═══════════════════════════════════════════════
   SHELL EMULATOR — command handler & virtual FS
   kitty-style CLI: macuake <command> [--flags]
   ═══════════════════════════════════════════════ */

window.MQ_SHELL = {

  completions: [
    'macuake state','macuake ls','macuake toggle','macuake show','macuake hide',
    'macuake new-tab','macuake new-tab --title','macuake close-tab','macuake close-tab --match',
    'macuake focus-tab','macuake focus-tab --match',
    'macuake split --horizontal','macuake split --vertical',
    'macuake close-pane','macuake send-text','macuake send-key',
    'macuake launch','macuake get-text','macuake get-text --lines',
    'macuake pin','macuake unpin',
    'macuake resize --width','macuake resize --height',
    'macuake settings','macuake clear',
    'ls','pwd','whoami','echo','cat README.md','cat Package.swift','neofetch','clear','help'
  ],

  // Virtual filesystem for cat
  files: {
    'README.md': [
      '\x1b[1m# macuake\x1b[0m', '',
      '\x1b[90m> Quake-style drop-down terminal for macOS, powered by Ghostty.\x1b[0m', '',
      'One hotkey. Instant terminal. \x1b[36mOption+Space\x1b[0m slides it down from the top.', '',
      '\x1b[1m## Features\x1b[0m',
      '- GPU-accelerated (GhosttyKit Metal renderer)',
      '- Hotkey toggle from any app',
      '- Tabs & split panes',
      '- MCP server (17 tools)',
      '- Socket API at /tmp/macuake.sock',
      '- Auto-updates via Sparkle'
    ],
    'Package.swift': [
      '\x1b[35mimport\x1b[0m PackageDescription', '',
      '\x1b[35mlet\x1b[0m package = \x1b[36mPackage\x1b[0m(',
      '    name: \x1b[31m"Macuake"\x1b[0m,',
      '    platforms: [.\x1b[36mmacOS\x1b[0m(.\x1b[36mv14\x1b[0m)],',
      '    targets: [',
      '        .\x1b[36mexecutableTarget\x1b[0m(name: \x1b[31m"Macuake"\x1b[0m, ...)',
      '    ]',
      ')'
    ],
  },

  // Neofetch art
  neofetch: [
    ['\x1b[32m                    \'c.          ', '\x1b[36muser\x1b[0m@\x1b[36mmacbook\x1b[0m'],
    ['\x1b[32m                 ,xNMM.          ', '\x1b[0m-----------'],
    ['\x1b[32m               .OMMMMo            ', '\x1b[36mOS:\x1b[0m macOS Sonoma 14.2'],
    ['\x1b[32m               OMMM0,             ', '\x1b[36mHost:\x1b[0m MacBook Pro (M3 Pro)'],
    ['\x1b[32m     .;loddo:\' loolloddol;.      ', '\x1b[36mShell:\x1b[0m zsh 5.9'],
    ['\x1b[32m   cKMMMMMMMMMMNWMMMMMMMMMM0:     ', '\x1b[36mTerminal:\x1b[0m macuake 0.1.0'],
    ['\x1b[32m .KMMMMMMMMMMMMMMMMMMMMMMMWd.     ', '\x1b[36mCPU:\x1b[0m Apple M3 Pro'],
    ['\x1b[32m XMMMMMMMMMMMMMMMMMMMMMMMX.       ', '\x1b[36mMemory:\x1b[0m 18432 MiB'],
  ],

  lsOutput: ['MaQuake/', 'Package.swift', 'README.md', 'scripts/', 'vendor/', 'site/'],

  readLines: [
    'drwxr-xr-x  12 user staff  384 Mar  7 10:22 .',
    '-rw-r--r--   1 user staff 2048 Mar  7 10:20 Package.swift',
    '-rw-r--r--   1 user staff  890 Mar  7 09:30 README.md',
    'drwxr-xr-x   8 user staff  256 Mar  7 10:22 MaQuake',
    'drwxr-xr-x   4 user staff  128 Mar  7 09:15 scripts',
  ],

  validControlChars: ['c', 'd', 'z', 'l', 'u', 'a', 'e', 'k', 'w'],

  // Parse --flag value pairs from parts array
  parseFlags(parts) {
    const flags = {};
    const positional = [];
    for (let i = 0; i < parts.length; i++) {
      if (parts[i].startsWith('--')) {
        const key = parts[i].slice(2);
        // boolean flag if next is missing or another flag
        if (i + 1 >= parts.length || parts[i + 1].startsWith('--')) {
          flags[key] = true;
        } else {
          flags[key] = parts[++i];
        }
      } else {
        positional.push(parts[i]);
      }
    }
    return { flags, positional };
  },

  /**
   * Handle a command from any pane's shell.
   * @param {string} input — raw command string
   * @param {Terminal} terminal — xterm.js Terminal instance
   * @param {string} paneId — ID of the pane that ran the command
   * @param {object} ctx — app context
   */
  handleCmd(input, terminal, paneId, ctx) {
    const self = window.MQ_SHELL;
    const parts = input.split(/\s+/), cmd = parts[0];

    // Color helpers
    const G = '\x1b[32m', C = '\x1b[36m', Y = '\x1b[33m', R = '\x1b[31m';
    const D = '\x1b[90m', W = '\x1b[1m', N = '\x1b[0m';

    // ── Shell built-ins ──

    if (cmd === 'help') {
      terminal.writeln(W + 'macuake' + N + ' — Quake-style terminal for macOS\r\n');
      terminal.writeln(D + '  COMMANDS' + N);
      const cmds = [
        ['state',                    'Show terminal state (visible, pinned, tabs, panes)'],
        ['ls',                       'List all tabs and panes'],
        ['toggle',                   'Toggle terminal visibility'],
        ['show / hide',              'Show or hide the terminal window'],
        ['new-tab [--title NAME]',   'Create a new tab'],
        ['close-tab [--match ID]',   'Close a tab (default: current)'],
        ['focus-tab --match ID',     'Focus a tab by ID'],
        ['split [--horizontal | --vertical]', 'Split the current pane'],
        ['close-pane',               'Close the current pane'],
        ['launch <cmd>',             'Run a command in the active pane'],
        ['send-text <text>',         'Send text to the active pane'],
        ['send-key <key>',           'Send Ctrl+key (c, d, z, l, ...)'],
        ['get-text [--lines N]',     'Read terminal output (default: 5 lines)'],
        ['pin / unpin',              'Pin or unpin above all windows'],
        ['resize [--width N] [--height N]', 'Set width/height percent'],
        ['settings',                 'Open the settings panel'],
        ['clear',                    'Clear the terminal buffer'],
      ];
      cmds.forEach(([c, d]) => terminal.writeln('  ' + C + ('macuake ' + c).padEnd(40) + N + D + d + N));
      terminal.writeln('');
      terminal.writeln(D + '  SHELL' + N);
      const sh = [
        ['ls',          'List files'],
        ['pwd',         'Current directory'],
        ['whoami',      'Current user'],
        ['echo <text>', 'Echo text'],
        ['cat <file>',  'Show file contents'],
        ['neofetch',    'System info'],
        ['clear',       'Clear terminal'],
        ['help',        'Show this help'],
      ];
      sh.forEach(([c, d]) => terminal.writeln('  ' + C + c.padEnd(40) + N + D + d + N));
      return;
    }
    if (cmd === 'clear') { terminal.clear(); return; }
    if (cmd === 'ls' && parts[1] !== '--') { self.lsOutput.forEach(f => terminal.writeln(f.endsWith('/') ? '\x1b[34m' + f + '\x1b[0m' : f)); return; }
    if (cmd === 'pwd') { terminal.writeln('/Users/user/Projects/macuake'); return; }
    if (cmd === 'whoami') { terminal.writeln('user'); return; }
    if (cmd === 'echo') { terminal.writeln(parts.slice(1).join(' ')); return; }
    if (cmd === 'cat') {
      const file = parts[1];
      if (!file) { terminal.writeln(R + 'Usage: cat <file>' + N); return; }
      if (self.files[file]) self.files[file].forEach(l => terminal.writeln(l));
      else terminal.writeln(R + 'cat: ' + file + ': No such file' + N);
      return;
    }
    if (cmd === 'neofetch') {
      self.neofetch.forEach(([a, b]) => terminal.writeln(a + b));
      return;
    }

    // ── macuake CLI commands ──

    if (cmd === 'macuake') {
      const sub = parts[1];
      const args = parts.slice(2);
      const { flags, positional } = self.parseFlags(args);

      if (!sub) { terminal.writeln(D + 'Usage: macuake <command> [flags]. Type ' + W + 'help' + N + D + ' for commands.' + N); return; }

      // ── state ──
      if (sub === 'state') {
        const tree = ctx.paneTrees.get(ctx.state.activeTabId);
        const paneCount = tree ? ctx.collectLeaves(tree).length : 1;
        terminal.writeln(C + 'Visible:   ' + N + (ctx.state.visible ? G + 'yes' + N : R + 'no' + N));
        terminal.writeln(C + 'Pinned:    ' + N + (ctx.state.pinned ? G + 'yes' + N : D + 'no' + N));
        terminal.writeln(C + 'Tabs:      ' + N + Y + ctx.state.tabs.length + N);
        terminal.writeln(C + 'Panes:     ' + N + Y + paneCount + N);
        terminal.writeln(C + 'Active tab:' + N + ' ' + Y + ctx.state.activeTabId + N);
        terminal.writeln(C + 'Version:   ' + N + '0.1.0');
        return;
      }

      // ── ls (list tabs & panes) ──
      if (sub === 'ls') {
        ctx.state.tabs.forEach((t, i) => {
          const tree = ctx.paneTrees.get(t.id);
          const panes = tree ? ctx.collectLeaves(tree) : [];
          const active = t.id === ctx.state.activeTabId;
          const marker = active ? G + ' *' + N : '  ';
          terminal.writeln(marker + C + ' Tab ' + Y + '#' + t.id + N + '  ' + W + t.title + N + D + '  (' + panes.length + (panes.length === 1 ? ' pane' : ' panes') + ')' + N);
          panes.forEach(pid => {
            const isFocused = pid === paneId;
            terminal.writeln('    ' + D + '\u2514 ' + N + (isFocused ? G + pid + ' (focused)' + N : D + pid + N));
          });
        });
        return;
      }

      // ── toggle / show / hide ──
      if (sub === 'toggle') {
        ctx.state.visible = !ctx.state.visible;
        terminal.writeln(G + 'Terminal ' + (ctx.state.visible ? 'shown' : 'hidden') + '.' + N);
        if (!ctx.state.visible) setTimeout(() => { if (ctx.interactiveOpen) ctx.toggleInteractive(); }, 300);
        return;
      }
      if (sub === 'show') {
        ctx.state.visible = true;
        terminal.writeln(G + 'Terminal shown.' + N);
        return;
      }
      if (sub === 'hide') {
        ctx.state.visible = false;
        terminal.writeln(G + 'Terminal hidden.' + N + D + ' Press Option+Space to show.' + N);
        setTimeout(() => { if (ctx.interactiveOpen) ctx.toggleInteractive(); }, 300);
        return;
      }

      // ── new-tab [--title NAME] or positional ──
      if (sub === 'new-tab') {
        const title = flags.title || positional.join(' ') || '~';
        const tab = ctx.addNewTab(title);
        terminal.writeln(G + 'Created tab ' + N + W + '"' + title + '"' + N + D + ' (' + ctx.state.tabs.length + ' tabs open)' + N);
        return;
      }

      // ── close-tab [--match ID] ──
      if (sub === 'close-tab') {
        if (ctx.state.tabs.length <= 1) {
          terminal.writeln(Y + 'Cannot close the last tab.' + N);
          return;
        }
        let tabId = ctx.state.activeTabId;
        if (flags.match !== undefined) {
          const id = parseInt(flags.match);
          const found = ctx.state.tabs.find(t => t.id === id);
          if (!found) { terminal.writeln(R + 'No tab matching id ' + flags.match + N); return; }
          tabId = id;
        } else if (positional[0] !== undefined) {
          const id = parseInt(positional[0]);
          const found = ctx.state.tabs.find(t => t.id === id);
          if (!found) { terminal.writeln(R + 'No tab matching id ' + positional[0] + N); return; }
          tabId = id;
        }
        const tab = ctx.state.tabs.find(t => t.id === tabId);
        const name = tab ? tab.title : tabId;
        ctx.closeTab(tabId);
        terminal.writeln(G + 'Closed tab ' + N + W + '"' + name + '"' + N + D + '. ' + ctx.state.tabs.length + ' tab' + (ctx.state.tabs.length === 1 ? '' : 's') + ' remaining.' + N);
        return;
      }

      // ── focus-tab --match ID ──
      if (sub === 'focus-tab') {
        const id = parseInt(flags.match || positional[0]);
        if (isNaN(id)) { terminal.writeln(R + 'Usage: macuake focus-tab --match <id>' + N); return; }
        const found = ctx.state.tabs.find(t => t.id === id);
        if (!found) { terminal.writeln(R + 'No tab matching id ' + id + N); return; }
        ctx.state.activeTabId = id;
        ctx.renderTabs();
        terminal.writeln(G + 'Focused tab ' + N + W + '"' + found.title + '"' + N);
        return;
      }

      // ── split [--horizontal | --vertical | h | v] ──
      if (sub === 'split') {
        let dir = 'h';
        if (flags.vertical || positional[0] === 'v' || positional[0] === 'vertical') dir = 'v';
        // --horizontal is default
        const newId = ctx.splitPane(paneId, dir);
        if (newId) {
          const dirName = dir === 'h' ? 'horizontal' : 'vertical';
          const tree = ctx.paneTrees.get(ctx.state.activeTabId);
          const count = tree ? ctx.collectLeaves(tree).length : 1;
          terminal.writeln(G + 'Split pane ' + dirName + 'ly.' + N + D + ' ' + count + ' panes in tab.' + N);
        }
        return;
      }

      // ── close-pane ──
      if (sub === 'close-pane') {
        const tree = ctx.paneTrees.get(ctx.state.activeTabId);
        if (tree && tree.type !== 'leaf') {
          ctx.closePane(paneId);
          const newTree = ctx.paneTrees.get(ctx.state.activeTabId);
          const count = newTree ? ctx.collectLeaves(newTree).length : 1;
          terminal.writeln(G + 'Closed pane.' + N + D + ' ' + count + ' pane' + (count === 1 ? '' : 's') + ' remaining.' + N);
        } else {
          terminal.writeln(Y + 'Only one pane. Use ' + W + 'macuake close-tab' + N + Y + ' to close the tab.' + N);
        }
        return;
      }

      // ── launch <cmd> (execute command) ──
      if (sub === 'launch' || sub === 'execute') {
        const execCmd = (flags.command || positional.join(' ')) || '';
        if (!execCmd) { terminal.writeln(R + 'Usage: macuake launch <command>' + N); return; }
        terminal.writeln(G + 'Running: ' + N + W + execCmd + N);
        return;
      }

      // ── send-text <text> ──
      if (sub === 'send-text' || sub === 'paste') {
        const text = positional.join(' ');
        if (!text) { terminal.writeln(R + 'Usage: macuake send-text <text>' + N); return; }
        terminal.writeln(G + 'Sent ' + N + Y + text.length + N + G + ' chars.' + N);
        return;
      }

      // ── send-key <key> (control char) ──
      if (sub === 'send-key' || sub === 'control-char') {
        const ch = (positional[0] || '').toLowerCase();
        if (!ch) { terminal.writeln(R + 'Usage: macuake send-key <key>' + N + D + '  Valid: ' + self.validControlChars.join(', ') + N); return; }
        if (self.validControlChars.includes(ch)) {
          terminal.writeln(G + 'Sent ' + N + W + 'Ctrl+' + ch.toUpperCase() + N);
        } else {
          terminal.writeln(R + 'Invalid key: ' + ch + N + D + '. Valid: ' + self.validControlChars.join(', ') + N);
        }
        return;
      }

      // ── get-text [--lines N] (read terminal) ──
      if (sub === 'get-text' || sub === 'read') {
        const n = parseInt(flags.lines || positional[0]) || 5;
        terminal.writeln(D + 'Reading last ' + n + ' lines from active pane:' + N);
        self.readLines.slice(0, n).forEach(l => terminal.writeln('  ' + l));
        return;
      }

      // ── pin / unpin ──
      if (sub === 'pin') {
        ctx.state.pinned = true;
        ctx.pinBtn.classList.add('pinned');
        if (ctx.interactiveOpen) ctx.backdrop.classList.remove('visible');
        terminal.writeln(G + 'Pinned above all windows.' + N);
        return;
      }
      if (sub === 'unpin') {
        ctx.state.pinned = false;
        ctx.pinBtn.classList.remove('pinned');
        if (ctx.interactiveOpen) ctx.backdrop.classList.add('visible');
        terminal.writeln(G + 'Unpinned.' + N);
        return;
      }

      // ── resize [--width N] [--height N] [--opacity N] ──
      if (sub === 'resize' || sub === 'set-appearance') {
        const w = Math.min(100, Math.max(30, parseInt(flags.width || positional[0]) || 80));
        const h = Math.min(90, Math.max(20, parseInt(flags.height || positional[1]) || 50));
        terminal.writeln(G + 'Resized.' + N + '  Width: ' + Y + w + '%' + N + '  Height: ' + Y + h + '%' + N);
        return;
      }

      // ── settings ──
      if (sub === 'settings') {
        terminal.writeln('');
        terminal.writeln('  ' + W + 'Settings' + N);
        terminal.writeln('  ' + D + '\u2500'.repeat(36) + N);
        terminal.writeln('  ' + C + 'Hotkey           ' + N + 'Option+Space');
        terminal.writeln('  ' + C + 'Width            ' + N + '80%');
        terminal.writeln('  ' + C + 'Height           ' + N + '50%');
        terminal.writeln('  ' + C + 'Opacity          ' + N + '1.0');
        terminal.writeln('  ' + C + 'Pin on top       ' + N + (ctx.state.pinned ? G + 'Yes' + N : D + 'No' + N));
        terminal.writeln('  ' + C + 'Display          ' + N + 'Follow cursor');
        terminal.writeln('  ' + C + 'API access       ' + N + G + 'Enabled' + N);
        terminal.writeln('  ' + C + 'Auto-update      ' + N + G + 'Enabled' + N);
        terminal.writeln('  ' + C + 'Ghostty config   ' + N + '~/.config/ghostty/config');
        return;
      }

      // ── clear ──
      if (sub === 'clear') {
        terminal.clear();
        terminal.writeln(G + 'Buffer cleared.' + N);
        return;
      }

      terminal.writeln(R + 'Unknown command: macuake ' + sub + N);
      terminal.writeln(D + 'Run ' + W + 'help' + N + D + ' for available commands.' + N);
      return;
    }

    terminal.writeln(R + 'command not found: ' + cmd + N);
  }
};
