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
        app.typeText("tty | pbcopy")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(250))
        let ttyB = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyB.hasPrefix("/dev/"), "Expected tty path on pasteboard, got: \(ttyB)")

        // Focus pane A and write a single byte into pane B, then go quiet.
        clickPane(normalizedX: 0.25)
        try await cdTmp(app)
        try await Task.sleep(for: .milliseconds(200))
        app.typeText("printf x > \(ttyB)")
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
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyTab2 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyTab2.hasPrefix("/dev/"), "Expected tty path for tab 2, got: \(ttyTab2)")

        window.typeKey("3", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyTab3 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyTab3.hasPrefix("/dev/"), "Expected tty path for tab 3, got: \(ttyTab3)")

        // Back to tab 1.
        window.typeKey("1", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(250))
        try await cdTmp(app)
        app.typeText("tty | pbcopy\n")
        try await Task.sleep(for: .milliseconds(250))
        let ttyTab1 = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(ttyTab1.hasPrefix("/dev/"), "Expected tty path for tab 1, got: \(ttyTab1)")

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

    // opencode E2E coverage lives in GhosttyOpencodeE2ETests so it can opt out
    // of per-appearance duplication (light/dark) and be less flaky.
}
