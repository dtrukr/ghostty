# Smart Background + Attention: Implementation and Testing

This document describes how the `smart-background` (per-pane background tinting)
and "attention" (bell/needs-attention tracking + focus cycling/auto-focus) are
implemented in Ghostty, plus how to test them locally.

## Configuration Overview

### Smart Background

Minimum knobs to enable a visible tint:

```conf
smart-background = true
smart-background-key = pwd        # or project
smart-background-strength = 1.0   # 0.0-1.0, >0 required to see changes
```

Notes:

- `smart-background-key = pwd` makes the tint change as the working directory
  changes.
- `smart-background-key = project` attempts to map a directory into a stable
  "project root" (VCS marker) when the cwd hint is trusted-local; for untrusted
  remote hints it falls back to `pwd` normalization.

### Attention

Minimum knobs to _see_ and _navigate_ attention:

```conf
bell-features = border
keybind = cmd+]=goto_attention:next
keybind = cmd+[=goto_attention:previous
```

Then enable one or more attention sources (you can combine these):

1. Attention when a command finishes (requires shell integration / OSC 133):

```conf
notify-on-command-finish = unfocused
notify-on-command-finish-action = bell
notify-on-command-finish-after = 5s
```

2. Attention when a desktop notification escape is emitted (OSC 9 / OSC 777):

```conf
desktop-notifications = true
attention-on-desktop-notification = true
```

3. Attention when an unfocused pane produces output and then becomes quiet:

```conf
attention-on-output-idle = 750ms
```

Optional: auto-focus the most recent attention surface after you have been idle:

```conf
auto-focus-attention = true
auto-focus-attention-idle = 5000ms
```

Optional: keep the attention border until user interaction (not merely focus):

```conf
attention-clear-on-focus = false
```

Optional debug logs:

```conf
attention-debug = true
```

## Smart Background: Implementation Details

### Data Flow Summary

1. A "cwd hint" is obtained.
   - Trusted-local: from the terminal's stored pwd (`Terminal.setPwd`) updated
     by OSC 7 where the host validates as local.
   - Untrusted: OSC 7 reported host does not validate as local. We do NOT trust
     it for filesystem behaviors, but we _do_ still use it to compute a smart
     background key so SSH/tmux sessions still provide visual context.

2. A key is derived and hashed.
   - `pwd` mode: normalized directory path (trims trailing separators).
   - `project` mode: if trusted-local, walk parents until finding a VCS marker
     (e.g. `.git`). If untrusted, fall back to `pwd` normalization.

3. A tinted background is computed from the hash + base colors.
   - Deterministically maps key hash -> hue (0-360).
   - Mixes that hue color with the configured base background based on
     `smart-background-strength`.
   - Best-effort clamps strength to preserve `minimum-contrast` with the
     configured foreground.

4. The new background is applied and propagated to the UI.
   - Updates the terminal's default background.
   - If the effective background changed, sends a surface `.color_change`
     message for `.background`, and queues a render.

### Key Code Locations

Core keying/tint logic:

- `src/termio/smart_background.zig`
  - `keyPath(...)`
  - `hashKey(...)`
  - `tintedBackground(...)`

OSC 7 parsing and "trusted vs untrusted host" handling:

- `src/termio/stream_handler.zig`
  - `reportPwd(...)` parses OSC 7, validates host, calls
    `smartBackgroundUpdateFromCwd(host, path, trusted_local)`
  - `applySmartBackground()` updates `terminal.colors.background.default` and
    emits `.color_change` when the effective background changes

UI propagation (macOS):

- The core emits `.color_change` and macOS observes it in
  `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` via the
  `.ghosttyColorDidChange` notification, updating `backgroundColor` for a
  `Ghostty.SurfaceView`.

### SSH/tmux Behavior

For smart background, Ghostty intentionally updates tinting even when OSC 7 is
"untrusted" (host not local). The untrusted cwd hint is used only for visual
context; it does not update the trusted `pwd` for filesystem behaviors.

## Attention: Implementation Details

