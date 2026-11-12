# Terminal Tabs

A small native macOS terminal with independent shell tabs. Each tab owns a PTY and a [`GhosttyTerminal`](https://lib.ghostty.org/vt/). libghostty-vt handles VT parsing, screen state, colors, styles, cursor state, and title updates. AppKit handles rendering and input.

Tabs can be organized into named, collapsible groups and displayed horizontally or in a vertical sidebar. Each tab follows the shell's current directory, even when the shell does not emit OSC 7. Double-click a tab name to rename it. Tab orientation and visibility are available from the gear menu and persist across launches.

Enable **Graphical mode** from the checkbox above the terminal to immediately render the current directory as inline Kitty Graphics placements. The macOS-style view control offers icon, list, and column layouts. Folder icons use a shaded dimensional treatment with a cached bloom filter. Every listing includes a clickable `..` entry for its parent directory. Plain `ls` follows the selected graphical view, `ls -a` adds hidden entries, and `ll` or `ls -l` switches to a vertical layout with permissions, link count, owner, group, byte size, modification time, icons, and filenames. Graphical results remain part of normal terminal output and scrollback. Other common listing commands and aliases are also recognized, including `la`, `gls`, `lsd`, `eza`, `exa`, `tree`, `dir`, and `vdir`. Listings are powered by a pinned build of [eza](https://github.com/eza-community/eza); outside graphical mode, recognized listing commands render eza's colored terminal output. Single-click an item to select it, then double-click to enter a directory or open a file. Right-click an item for **Open**, **Open With**, **Copy**, and **Paste** actions. **Open With** lists compatible applications and includes an **Other…** picker. Paste targets a selected folder directly; for a selected file, it targets the current directory and uses collision-safe copy names.

## Run

You need macOS 14+, Swift 6, Git, Rust via rustup, and the Zig version required by the pinned Ghostty revision.

```sh
./Scripts/run.sh
```

The first run fetches Ghostty and eza, builds `libghostty-vt.dylib` plus a pinned eza executable, and launches the app. eza is built under its EUPL-1.2 license, which is copied beside the executable at `.build/bin/eza-LICENSE.txt`. If the Ghostty library already exists elsewhere:

```sh
LIBGHOSTTY_VT_PATH=/path/to/libghostty-vt.dylib swift run TerminalTabs
```

## Shortcuts

| Action | Shortcut |
|---|---|
| New tab | Command-T |
| New tab group | Command-Shift-T |
| Close tab | Command-W |
| Select tab | Command-1 through Command-9 |
| Previous / next tab | Command-Shift-[ / Command-Shift-] |
| Show / hide tab bar | Command-Shift-B |
| Open AI chat | Command-Shift-I |
| Paste | Command-V |

Use the chevron beside a group to fold or unfold its tabs. Right-click a group to collapse, expand, rename, or close it. Closing the final tab or group creates a fresh one, so the window always remains usable. Resizing the window updates both the PTY and the corresponding Ghostty terminal grid.

## AI chat

Open the gear settings panel (or press Command-,) to connect ChatGPT or Claude. Sign-in mode delegates browser authentication and credential storage to the official Codex and Claude Code CLIs. API-key mode is also available; keys are stored in macOS Keychain and model identifiers can be changed as providers release new models. Open the per-tab conversation with Command-Shift-I. Right-click a command block and choose **Attach Output to AI Chat** to send its command, working directory, and full captured output with your next question.

Sign-in mode requires the corresponding official CLI to be installed. API-key billing is separate from consumer ChatGPT and Claude subscriptions.

## Structure

- `GhosttyBridge.c` loads libghostty-vt at runtime and connects it to a macOS PTY.
- `TerminalModel.swift` owns tab state and shell sessions.
- `TerminalCanvas.swift` draws Ghostty's render-state cells with AppKit.
- `TerminalTabsApp.swift` provides the tab bar, window, and commands.

The bridge is intentionally narrow. It can adopt newer libghostty-vt releases without exposing the full C API to Swift.
