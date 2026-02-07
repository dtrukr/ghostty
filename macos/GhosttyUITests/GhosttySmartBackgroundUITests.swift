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
            background = #000000
            foreground = #ffffff

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

    private func saturationProxy(_ c: (UInt8, UInt8, UInt8)) -> Double {
        // A simple saturation proxy in RGB: (max-min)/max. Good enough to assert "not neon".
        let maxv = Double(max(c.0, max(c.1, c.2)))
        let minv = Double(min(c.0, min(c.1, c.2)))
        guard maxv > 0 else { return 0 }
        return (maxv - minv) / maxv
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

    @MainActor
    func testSmartBackgroundIsStableAcrossRelaunchForSameFolder() async throws {
        func sampleTmpTint(_ app: XCUIApplication) async throws -> (UInt8, UInt8, UInt8) {
            app.launch()
            let window = app.windows.firstMatch
            XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()

            app.typeText("\(osc7(path: "/tmp"))\n")
            app.typeText("\(clearScreen())\n")
            try await Task.sleep(for: .milliseconds(700))

            let shot = window.screenshot()
            let c = rgbAtNormalizedPoint(shot.image, x: 0.5, y: 0.5)
            XCTAssertGreaterThan(c.a, 200, "Expected alpha to be opaque-ish")
            return (c.r, c.g, c.b)
        }

        let app1 = try ghosttyApplication()
        let c1 = try await sampleTmpTint(app1)
        app1.terminate()

        let app2 = try ghosttyApplication()
        let c2 = try await sampleTmpTint(app2)
        app2.terminate()

        let dist = colorDistance(c1, c2)
        XCTAssertLessThan(
            dist,
            3.0,
            "Expected /tmp tint to be stable across relaunch. c1=\(c1) c2=\(c2) dist=\(dist)"
        )
    }

    @MainActor
    func testSmartBackgroundUsesGentlePastelTints() async throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()

        app.typeText("\(osc7(path: "/tmp"))\n")
        app.typeText("\(clearScreen())\n")
        try await Task.sleep(for: .milliseconds(700))

        let shot = window.screenshot()
        let c = rgbAtNormalizedPoint(shot.image, x: 0.5, y: 0.5)
        let sat = saturationProxy((c.r, c.g, c.b))

        XCTAssertLessThan(
            sat,
            0.70,
            "Expected smart background tint to be gentle/pastel (low saturation proxy). rgb=\(c) sat=\(sat)"
        )
    }

    @MainActor
    func testSmartBackgroundProjectKeyUnifiesGitWorktrees() async throws {
        // Best-effort: if git isn't installed, skip.
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()

        let gitOK = try await runLocalCommandAndCaptureExitCode(app, cmd: "command -v git >/dev/null")
        guard gitOK == 0 else { throw XCTSkip("git not found in PATH") }

        // Switch to project keying for this test.
        try updateConfig(
            """
            title = "GhosttySmartBackgroundUITests"
            confirm-close-surface = false

            background-opacity = 1.0
            background-blur = 0
            background = #000000
            foreground = #ffffff

            desktop-notifications = false

            smart-background = true
            smart-background-key = project
            smart-background-strength = 1.0

            # Used by this test to read the computed key label via the inspector.
            keybind = cmd+i=inspector:toggle
            """
        )
        // Relaunch with the updated config.
        app.terminate()

        let app2 = try ghosttyApplication()
        app2.launch()

        let window2 = app2.windows.firstMatch
        XCTAssertTrue(window2.waitForExistence(timeout: 2), "Main window should exist")
        window2.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()

        // Create a second split for side-by-side sampling.
        window2.typeKey("d", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(500))

        func clickPane(_ x: CGFloat) {
            window2.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.75)).click()
        }

        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let repo = "/tmp/ghostty_ui_git_repo_\(id)"
        let wt = "/tmp/ghostty_ui_git_repo_\(id)_wt"

        // Setup a repo and a worktree.
        clickPane(0.25)
        app2.typeText(
            """
            rm -rf \(repo) \(wt)
            mkdir -p \(repo)
            cd \(repo)
            git init -q
            git config user.email test@example.com
            git config user.name GhosttyUITests
            echo hi > README.md
            git add README.md
            git commit -q -m init
            git worktree add -q \(wt)
            \n
            """
        )
        try await Task.sleep(for: .seconds(1))

        // Pane A: main repo root.
        clickPane(0.25)
        app2.typeText("\(osc7(path: repo))\n")
        app2.typeText("\(clearScreen())\n")

        // Pane B: worktree root, should map to the same project key.
        clickPane(0.75)
        app2.typeText("\(osc7(path: wt))\n")
        app2.typeText("\(clearScreen())\n")

        try await Task.sleep(for: .milliseconds(700))

        func readSmartBackgroundKeyForFocusedSurface() async throws -> String {
            // Toggle the inspector for the focused surface, read the accessibility label,
            // then close it to avoid multiple matches.
            window2.typeKey("i", modifierFlags: .command)
            let keyText = app2.staticTexts["Ghostty.Inspector.SmartBackgroundKey"]
            XCTAssertTrue(keyText.waitForExistence(timeout: 2), "Expected inspector smart background key label to exist")
            let key = keyText.label
            window2.typeKey("i", modifierFlags: .command)
            try await Task.sleep(for: .milliseconds(150))
            return key
        }

        // Key labels should match (this is the direct observable for worktree unification).
        clickPane(0.25)
        try await Task.sleep(for: .milliseconds(150))
        let keyLeft = try await readSmartBackgroundKeyForFocusedSurface()

        clickPane(0.75)
        try await Task.sleep(for: .milliseconds(150))
        let keyRight = try await readSmartBackgroundKeyForFocusedSurface()

        XCTAssertEqual(
            keyLeft,
            keyRight,
            "Expected smart background project key to unify git worktree with main repo. leftKey=\(keyLeft) rightKey=\(keyRight)"
        )
        XCTAssertNotEqual(keyLeft, "—", "Expected a non-empty smart background key label for the repo pane")
        XCTAssertNotEqual(keyRight, "—", "Expected a non-empty smart background key label for the worktree pane")

        // Cleanup (best-effort).
        clickPane(0.25)
        app2.typeText("rm -rf \(repo) \(wt)\n")
    }
}
