//
//  GhosttySmartBackgroundUITests.swift
//  GhosttyUITests
//
//  Created by Codex on 2026-02-06.
//

import AppKit
import Foundation
import XCTest

final class GhosttySmartBackgroundUITests: GhosttyCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()

        // Make the tint visually strong and make the rendered output easier
        // to sample from a screenshot.
        try updateConfig(
            """
            title = "GhosttySmartBackgroundUITests"
            confirm-close-surface = false

            # Ensure an opaque, flat background.
            background-opacity = 1.0
            background-blur = 0

            # Avoid any OS notification permission prompts during UI tests.
            desktop-notifications = false

            smart-background = true
            smart-background-key = pwd
            smart-background-strength = 1.0
            """
        )
    }

    private func readPasteboardString(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
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

    private func osc7(host: String, path: String) -> String {
        // OSC 7: ESC ] 7 ; file://<host><path> BEL
        // Use hex escapes so the shell doesn't interpret backslashes.
        #"printf '\x1b]7;file://\#(host)\#(path)\x07'"#
    }

    private func osc7(path: String) -> String {
        // Host is optional. Omitting it avoids hostname validation flakiness in tests.
        #"printf '\x1b]7;file://\#(path)\x07'"#
    }

    private func osc7TmuxPassthrough(host: String, path: String) -> String {
        // When inside tmux, some OSC sequences can be filtered. Wrap OSC 7 in a
        // tmux passthrough DCS so it reliably reaches the outer terminal:
        //   DCS tmux ; ESC <payload with doubled ESC> ST
        #"printf '\x1bPtmux;\x1b\x1b]7;file://\#(host)\#(path)\x07\x1b\\'"#
    }

    private func osc7TmuxPassthrough(path: String) -> String {
        // Like osc7(path:), but wrapped for tmux passthrough.
        #"printf '\x1bPtmux;\x1b\x1b]7;file://\#(path)\x07\x1b\\'"#
    }

    private func clearScreen() -> String {
        #"printf '\x1b[2J\x1b[H'"#
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

    private func colorDistance(_ a: (UInt8, UInt8, UInt8), _ b: (UInt8, UInt8, UInt8)) -> Double {
        let dr = Double(Int(a.0) - Int(b.0))
        let dg = Double(Int(a.1) - Int(b.1))
        let db = Double(Int(a.2) - Int(b.2))
        return (dr * dr + dg * dg + db * db).squareRoot()
    }

    @MainActor
    func testSmartBackgroundChangesAcrossSplits() async throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()

        // Create a second split (two panes).
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(500))

        func clickPane(normalizedX: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.75)).click()
        }

        // Pane A: /tmp
        clickPane(normalizedX: 0.25)
        app.typeText("\(osc7(path: "/tmp"))\n")
        app.typeText("\(clearScreen())\n")

        // Pane B: /
        clickPane(normalizedX: 0.75)
        app.typeText("\(osc7(path: "/"))\n")
        app.typeText("\(clearScreen())\n")

        // Allow the renderer to apply the tint and settle.
        try await Task.sleep(for: .milliseconds(700))

        // Take a screenshot and compare background pixels in each pane.
        // Sample slightly right of the prompt column to avoid text.
        let shot = window.screenshot()
        let left = rgbAtNormalizedPoint(shot.image, x: 0.25, y: 0.5)
        let right = rgbAtNormalizedPoint(shot.image, x: 0.75, y: 0.5)

        // Alpha should be opaque-ish due to background-opacity=1.0.
        XCTAssertGreaterThan(left.a, 200, "Expected left pane alpha to be opaque-ish, got a=\(left.a)")
        XCTAssertGreaterThan(right.a, 200, "Expected right pane alpha to be opaque-ish, got a=\(right.a)")

        let dist = colorDistance((left.r, left.g, left.b), (right.r, right.g, right.b))
        XCTAssertGreaterThan(
            dist,
            10.0,
            "Expected left/right background colors to differ (smart-background). left=\(left) right=\(right) dist=\(dist)"
        )
    }

    @MainActor
    func testSmartBackgroundChangesInSSHPane() async throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()

        // Create a second split (two panes).
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(500))

        func clickPane(normalizedX: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.75)).click()
        }

        // Right pane will be SSH.
        clickPane(normalizedX: 0.75)

        let host = uiTestSSHHost()
        let oscHost = uiTestOsc7Host(from: host)
        let sshBase = "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \(host)"
        let sshOK = try await runLocalCommandAndCaptureExitCode(app, cmd: "\(sshBase) 'true'")
        guard sshOK == 0 else {
            throw XCTSkip("SSH preflight failed (need key-based auth): exit=\(sshOK)")
        }

        // Start an interactive SSH session (we already verified it won't prompt).
        app.typeText("ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \(host)")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .seconds(2))

        // Pane A: local / (trusted host omitted).
        clickPane(normalizedX: 0.25)
        app.typeText("\(osc7(path: "/"))\n")
        app.typeText("\(clearScreen())\n")
        try await Task.sleep(for: .milliseconds(200))

        // Pane B: remote /tmp. Send an OSC 7 with a non-local host. Smart
        // background should still update (untrusted host) for SSH/tmux.
        clickPane(normalizedX: 0.75)
        app.typeText("\(osc7(host: oscHost, path: "/tmp"))\n")
        app.typeText("\(clearScreen())\n")
        try await Task.sleep(for: .milliseconds(700))

        // Verify the pane backgrounds differ based on directory, even when the
        // right pane's cwd comes from an untrusted (SSH) OSC 7 host.
        var shot = window.screenshot()
        let left = rgbAtNormalizedPoint(shot.image, x: 0.25, y: 0.5)
        let right = rgbAtNormalizedPoint(shot.image, x: 0.75, y: 0.5)

        XCTAssertGreaterThan(left.a, 200, "Expected left pane alpha to be opaque-ish")
        XCTAssertGreaterThan(right.a, 200, "Expected right pane alpha to be opaque-ish")

        var dist = colorDistance((left.r, left.g, left.b), (right.r, right.g, right.b))
        XCTAssertGreaterThan(
            dist,
            10.0,
            "Expected local/SSH pane background colors to differ. left=\(left) right=\(right) dist=\(dist)"
        )

        // Best-effort cleanup.
        app.typeText("exit\n")
    }

    @MainActor
    func testSmartBackgroundChangesInsideLocalTmux() async throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()

        // Preflight: if tmux isn't installed, skip.
        let tmuxOK = try await runLocalCommandAndCaptureExitCode(app, cmd: "command -v tmux >/dev/null")
        guard tmuxOK == 0 else {
            throw XCTSkip("tmux not found in PATH")
        }

        // Create a second split (two panes).
        window.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(500))

        func clickPane(normalizedX: CGFloat) {
            window.coordinate(withNormalizedOffset: CGVector(dx: normalizedX, dy: 0.75)).click()
        }

        // Pane A: stable baseline (/).
        clickPane(normalizedX: 0.25)
        app.typeText("\(osc7(path: "/"))\n")
        app.typeText("\(clearScreen())\n")
        try await Task.sleep(for: .milliseconds(200))

        // Pane B: start tmux and verify OSC 7 updates still change the pane tint.
        clickPane(normalizedX: 0.75)
        // Use a dedicated tmux server so we don't mutate the user's primary tmux server.
        app.typeText("tmux -L ghostty_ui_test new -A -s ghostty_smart_bg_test\n")
        try await Task.sleep(for: .seconds(1))
        // tmux 3.6+ defaults `allow-passthrough` to off, which blocks our
        // passthrough-encoded OSC 7.
        app.typeText("tmux -L ghostty_ui_test set -g allow-passthrough on\n")
        try await Task.sleep(for: .milliseconds(300))
        app.typeText("\(clearScreen())\n")
        try await Task.sleep(for: .milliseconds(300))

        var shot = window.screenshot()
        let rightBefore = rgbAtNormalizedPoint(shot.image, x: 0.75, y: 0.5)

        app.typeText("\(osc7TmuxPassthrough(path: "/tmp"))\n")
        app.typeText("\(clearScreen())\n")
        try await Task.sleep(for: .milliseconds(700))

        shot = window.screenshot()
        let rightAfter = rgbAtNormalizedPoint(shot.image, x: 0.75, y: 0.5)

        let dist = colorDistance((rightBefore.r, rightBefore.g, rightBefore.b), (rightAfter.r, rightAfter.g, rightAfter.b))
        XCTAssertGreaterThan(
            dist,
            10.0,
            "Expected tmux pane background color to change after OSC7. before=\(rightBefore) after=\(rightAfter) dist=\(dist)"
        )

        // Cleanup: exit tmux.
        app.typeText("exit\n")
        try await Task.sleep(for: .milliseconds(500))
        app.typeText("tmux -L ghostty_ui_test kill-server\n")
        try await Task.sleep(for: .milliseconds(300))
    }
}
