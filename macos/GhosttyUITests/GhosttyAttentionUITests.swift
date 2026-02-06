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
    func testAutoFocusAttentionOnOutputIdleFocusesUnfocusedSplit() async throws {
        try updateConfig(
            """
            title = "GhosttyAttentionUITests"
            confirm-close-surface = false

            bell-features = border

            auto-focus-attention = true
            auto-focus-attention-idle = 50ms
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

        // Wait long enough for:
        // - the output to finish (~1s)
        // - the quiet period (250ms)
        // - the user-idle threshold (50ms)
        try await Task.sleep(for: .seconds(3))

        // If auto-focus-attention worked, we should now be focused in pane B.
        app.typeText("tty | pbcopy")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(250))

        let ttyAfter = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(ttyAfter, ttyB, "Expected output-idle attention auto-focus to focus pane B (\(ttyB)), got \(ttyAfter)")
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
