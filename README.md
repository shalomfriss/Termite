# Terminal Tabs

A small native macOS terminal with independent shell tabs. Each tab owns a PTY and a [`GhosttyTerminal`](https://lib.ghostty.org/vt/). libghostty-vt handles VT parsing, screen state, colors, styles, cursor state, and title updates. AppKit handles rendering and input.

Tabs can be organized into named groups and displayed horizontally or in a vertical sidebar. Each tab shows its current directory, updated from the shell through OSC 7. Tab orientation and visibility are available from the layout menu or Settings (Command-,) and persist across launches.

## Run

You need macOS 14+, Swift 6, Git, and the Zig version required by the pinned Ghostty revision.

```sh
./Scripts/run.sh
```

The first run fetches Ghostty, builds `libghostty-vt.dylib`, and launches the app. If the library already exists elsewhere:

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
| Open Settings | Command-, |
| Paste | Command-V |

Right-click a group to rename or close it. Closing the final tab or group creates a fresh one, so the window always remains usable. Resizing the window updates both the PTY and the corresponding Ghostty terminal grid.

## Structure

- `GhosttyBridge.c` loads libghostty-vt at runtime and connects it to a macOS PTY.
- `TerminalModel.swift` owns tab state and shell sessions.
- `TerminalCanvas.swift` draws Ghostty's render-state cells with AppKit.
- `TerminalTabsApp.swift` provides the tab bar, window, and commands.

The bridge is intentionally narrow. It can adopt newer libghostty-vt releases without exposing the full C API to Swift.