### Concepts

- "Needs attention" state is represented in the macOS UI as `surfaceView.bell`
  with a bell border overlay (`bell-features = border`), and is also used as the
  set of candidates for `goto_attention`.
- Multiple sources can trigger a mark:
  - BEL (terminal bell)
  - Output-idle attention (core-driven)
  - Command-finish / desktop-notification sources (app-driven)

### Output-Idle Attention (Core)

High level:

1. When PTY output is processed on an unfocused surface and
   `attention-on-output-idle` is configured, core sends a lightweight message to
   the termio thread:
   - `src/termio/Termio.zig` in `processOutputLocked(...)`:
     - when `attention_on_output_idle != null` and `!terminal.flags.focused`,
       it queues `.output_activity = { focused = false }`

2. The termio thread arms a timer that fires after the configured "quiet
   period".
   - `src/termio/Thread.zig` handles `.output_activity`:
     - stores the time of last output, arms `output_idle` timer

3. When the timer fires and the surface stayed quiet long enough, it sends a
   surface message:
   - `.mark_attention = { source = .output_idle }`
   - `src/termio/Thread.zig` in `outputIdleCallback(...)`

4. On macOS, the runtime turns `.mark_attention` into the same UI pathway as a
   bell:
   - `macos/Sources/Ghostty/Ghostty.App.swift` `markAttention(...)` posts
     `.ghosttyBellDidRing` (source `output_idle`)
   - `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
     `.ghosttyBellDidRing` sets `bell = true` and records `bellInstant`

#### App-Inactive Behavior

When the host app loses focus (macOS "inactive"), Ghostty clears per-surface
focus in core (`src/App.zig` `focusEvent(false)` calls `Surface.focusCallback(false)`
for all surfaces). On macOS this is driven by `ghostty_app_set_focus(app, false)`
from `macos/Sources/Ghostty/Ghostty.App.swift` when `NSApplication.didResignActive`
fires.

This ensures output-driven attention sources (notably `attention-on-output-idle`)
still arm while the app is in the background, so attention borders are visible
when you return.

#### Split/Resize Suppression (Bug Fix)

Interactive programs often redraw after a resize (SIGWINCH), producing output
that is not a meaningful "work finished" signal. This can incorrectly arm
output-idle attention when you create a split or resize a window.

To prevent that, the termio thread suppresses arming output-idle attention for a
short window immediately after a resize:

- `src/termio/Thread.zig`
  - on `.resize`, record `output_idle_last_resize = now`
  - on `.output_activity` (unfocused), ignore if last resize was within ~250ms

### Focus Cycling / Auto-Focus (macOS)

Focus cycling (`goto_attention:*`) and auto-focus are implemented on macOS in
the terminal controller:

- `macos/Sources/Features/Terminal/BaseTerminalController.swift`
  - `cycleAttention(...)` chooses among surfaces where `surfaceView.bell == true`
  - Most recent is determined by `bellInstant` (monotonic uptime)

#### Auto-Focus: Exact Focus + Mouse Gating Logic

Auto-focus listens for `.ghosttyBellDidRing`. If `auto-focus-attention = true`,
it marks the controller as "pending" and then decides when it is allowed to
steal focus.

Key idea: **auto-focus is paused while you are "reading" the currently focused
pane**, where "reading" is defined as:

- A terminal surface is focused (first responder is inside a `SurfaceView`)
- The mouse cursor is inside that focused `SurfaceView`

This prevents focus from being stolen while you're looking at a pane, even if
you are not typing.

When attention becomes pending:

1. If a surface is focused and the mouse is inside it:
   - Auto-focus is paused (no timers are armed).
   - Debug overlay shows `paused(focused+mouse): pending`.
2. If a surface is focused but the mouse is outside it:
   - Auto-focus is allowed to resume (it arms the resume countdown described
     below).
3. If no surface is focused (terminal isn't first responder):
   - Auto-focus waits for `auto-focus-attention-idle` of user-idle, then focuses
     the most recent attention surface.

When auto-focus is allowed to resume, it uses `auto-focus-attention-resume-delay`
as a **debounced quiet-period**:

- A resume attempt is scheduled for `resume-delay` ms.
- Any user action (mouse/keyboard/scroll/mouse move) updates the activity
  timestamp and forces the resume attempt to wait until a full `resume-delay`
  has elapsed since the last activity.
- If the mouse re-enters a focused surface while a resume timer is armed, the
  timer is canceled and auto-focus returns to the paused state.

Optional: `auto-focus-attention-resume-on-surface-switch = true`

- If attention is pending and you switch focus to a different pane, Ghostty
  treats that as a "done reading the previous pane" signal and queues the
  resume logic.
- It still will not steal focus while the mouse is inside the newly focused
  pane.

Notes:

- With `focus-follows-mouse = true`, many workflows remain in a perpetual
  `paused(focused+mouse)` state because the cursor is almost always inside some
  pane. For predictable behavior, prefer `focus-follows-mouse = false`.
- Auto-focus prioritizes attention candidates within the current tab first, and
  only falls back to other tabs when the current tab has no candidates.

The attention border itself is rendered by:

- `macos/Sources/Ghostty/Surface View/SurfaceView.swift` `BellBorderOverlay`

## Testing Approach

Ghostty has both Zig unit tests (run by `zig build test`) and macOS UI tests
(XCTest UI tests run through the build system).

### Smart Background Tests

Zig unit tests:

- `zig build test -Dtest-filter=smart_background`
  - Covers determinism and keying behavior in `src/termio/smart_background.zig`

macOS UI tests:

- `zig build xctest -Dxcode-only-testing=GhosttyUITests/GhosttySmartBackgroundUITests`
  - `macos/GhosttyUITests/GhosttySmartBackgroundUITests.swift`
  - Verifies per-pane background color changes by sampling screenshot pixels
    after emitting OSC 7 sequences into each pane.
  - SSH case:
    - Uses `GHOSTTY_UI_TEST_SSH_HOST` (defaults to a known host in tests).
    - Verifies that an untrusted-host OSC 7 still changes the pane tint.

If the SSH host differs on your machine, set:

```sh
GHOSTTY_UI_TEST_SSH_HOST="user@host" zig build xctest -Dxcode-only-testing=GhosttyUITests/GhosttySmartBackgroundUITests
```

### Attention Tests

Zig unit tests:

- `zig build test -Dtest-filter=attention`
  - Focuses on core logic where applicable (and ensures attention-related code
    compiles and basic behavior is covered).

macOS UI tests:

- `zig build xctest -Dxcode-only-testing=GhosttyUITests/GhosttyAttentionUITests`
  - `macos/GhosttyUITests/GhosttyAttentionUITests.swift`
  - Includes a regression test to ensure splitting alone does not trigger
    output-idle attention:
    - `testAttentionOnOutputIdleDoesNotTriggerFromSplitAlone()`
    - It enables `attention-on-output-idle`, creates a split, waits, then
      asserts the attention border did not appear by sampling screenshot pixels.

opencode cross-coverage (attention behavior with SSH + remote output):

- `zig build xctest -Dxcode-only-testing=GhosttyUITests/GhosttyOpencodeE2ETests`

### Running "All" Tests

Zig tests:

```sh
zig build test
```

macOS Xcode tests (includes UI tests):

```sh
zig build xctest
```

To run a single class (recommended during iteration):

```sh
zig build xctest -Dxcode-only-testing=GhosttyUITests/GhosttyAttentionUITests
zig build xctest -Dxcode-only-testing=GhosttyUITests/GhosttySmartBackgroundUITests
```

### Notes on UI Test Reliability

- UI tests require macOS UI testing automation to be allowed for the test runner.
  If you see "Timed out while enabling automation mode", it is an environment/
  permission issue rather than a test failure.
- The tests avoid depending on the inspector UI and instead verify behavior via
  screenshot pixel sampling (background tint) or border color sampling
  (attention border).
