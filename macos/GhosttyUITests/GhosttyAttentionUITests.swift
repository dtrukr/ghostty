//
//  GhosttyAttentionUITests.swift
//  GhosttyUITests
//
//  Created by Codex on 2026-02-06.
//

import AppKit
import Foundation
import XCTest

final class GhosttyAttentionUITests: GhosttyCustomConfigCase {
    private func cdTmp(_ app: XCUIApplication) async throws {
        app.typeText("cd /tmp")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(150))
    }

    private func captureTTY(
        _ app: XCUIApplication,
        timeoutMs: Int = 2000,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> String {
        app.typeText("tty | pbcopy")
        app.typeKey("\n", modifierFlags: [])

        let stepMs = 200
        var waited = 0
        while waited < timeoutMs {
            try await Task.sleep(for: .milliseconds(stepMs))
            let tty = try readPasteboardString(file: file, line: line).trimmingCharacters(in: .whitespacesAndNewlines)
            if tty.hasPrefix("/dev/") { return tty }
            waited += stepMs
        }

        let tty = try readPasteboardString(file: file, line: line).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTFail("Expected tty path on pasteboard, got: \(tty)", file: file, line: line)
        return tty
    }

    private func rgbAtNormalizedPoint(_ image: NSImage, x: CGFloat, y: CGFloat) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return (0, 0, 0, 0)
        }

        // XCUITest uses a top-left origin for normalized coordinates. NSBitmapImageRep uses a
        // bottom-left origin, so invert y.
        let px = Int(max(0, min(CGFloat(cg.width - 1), x * CGFloat(cg.width - 1))))
        let py = Int(max(0, min(CGFloat(cg.height - 1), (1.0 - y) * CGFloat(cg.height - 1))))

        guard let c = image.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else {
            return (0, 0, 0, 0)
        }

        var rr: CGFloat = 0
        var gg: CGFloat = 0
        var bb: CGFloat = 0
        var aa: CGFloat = 0
        c.getRed(&rr, green: &gg, blue: &bb, alpha: &aa)

        return (UInt8(rr * 255), UInt8(gg * 255), UInt8(bb * 255), UInt8(aa * 255))
    }

    private func looksLikeBellBorder(_ c: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool {
        // BellBorderOverlay color is (1.0, 0.8, 0.0) at 0.5 opacity. We don't want to
        // be overly strict, but it should read as "yellow-ish".
        guard c.a > 200 else { return false }
        return c.r >= 110 && c.g >= 90 && c.b <= 160 && c.r >= c.g
    }

    override func setUp() async throws {
        try await super.setUp()

        // Keep this minimal and deterministic:
        // - opt into our goto_attention keybinds (no defaults shipped)
        // - enable bell border so we have a visible signal if debugging manually
        // - disable close confirmation so tests can't get stuck behind prompts
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            keybind = cmd+]=goto_attention:next
            keybind = cmd+[=goto_attention:previous
            """
        )
    }

    @MainActor
    func testAttentionOnOutputIdleDoesNotTriggerFromSplitAlone() async throws {
        // Regression coverage: splitting/resizing should not be treated as "output while
        // unfocused" for attention-on-output-idle purposes. This should require actual
        // output from an unfocused pane (command output, etc.).
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            attention-on-output-idle = 200ms
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create a second split (two panes). This will resize pane A and spawn pane B.
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(600))

        // Ensure pane B is focused (pane A unfocused).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.75)).click()
        try await Task.sleep(for: .milliseconds(200))

        // Wait longer than attention-on-output-idle.
        try await Task.sleep(for: .seconds(2))

        // Sample pixels on pane A's left edge: if the bell border is active, these tend
        // to be yellow-ish.
        let shot = window.screenshot()
        let samples = [
            rgbAtNormalizedPoint(shot.image, x: 0.02, y: 0.45),
            rgbAtNormalizedPoint(shot.image, x: 0.02, y: 0.55),
            rgbAtNormalizedPoint(shot.image, x: 0.02, y: 0.65),
        ]

        XCTAssertFalse(
            samples.contains(where: looksLikeBellBorder),
            "Expected pane A to NOT show attention border from splitting alone. samples=\(samples)"
        )
    }

    @MainActor
    func testAttentionOnOutputIdleWaitsAtLeastConfiguredDuration() async throws {
        // Ensure output-idle attention does not trigger early.
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            # No auto-focus; we want to inspect the unfocused pane border.
            auto-focus-attention = false
            background-opacity = 1.0
            background-blur = 0
            background = #000000
            foreground = #ffffff
            attention-on-output-idle = 1200ms
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create a second split (two panes).
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(600))

        func clickPane(normalizedX: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.75)).click()
        }

        // Focus pane B and capture its PTY.
        clickPane(normalizedX: 0.75)
        try await cdTmp(app)
        let ttyB = try await captureTTY(app)

        // Focus pane A and stream output into pane B for a short burst, then go quiet.
        // This ensures output-idle attention ignores one-off redraws but still
        // triggers for real "work output" bursts.
        clickPane(normalizedX: 0.25)
        try await cdTmp(app)
        try await Task.sleep(for: .milliseconds(200))
        // Keep this burst long enough to be considered "meaningful streaming"
        // output by the output-idle heuristic.
        app.typeText("(for i in 1 2 3 4 5 6 7; do printf x; sleep 0.12; done) > \(ttyB)")
        app.typeKey("\n", modifierFlags: [])

        func samplesForPaneBBorder(_ image: NSImage) -> [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] {
            // BellBorderOverlay uses a 3px stroke. Sample very close to the
            // right edge of the window so we actually hit the border pixels.
            return [
                rgbAtNormalizedPoint(image, x: 0.999, y: 0.35),
                rgbAtNormalizedPoint(image, x: 0.999, y: 0.50),
                rgbAtNormalizedPoint(image, x: 0.999, y: 0.65),
            ]
        }

        // Before the configured quiet period elapses, there should be no attention border.
        try await Task.sleep(for: .milliseconds(700))
        var shot = window.screenshot()
        let earlySamples = samplesForPaneBBorder(shot.image)
        XCTAssertFalse(
            earlySamples.contains(where: looksLikeBellBorder),
            "Expected pane B to NOT show attention border before quiet period. samples=\(earlySamples)"
        )

        // After the quiet period, the attention border should appear.
        try await Task.sleep(for: .milliseconds(1600))
        shot = window.screenshot()
        let lateSamples = samplesForPaneBBorder(shot.image)
        XCTAssertTrue(
            lateSamples.contains(where: looksLikeBellBorder),
            "Expected pane B to show attention border after quiet period. samples=\(lateSamples)"
        )
    }

    @MainActor
    func testAttentionOnOutputIdleIgnoresSingleBurstRedrawLikeRemoteTmuxRefresh() async throws {
        // Regression coverage: some background panes (notably SSH+tmux) can emit
        // occasional redraw bursts (e.g. tmux refresh/status updates). Those
        // should not be treated as "work finished" for attention-on-output-idle.
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border
            auto-focus-attention = false
            attention-on-output-idle = 1500ms
            focus-follows-mouse = false

            # Deterministic split creation.
            keybind = cmd+d=new_split:right
            keybind = cmd+shift+d=new_split:down

            # Make screenshots easier to sample.
            background-opacity = 1.0
            background-blur = 0
            background = #000000
            foreground = #ffffff
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        func clickPane(_ x: CGFloat, _ y: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
        }

        // Create a 2x2 grid of panes.
        window.typeKey("d", modifierFlags: .command) // split right
        try await Task.sleep(for: .milliseconds(500))
        clickPane(0.25, 0.25) // top-left
        window.typeKey("d", modifierFlags: [.command, .shift]) // split down (left column)
        try await Task.sleep(for: .milliseconds(500))
        clickPane(0.75, 0.25) // top-right
        window.typeKey("d", modifierFlags: [.command, .shift]) // split down (right column)
        try await Task.sleep(for: .milliseconds(700))

        // Preflight: make sure SSH works without prompting.
        let host = uiTestSSHHost()
        let sshBase = "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \(host)"
        let sshOK = try await runLocalCommandAndCaptureExitCode(app, cmd: "\(sshBase) 'true'")
        guard sshOK == 0 else {
            throw XCTSkip("SSH preflight failed (need key-based auth): exit=\(sshOK)")
        }

        // Start SSH + tmux in each pane, each using a dedicated tmux server name.
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let panes: [(name: String, x: CGFloat, y: CGFloat)] = [
            ("tl", 0.25, 0.25),
            ("tr", 0.75, 0.25),
            ("bl", 0.25, 0.75),
            ("br", 0.75, 0.75),
        ]
        let servers = panes.map { "ghostty_ui_tmux_\(id)_\($0.name)" }

        for (i, p) in panes.enumerated() {
            clickPane(p.x, p.y)
            // Start an interactive SSH session (already preflighted).
            app.typeText("ssh -tt -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \(host)\n")
            try await Task.sleep(for: .seconds(2))
            // Start tmux with a dedicated server name so we can poke it from outside.
            app.typeText("tmux -L \(servers[i]) new -A -s ghostty_test\n")
            try await Task.sleep(for: .seconds(1))
        }

        // Focus top-left pane so the other three are unfocused.
        clickPane(0.25, 0.25)
        try await Task.sleep(for: .milliseconds(300))

        // Trigger a single redraw burst to each unfocused tmux client from outside.
        for server in [servers[1], servers[2], servers[3]] {
            let rc = try await runLocalCommandAndCaptureExitCode(app, cmd: "\(sshBase) 'tmux -L \(server) refresh-client -S'")
            XCTAssertEqual(rc, 0, "Expected tmux refresh-client to succeed for server \(server), rc=\(rc)")
        }

        // Wait longer than attention-on-output-idle. If we incorrectly treat a single
        // redraw burst as actionable output, these panes will get an attention mark.
        try await Task.sleep(for: .seconds(3))

        let shot = window.screenshot()
        let samples: [(r: UInt8, g: UInt8, b: UInt8, a: UInt8)] = [
            // Left edge (top-left / bottom-left).
            rgbAtNormalizedPoint(shot.image, x: 0.001, y: 0.25),
            rgbAtNormalizedPoint(shot.image, x: 0.001, y: 0.75),
            // Right edge (top-right / bottom-right).
            rgbAtNormalizedPoint(shot.image, x: 0.999, y: 0.25),
            rgbAtNormalizedPoint(shot.image, x: 0.999, y: 0.75),
        ]

        XCTAssertFalse(
            samples.contains(where: looksLikeBellBorder),
            "Expected no attention border from single redraw bursts in unfocused SSH+tmux panes. samples=\(samples)"
        )

        // Best-effort cleanup: kill tmux servers (ignore failures).
        for server in servers {
            _ = try? await runLocalCommandAndCaptureExitCode(app, cmd: "\(sshBase) 'tmux -L \(server) kill-server'")
        }
    }

    @MainActor
    func testAttentionOnOutputIdleIgnoresShortBurstLikeLsInUnfocusedPane() async throws {
        // Repro coverage: short command output in background panes (e.g. `ls` in
        // SSH/tmux) should not be treated as "work finished" for output-idle
        // attention. This prevents spurious attention marks from quick redraws.
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border
            auto-focus-attention = false
            attention-on-output-idle = 1500ms
            focus-follows-mouse = false

            background-opacity = 1.0
            background-blur = 0
            background = #000000
            foreground = #ffffff
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create a second split (two panes).
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(600))

        func clickPane(normalizedX: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.75)).click()
        }

        // Focus pane B and capture its PTY so we can write output into it while unfocused.
        clickPane(normalizedX: 0.75)
        try await cdTmp(app)
        let ttyB = try await captureTTY(app)

        // Focus pane A. Pane B is now unfocused.
        clickPane(normalizedX: 0.25)
        try await cdTmp(app)
        try await Task.sleep(for: .milliseconds(200))

        // Emit a short burst of output into pane B (multiple small writes over <500ms).
        app.typeText("(for i in 1 2 3 4 5 6 7 8 9 10; do printf x > \(ttyB); sleep 0.02; done)")
        app.typeKey("\n", modifierFlags: [])

        // Wait longer than attention-on-output-idle and then ensure pane B doesn't get a bell border.
        try await Task.sleep(for: .seconds(3))

        let shot = window.screenshot()
        // Pane B is on the right edge. Sample close to right edge for border pixels.
        let samples = [
            rgbAtNormalizedPoint(shot.image, x: 0.999, y: 0.35),
            rgbAtNormalizedPoint(shot.image, x: 0.999, y: 0.50),
            rgbAtNormalizedPoint(shot.image, x: 0.999, y: 0.65),
        ]
        XCTAssertFalse(
            samples.contains(where: looksLikeBellBorder),
            "Expected short burst output to NOT trigger attention-on-output-idle. samples=\(samples)"
        )
    }

    @MainActor
    func testAutoFocusAttentionOnOutputIdleFocusesUnfocusedSplit() async throws {
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            auto-focus-attention = true
            auto-focus-attention-idle = 50ms
            auto-focus-attention-resume-delay = 0ms
            attention-on-output-idle = 250ms
            attention-debug = true
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create a second split (two panes).
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(500))

        func clickPane(normalizedX: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.75)).click()
        }

        // Focus pane B and capture its PTY.
        clickPane(normalizedX: 0.75)
        try await cdTmp(app)
        app.typeText("tty | pbcopy")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(250))
        let ttyB = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyB.hasPrefix("/dev/"), "Expected tty path on pasteboard, got: \(ttyB)")

        // Focus pane A and stream some output into pane B, then stop.
        clickPane(normalizedX: 0.25)
        try await cdTmp(app)
        app.typeText("(for i in 1 2 3 4 5; do printf 'x'; sleep 0.2; done) > \(ttyB) &")
        app.typeKey("\n", modifierFlags: [])

        // Wait long enough for output-idle attention to trigger. While we're
        // still focused in pane A, auto-focus-attention must not steal focus.
        try await Task.sleep(for: .seconds(3))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyWhileFocused = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(ttyWhileFocused, ttyB, "Expected auto-focus to remain paused while pane A is focused, but we ended up in pane B")

        // Move focus away from the terminal surface by clicking the window titlebar.
        // This should resume auto-focus immediately and focus pane B.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        try await Task.sleep(for: .seconds(2))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyAfterResume = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyAfterResume, ttyB, "Expected output-idle attention auto-focus to focus pane B (\(ttyB)) after unfocus, got \(ttyAfterResume)")
    }

    @MainActor
    func testAutoFocusAttentionDoesNotImmediatelyCycleAwayAfterFocus() async throws {
        // Regression coverage: if multiple attention marks happen close together,
        // stale auto-focus work items must not cause immediate focus cycling.
        //
        // This test creates 3 tabs, rings tab 3 then tab 2 in quick succession
        // (tab 2 is the most recent), and verifies we end up focused on tab 2.
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            auto-focus-attention = true
            auto-focus-attention-idle = 200ms
            auto-focus-attention-resume-delay = 0ms

            # Default is true, but make the behavior explicit for this test:
            attention-clear-on-focus = true
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create tab 2 and tab 3.
        window.typeKey("t", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))
        window.typeKey("t", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))

        // Capture tty paths for tab 2 and tab 3.
        window.typeKey("2", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))
        try await cdTmp(app)
        let ttyTab2 = try await captureTTY(app)

        window.typeKey("3", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))
        try await cdTmp(app)
        let ttyTab3 = try await captureTTY(app)

        // Back to tab 1.
        window.typeKey("1", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))
        try await cdTmp(app)
        let ttyTab1 = try await captureTTY(app)

        // Ring tab 3 then tab 2 shortly after. Tab 2 is most recent and should
        // be the final auto-focused surface.
        app.typeText("(sleep 0.10; printf '\\a' > \(ttyTab3); sleep 0.05; printf '\\a' > \(ttyTab2)) &\n")

        // Wait for the bells to fire and idle threshold to elapse. While we're
        // still focused in tab 1, auto-focus-attention must not steal focus.
        try await Task.sleep(for: .seconds(2))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyWhileFocused = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyWhileFocused, ttyTab1, "Expected auto-focus to remain paused while tab 1 is focused (\(ttyTab1)), got \(ttyWhileFocused)")

        // Move focus away from the terminal surface by clicking the window titlebar.
        // Auto-focus should resume immediately and focus tab 2 (the most recent bell).
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        try await Task.sleep(for: .seconds(2))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyAfterResume = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyAfterResume, ttyTab2, "Expected auto-focus to end on tab 2 (\(ttyTab2)) after unfocus, got \(ttyAfterResume)")
    }

    @MainActor
    func testAutoFocusDoesNotStealFocusAwayFromJustAutoFocusedTab() async throws {
        // Regression coverage: if auto-focus brings us to a tab due to attention,
        // subsequent attention in other tabs must not immediately steal focus away
        // while the user is reading (even if they don't move the mouse).
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            auto-focus-attention = true
            auto-focus-attention-idle = 200ms
            auto-focus-attention-resume-delay = 0ms
            auto-focus-attention-resume-on-surface-switch = true
            attention-clear-on-focus = true
            attention-debug = true
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create tab 2.
        window.typeKey("t", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))

        // Capture tty for tab 1 and tab 2.
        window.typeKey("1", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyTab1 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyTab1.hasPrefix("/dev/"), "Expected tty path for tab 1, got: \(ttyTab1)")

        window.typeKey("2", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyTab2 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyTab2.hasPrefix("/dev/"), "Expected tty path for tab 2, got: \(ttyTab2)")

        // Back to tab 1.
        window.typeKey("1", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))
        try await cdTmp(app)

        // Ring tab 2 while tab 1 is focused. Auto-focus is paused while "reading"
        // the focused surface. We'll then signal "not interested" by moving the
        // mouse out of the focused pane, which allows auto-focus to run.
        app.typeText("(sleep 0.10; printf '\\a' > \(ttyTab2)) &\n")
        try await Task.sleep(for: .milliseconds(1200))

        let overlay = app.otherElements["Ghostty.Attention.Overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 2), "Expected attention overlay to exist when attention-debug=true")
        XCTAssertNotEqual(overlay.label, "idle", "Expected auto-focus to be pending/paused after ringing tab 2. overlay=\(overlay.label)")

        // Signal "not interested" by moving mouse focus out of the surface.
        let dragStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let dragEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.20))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        try await Task.sleep(for: .seconds(3))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyAfterFocus = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        let overlayText = overlay.exists ? overlay.label : "<no overlay>"
        XCTAssertEqual(ttyAfterFocus, ttyTab2, "Expected auto-focus to move to tab 2 (\(ttyTab2)), got \(ttyAfterFocus). overlay=\(overlayText)")

        // Ensure mouse is outside the focused surface to reproduce the bug where
        // auto-focus could steal focus again even without user interaction.
        let dragStart2 = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        let dragEnd2 = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -0.20))
        dragStart2.press(forDuration: 0.05, thenDragTo: dragEnd2)
        try await Task.sleep(for: .milliseconds(200))

        // Now ring tab 1 while we're reading tab 2. Auto-focus must NOT steal focus back.
        app.typeText("printf '\\a' > \(ttyTab1)\n")
        try await Task.sleep(for: .seconds(2))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyStillTab2 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            ttyStillTab2,
            ttyTab2,
            "Expected auto-focus to remain on tab 2 while reading; got \(ttyStillTab2). overlay=\(overlay.label)"
        )

        // Signal "done reading" by switching to another surface (resume-on-surface-switch).
        // This clears the focus lock and allows auto-focus to run immediately.
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .seconds(2))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyAfterResume = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            ttyAfterResume,
            ttyTab1,
            "Expected auto-focus to resume and focus tab 1 (\(ttyTab1)) after unfocus, got \(ttyAfterResume). overlay=\(overlay.label)"
        )
    }

    @MainActor
    func testAutoFocusAttentionResumesOnUnfocusAndPrefersCurrentTabCandidate() async throws {
        // Behavior:
        // - While a surface is focused, auto-focus-attention must not steal focus.
        // - Once focus leaves the terminal surface, auto-focus should resume immediately.
        // - When resuming, prefer attention candidates within the current tab first.
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            auto-focus-attention = true
            auto-focus-attention-idle = 250ms
            auto-focus-attention-resume-delay = 0ms

            # Make sure attention marks clear when we focus them so the "prefer current tab"
            # portion of this test doesn't leave stale candidates behind.
            attention-clear-on-focus = true

            attention-debug = true
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        func clickPane(_ x: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.75)).click()
        }

        // Split tab 1 into two panes and capture pane B's PTY.
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(500))

        clickPane(0.75)
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyPaneB = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyPaneB.hasPrefix("/dev/"), "Expected tty path for pane B, got: \(ttyPaneB)")

        // Create tab 2 and capture its PTY.
        window.typeKey("t", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyTab2 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyTab2.hasPrefix("/dev/"), "Expected tty path for tab 2, got: \(ttyTab2)")

        // Back to tab 1, focus pane A.
        window.typeKey("1", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        clickPane(0.25)
        try await Task.sleep(for: .milliseconds(200))
        try await cdTmp(app)

        // Ring pane B (current tab) and then ring tab 2 shortly after. Even though tab 2's
        // bell is more recent, auto-focus should prefer pane B once it resumes.
        app.typeText("(sleep 0.10; printf '\\a' > \(ttyPaneB); sleep 0.05; printf '\\a' > \(ttyTab2)) &\n")
        try await Task.sleep(for: .seconds(2))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyWhileFocused = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertNotEqual(
            ttyWhileFocused,
            ttyPaneB,
            "Expected auto-focus to remain paused while pane A is focused, but we ended up in pane B"
        )

        // Unfocus the terminal surface by clicking the window titlebar to resume auto-focus.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        try await Task.sleep(for: .seconds(2))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyAfterResume = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(
            ttyAfterResume,
            ttyPaneB,
            "Expected auto-focus to prefer current tab candidate (pane B \(ttyPaneB)) after unfocus, got \(ttyAfterResume)"
        )
    }

    @MainActor
    func testAutoFocusAttentionResumeDelayIsHonored() async throws {
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            auto-focus-attention = true
            auto-focus-attention-idle = 50ms
            # Use a longer delay to reduce flakiness from UI test scheduling overhead.
            auto-focus-attention-resume-delay = 2500ms
            attention-debug = true
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create a second split (two panes).
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(500))

        func clickPane(_ x: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.75)).click()
        }

        // Capture tty paths for pane A and pane B.
        clickPane(0.25)
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyA = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyA.hasPrefix("/dev/"), "Expected tty path for pane A, got: \(ttyA)")

        clickPane(0.75)
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyB = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyB.hasPrefix("/dev/"), "Expected tty path for pane B, got: \(ttyB)")

        // Back to pane A.
        clickPane(0.25)
        try await Task.sleep(for: .milliseconds(200))
        try await cdTmp(app)

        // Ring pane B. While we're focused in pane A, auto-focus must remain paused.
        app.typeText("printf '\\a' > \(ttyB)\n")
        try await Task.sleep(for: .milliseconds(600))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyWhileFocused = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyWhileFocused, ttyA, "Expected auto-focus to remain paused while pane A is focused (\(ttyA)), got \(ttyWhileFocused)")

        // Move mouse focus outside of the pane by dragging the cursor out of the surface.
        // (Clicking the titlebar is not reliable when the terminal view extends into it.)
        let dragStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75))
        let dragEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.02))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)

        let overlay = app.otherElements["Ghostty.Attention.Overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 2), "Expected attention overlay to exist when attention-debug=true")
        XCTAssertTrue(overlay.label.contains("resume in 2500ms"), "Expected overlay to show resume delay, got: \(overlay.label)")

        // Before the resume delay elapses, we should not have focused pane B yet.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(overlay.label.contains("resume in 2500ms"), "Expected overlay to still be waiting, got: \(overlay.label)")

        // After the delay, we should auto-focus to pane B. Don't assert on overlay
        // text here since focus state changes can legitimately update it.
        try await Task.sleep(for: .milliseconds(2800))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyAfter = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyAfter, ttyB, "Expected auto-focus to focus pane B (\(ttyB)) after resume delay, got \(ttyAfter)")
    }

    @MainActor
    func testAutoFocusAttentionResumesOnSurfaceSwitchWhenEnabled() async throws {
        // When enabled, switching to a different surface should resume a pending
        // auto-focus-attention action (even though we're still focused in a pane).
        //
        // With the "reading" gate, auto-focus must never steal focus while the
        // mouse is inside the focused surface. This test verifies we do not
        // switch away immediately just because focus changed.
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            auto-focus-attention = true
            auto-focus-attention-idle = 50ms
            auto-focus-attention-resume-delay = 0ms
            auto-focus-attention-resume-on-surface-switch = true

            # Keep focus changes deterministic for this test.
            focus-follows-mouse = false

            attention-debug = true
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        func click(_ x: CGFloat, _ y: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
        }

        // Make 3 panes: split right, then split down on the left side.
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(500))
        click(0.25, 0.75) // focus left
        window.typeKey("D", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .milliseconds(600))

        // Capture ttys for:
        // - pane A (top-left) = attention target
        // - pane B (right) = switch-to surface
        // - pane C (bottom-left) = reading surface when attention arrives
        click(0.25, 0.25) // top-left
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyA = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyA.hasPrefix("/dev/"), "Expected tty path for pane A, got: \(ttyA)")

        click(0.75, 0.75) // right
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyB = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyB.hasPrefix("/dev/"), "Expected tty path for pane B, got: \(ttyB)")

        click(0.25, 0.75) // bottom-left
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyC = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyC.hasPrefix("/dev/"), "Expected tty path for pane C, got: \(ttyC)")

        // While we're focused in pane C, ring pane A (unfocused) to create a pending attention mark.
        app.typeText("printf '\\a' > \(ttyA)\n")
        try await Task.sleep(for: .milliseconds(400))

        // Confirm we are still in pane C (paused while focused).
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyWhileFocused = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyWhileFocused, ttyC, "Expected to remain in pane C while attention is pending")

        // Switch focus to a different surface (pane B). With resume-on-surface-switch enabled,
        // auto-focus must still remain paused while we're reading pane B.
        click(0.75, 0.75)
        try await Task.sleep(for: .seconds(2))

        // Verify we're still in pane B (auto-focus is paused while reading).
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyStillB = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyStillB, ttyB, "Expected to still be reading pane B while attention is pending")
    }

    @MainActor
    func testAutoFocusAttentionResumeDelayIsDebouncedAndPausesWhileReading() async throws {
        // Behavior:
        // - Mouse exit arms a resume countdown (auto-focus-attention-resume-delay).
        // - Any interaction and/or re-entering a pane pauses the countdown entirely.
        // - Once the mouse leaves again and we remain quiet for the full delay,
        //   auto-focus should execute.
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            auto-focus-attention = true
            auto-focus-attention-idle = 50ms
            auto-focus-attention-resume-delay = 1500ms

            focus-follows-mouse = false
            attention-debug = true
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        func click(_ x: CGFloat, _ y: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
        }

        // Make 3 panes: split right, then split down on the left side.
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(500))
        click(0.25, 0.75) // focus left
        window.typeKey("D", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .milliseconds(600))

        // Capture ttys for:
        // - pane A (top-left) = attention target
        // - pane B (right) = "work" pane during countdown
        // - pane C (bottom-left) = reading surface when attention arrives
        click(0.25, 0.25) // top-left
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyA = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)

        click(0.75, 0.75) // right
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyB = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)

        click(0.25, 0.75) // bottom-left
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyC = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)

        XCTAssertTrue(ttyA.hasPrefix("/dev/"))
        XCTAssertTrue(ttyB.hasPrefix("/dev/"))
        XCTAssertTrue(ttyC.hasPrefix("/dev/"))

        // Ring pane A while we're reading pane C. Auto-focus must remain paused.
        app.typeText("printf '\\a' > \(ttyA)\n")
        try await Task.sleep(for: .milliseconds(400))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyWhileReading = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyWhileReading, ttyC)

        // Mouse-exit pane C to arm the resume delay.
        let dragStartC = window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75))
        let dragEndOutside = window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: -0.20))
        dragStartC.press(forDuration: 0.05, thenDragTo: dragEndOutside)

        // Quickly click into pane B to do work. This should pause auto-focus entirely,
        // even if the originally-armed resume delay elapses.
        click(0.75, 0.75)
        try await Task.sleep(for: .seconds(2))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyStillWorking = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyStillWorking, ttyB, "Expected to still be in pane B; auto-focus should be paused while reading/working")

        // Now signal disinterest by moving mouse out of pane B and staying quiet.
        let dragStartB = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.75))
        dragStartB.press(forDuration: 0.05, thenDragTo: dragEndOutside)
        try await Task.sleep(for: .seconds(3))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyAfter = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyAfter, ttyA, "Expected auto-focus to eventually focus pane A after mouse exit + quiet period, got \(ttyAfter)")
    }

    @MainActor
    func testAgentStatusOverlaySummarizesProvidersAcrossSurfaces() async throws {
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            # Agent status overlay is debug-only (tied to attention-debug).
            attention-debug = true
            agent-status-stable = 200ms

            focus-follows-mouse = false
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        func click(_ x: CGFloat, _ y: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
        }

        // Make 3 panes: split right, then split down on the left side.
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(500))
        click(0.25, 0.75) // focus left
        window.typeKey("D", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .milliseconds(600))

        // Set each pane's title to indicate the provider (this is how users typically
        // see "codex --model ..." in the tab title), then emit viewport text that
        // matches AoE's heuristics for running/waiting/idle.
        func setTitleCodex() async throws {
            app.typeText("printf '\\\\e]0;codex --model gpt\\\\a'\n")
            try await Task.sleep(for: .milliseconds(150))
        }

        // Pane A (top-left): Running.
        click(0.25, 0.25)
        try await cdTmp(app)
        try await setTitleCodex()
        app.typeText("printf 'codex thinking... esc to interrupt\\n'\n")

        // Pane B (right): Waiting.
        click(0.75, 0.75)
        try await cdTmp(app)
        try await setTitleCodex()
        app.typeText("printf 'codex>\\n'\n")

        // Pane C (bottom-left): Idle.
        click(0.25, 0.75)
        try await cdTmp(app)
        try await setTitleCodex()
        app.typeText("printf 'codex hello\\n'\n")

        // Allow the polling interval + stable window to elapse.
        try await Task.sleep(for: .seconds(2))

        let overlay = app.otherElements["Ghostty.AgentStatus.Overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 2), "Expected agent status overlay to exist when attention-debug=true")

        // Expect the codex provider line to summarize 3 panes: 1 waiting, 1 idle, 1 running.
        XCTAssertTrue(overlay.label.lowercased().contains("codex"), "Expected overlay to mention codex, got: \(overlay.label)")
        XCTAssertTrue(overlay.label.contains("⏳1"), "Expected overlay to include waiting count, got: \(overlay.label)")
        XCTAssertTrue(overlay.label.contains("💤1"), "Expected overlay to include idle count, got: \(overlay.label)")
        XCTAssertTrue(overlay.label.contains("🏃1"), "Expected overlay to include running count, got: \(overlay.label)")
    }

    @MainActor
    func testAutoFocusAttentionPausesWhileReadingFocusedPaneAndResumesOnMouseExit() async throws {
        // Behavior:
        // - Auto-focus-attention should not steal focus while a pane is focused (user is reading).
        // - Once the user moves mouse focus outside the pane, resume immediately (no idle wait).
        // - When resuming, prefer candidates in the current tab first; if none, then other tabs.
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            auto-focus-attention = true
            auto-focus-attention-idle = 50ms
            auto-focus-attention-resume-delay = 0ms
            attention-clear-on-focus = true
            attention-debug = true
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        func clickPane(_ x: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.75)).click()
        }

        // Split tab 1 into two panes and capture pane A/B PTYs.
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(500))

        clickPane(0.25)
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyA = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyA.hasPrefix("/dev/"), "Expected tty path for pane A, got: \(ttyA)")

        clickPane(0.75)
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyB = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyB.hasPrefix("/dev/"), "Expected tty path for pane B, got: \(ttyB)")

        // Create tab 2 and capture its PTY.
        window.typeKey("t", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyTab2 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyTab2.hasPrefix("/dev/"), "Expected tty path for tab 2, got: \(ttyTab2)")

        // Back to tab 1, focus pane A.
        window.typeKey("1", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        clickPane(0.25)
        try await Task.sleep(for: .milliseconds(150))
        try await cdTmp(app)

        // Ring pane B (current tab) and then ring tab 2 slightly after.
        app.typeText("(sleep 0.10; printf '\\a' > \(ttyB); sleep 0.05; printf '\\a' > \(ttyTab2)) &\n")
        try await Task.sleep(for: .seconds(2))

        // While pane A is focused, auto-focus must not steal focus.
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyWhileFocused = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyWhileFocused, ttyA, "Expected auto-focus to remain paused while pane A is focused (\(ttyA)), got \(ttyWhileFocused)")

        let overlay = app.otherElements["Ghostty.Attention.Overlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 2), "Expected attention overlay to exist when attention-debug=true")

        // Signal "not interested" by moving mouse focus out of pane A to allow
        // auto-focus to run. It should prefer pane B in the current tab.
        let dragStartA = window.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75))
        // Use a point well outside the window to guarantee the cursor leaves the surface.
        let dragEndA = window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: -0.20))
        dragStartA.press(forDuration: 0.05, thenDragTo: dragEndA)
        try await Task.sleep(for: .seconds(2))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyAfterResume1 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyAfterResume1, ttyB, "Expected auto-focus to prefer current tab candidate pane B (\(ttyB)), got \(ttyAfterResume1). overlay=\(overlay.label)")

        // While reading pane B, ring tab 2 again. Auto-focus must remain paused.
        app.typeText("printf '\\a' > \(ttyTab2)\n")
        try await Task.sleep(for: .seconds(2))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyStillReading = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyStillReading, ttyB, "Expected auto-focus to remain paused while reading focused pane B (\(ttyB)), got \(ttyStillReading)")

        // Signal "not interested" by moving mouse focus out of pane B.
        let dragStart = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.75))
        let dragEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: -0.20))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
        try await Task.sleep(for: .seconds(2))

        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyAfterResume2 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyAfterResume2, ttyTab2, "Expected auto-focus to resume and focus tab 2 (\(ttyTab2)) after mouse exit, got \(ttyAfterResume2)")
    }

    @MainActor
    func testGotoAttentionFocusesUnfocusedSplitWithBell() async throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")

        // Ensure the terminal has focus by clicking in the lower region of the window.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create a second split (two panes).
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .seconds(1))

        func clickPane(normalizedX: CGFloat) {
            // We don't have stable per-split accessibility elements, so we
            // focus splits by clicking inside the window content area.
            window.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.75)).click()
        }

        // Focus pane B and capture its PTY path via pbcopy.
        clickPane(normalizedX: 0.75)
        try await cdTmp(app)
        app.typeText("tty | pbcopy")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(250))

        let ttyB = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyB.hasPrefix("/dev/"), "Expected tty path on pasteboard, got: \(ttyB)")

        // Focus pane A and trigger a bell in pane B (unfocused) by writing to its PTY.
        clickPane(normalizedX: 0.25)
        try await cdTmp(app)
        // Important: we want the shell to receive `printf '\a'` (BEL).
        app.typeText("(sleep 1; printf '\\a' > \(ttyB)) &")
        app.typeKey("\n", modifierFlags: [])

        // Allow the bell to fire.
        try await Task.sleep(for: .milliseconds(1500))

        // Cycle to the most recent attention surface (pane B).
        app.typeKey("]", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))

        // Verify pane B is focused by re-copying tty from the *currently focused* pane.
        app.typeText("tty | pbcopy")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(250))

        let ttyAfter = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyAfter, ttyB, "Expected goto_attention to focus pane B (\(ttyB)), got \(ttyAfter)")
    }

    @MainActor
    func testGotoAttentionFocusesAcrossTabs() async throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")

        // Ensure the terminal has focus by clicking in the lower region of the window.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create a second tab.
        window.typeKey("t", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))

        // Switch to tab 2 and capture its PTY via pbcopy.
        window.typeKey("2", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        try await cdTmp(app)
        app.typeText("tty | pbcopy")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(250))

        let ttyTab2 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyTab2.hasPrefix("/dev/"), "Expected tty path on pasteboard, got: \(ttyTab2)")

        // Switch back to tab 1.
        window.typeKey("1", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        try await cdTmp(app)

        // Trigger a bell in tab 2 (unfocused) by writing to its PTY from tab 1.
        app.typeText("(sleep 1; printf '\\a' > \(ttyTab2)) &")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(1500))

        // Cycle to the most recent attention surface (which should be in tab 2).
        window.typeKey("]", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))

        // Verify we are now focused in tab 2 by re-copying tty from the focused pane.
        app.typeText("tty | pbcopy")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(250))

        let ttyAfter = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyAfter, ttyTab2, "Expected goto_attention to focus tab 2 (\(ttyTab2)), got \(ttyAfter)")
    }

    @MainActor
    func testGotoAttentionCyclesAcrossThreeTabs() async throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create two more tabs so we have 3 total.
        window.typeKey("t", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        window.typeKey("t", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))

        func captureTTYForTab(_ tabIndex: String) async throws -> String {
            window.typeKey(tabIndex, modifierFlags: .command)
            try await Task.sleep(for: .milliseconds(300))
            try await cdTmp(app)

            app.typeText("tty | pbcopy")
            app.typeKey("\n", modifierFlags: [])
            try await Task.sleep(for: .milliseconds(250))

            let tty = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(tty.hasPrefix("/dev/"), "Expected tty path on pasteboard, got: \(tty)")
            return tty
        }

        let tty1 = try await captureTTYForTab("1")
        let tty2 = try await captureTTYForTab("2")
        let tty3 = try await captureTTYForTab("3")
        XCTAssertNotEqual(tty1, tty2)
        XCTAssertNotEqual(tty2, tty3)

        // From tab 1, ring bells into tab 2 then tab 3 so tab 3 is most recent.
        window.typeKey("1", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        try await cdTmp(app)
        app.typeText("(sleep 1; printf '\\a' > \(tty2)) &")
        app.typeKey("\n", modifierFlags: [])
        app.typeText("(sleep 2; printf '\\a' > \(tty3)) &")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(2600))

        // cmd+] should go to tab 3, then cmd+] again should go to tab 2.
        window.typeKey("]", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        app.typeText("tty | pbcopy")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(250))
        let ttyAfter1 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyAfter1, tty3, "Expected first goto_attention to focus tab 3")

        window.typeKey("]", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        app.typeText("tty | pbcopy")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(250))
        let ttyAfter2 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyAfter2, tty2, "Expected second goto_attention to focus tab 2")
    }

    private func readPasteboardString(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let s = NSPasteboard.general.string(forType: .string) else {
            XCTFail("Pasteboard did not contain a string", file: file, line: line)
            throw XCTSkip("Pasteboard empty")
        }
        return s
    }

    private func runLocalCommandAndCaptureExitCode(
        _ app: XCUIApplication,
        cmd: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Int {
        app.typeText("\(cmd); echo $? | pbcopy")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(400))

        let s = try readPasteboardString(file: file, line: line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let code = Int(s) else {
            XCTFail("Expected exit code on pasteboard, got: \(s)", file: file, line: line)
            return 999
        }
        return code
    }

    // opencode E2E coverage lives in GhosttyOpencodeE2ETests so it can opt out
    // of per-appearance duplication (light/dark) and be less flaky.
}
