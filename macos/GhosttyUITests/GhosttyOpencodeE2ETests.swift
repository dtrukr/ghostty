//
//  GhosttyOpencodeE2ETests.swift
//  GhosttyUITests
//
//  Created by Codex on 2026-02-06.
//

import AppKit
import Foundation
import XCTest

final class GhosttyOpencodeE2ETests: GhosttyCustomConfigCase {
    private func hasOpencodeBinary() -> Bool {
        let candidates = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
        return candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    private func applyBaseConfig(focusFollowsMouse: Bool = false) throws {
        try updateConfig(
            """
            title = "GhosttyOpencodeE2ETests"
            confirm-close-surface = false

            # We rely on output-idle to treat "generation finished" as the
            # terminal becoming quiet for a short period while unfocused.
            auto-focus-attention = true
            auto-focus-attention-watch-mode = all
            auto-focus-attention-idle = 200ms
            auto-focus-attention-resume-delay = 0ms
            attention-on-output-idle = 750ms
            attention-debug = true
            focus-follows-mouse = \(focusFollowsMouse ? "true" : "false")
            """
        )
    }

    private func moveMouseOutsideWindow(
        _ window: XCUIElement,
        startX: CGFloat = 0.25,
        startY: CGFloat = 0.75
    ) {
        let dragStart = window.coordinate(withNormalizedOffset: CGVector(dx: startX, dy: startY))
        let dragEnd = window.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: -0.20))
        dragStart.press(forDuration: 0.05, thenDragTo: dragEnd)
    }

    private func waitForFocus(
        _ app: XCUIApplication,
        expectedID: String,
        timeout: TimeInterval,
        activateAppWhileWaiting: Bool = false
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if activateAppWhileWaiting {
                app.activate()
            }
            if focusedSurfaceIdentifier(app) == expectedID {
                return true
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    private func cdTmp(_ app: XCUIApplication) async throws {
        app.typeText("cd /tmp")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(150))
    }

    private func focusedSurfaceIdentifier(_ app: XCUIApplication) -> String? {
        // We expose per-surface identifiers via accessibilityIdentifier and
        // include "(focused)" in the accessibilityLabel. This gives us a stable
        // way to detect focus changes across splits/tabs.
        let surfaces = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "Ghostty.SurfaceView.")
        ).allElementsBoundByIndex
        return surfaces.first(where: { $0.label.contains("focused") })?.identifier
    }

    private func surfaceDiagnostics(_ app: XCUIApplication) -> String {
        let surfaces = app.textViews.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "Ghostty.SurfaceView.")
        ).allElementsBoundByIndex
        if surfaces.isEmpty { return "<no surface textViews found>" }
        return surfaces
            .map { "\($0.identifier): \($0.label)" }
            .joined(separator: "\n")
    }

    private func agentBadgeLabels(_ app: XCUIApplication) -> [String] {
        app.otherElements.matching(identifier: "Ghostty.Surface.AgentBadge")
            .allElementsBoundByIndex
            .map { $0.label }
    }

    private func waitForBadgeLabel(
        _ app: XCUIApplication,
        containing needle: String,
        timeout: TimeInterval
    ) async throws -> String? {
        let target = needle.lowercased()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let labels = agentBadgeLabels(app)
            if let match = labels.first(where: { $0.lowercased().contains(target) }) {
                return match
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func waitForNoBadgeLabel(
        _ app: XCUIApplication,
        containing needle: String,
        timeout: TimeInterval
    ) async throws -> Bool {
        let target = needle.lowercased()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let labels = agentBadgeLabels(app)
            if labels.first(where: { $0.lowercased().contains(target) }) == nil {
                return true
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return false
    }


    private func ensureProviderStability(
        _ app: XCUIApplication,
        expected: String,
        forbidden: [String],
        duration: TimeInterval,
        sampleEvery: Duration = .milliseconds(250)
    ) async throws -> (ok: Bool, reason: String) {
        let expectedLower = expected.lowercased()
        let forbiddenLower = forbidden.map { $0.lowercased() }
        let deadline = Date().addingTimeInterval(duration)

        while Date() < deadline {
            let labels = agentBadgeLabels(app).map { $0.lowercased() }

            if !labels.contains(where: { $0.contains(expectedLower) }) {
                return (false, "expected badge missing: \(expectedLower); labels=\(labels)")
            }

            for needle in forbiddenLower {
                if labels.contains(where: { $0.contains(needle) }) {
                    return (false, "unexpected badge present: \(needle); labels=\(labels)")
                }
            }

            try await Task.sleep(for: sampleEvery)
        }

        return (true, "")
    }

    private func readPasteboardString(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let s = NSPasteboard.general.string(forType: .string) else {
            XCTFail("Pasteboard did not contain a string", file: file, line: line)
            throw XCTSkip("Pasteboard empty")
        }
        return s
    }

    private func waitForPasteboardValue(
        _ value: String,
        timeout: TimeInterval
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = NSPasteboard.general.string(forType: .string)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               current == value
            {
                return true
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        return false
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

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        // Avoid running expensive E2E coverage twice (light/dark).
        false
    }

    override func setUp() async throws {
        try await super.setUp()
        try applyBaseConfig()
    }

    @MainActor
    func testAutoFocusAttentionWorksWithOpencode() async throws {
        // Best-effort check for `opencode` without executing a subprocess.
        // If it's not installed, skip cleanly.
        guard hasOpencodeBinary() else {
            throw XCTSkip("opencode not found at expected locations. Install it first.")
        }

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

        // Focus pane B.
        clickPane(normalizedX: 0.75)
        try await Task.sleep(for: .milliseconds(200))
        try await cdTmp(app)

        // Capture the accessibility identifier for pane B (currently focused).
        let allSurfaces = app.textViews.allElementsBoundByIndex
            .filter { $0.identifier.hasPrefix("Ghostty.SurfaceView.") }
        XCTAssertGreaterThanOrEqual(allSurfaces.count, 2, "Expected at least two terminal surfaces")

        guard let focusedSurface = allSurfaces.first(where: { $0.label.contains("focused") }) else {
            XCTFail("Couldn't find a focused terminal surface element")
            return
        }
        let expectedFocusedID = focusedSurface.identifier

        // Start opencode in pane B, wait for initialization, ask a question.
        app.typeText("opencode --model opencode/kimi-k2.5-free")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .seconds(6))

        // Submit the prompt in a single synthesis step. Doing the newline as a
        // separate keypress can get delayed by XCUITest quiescence waits while
        // the TUI is actively rendering.
        app.typeText("What time is it?\n")

        // Immediately switch to pane A and do nothing (idle).
        clickPane(normalizedX: 0.25)
        moveMouseOutsideWindow(window, startX: 0.25, startY: 0.75)

        // Wait for output-idle attention to mark attention and auto-focus back to pane B.
        if try await waitForFocus(app, expectedID: expectedFocusedID, timeout: 120) {
            return
        }

        XCTFail("Expected focus to return to the opencode pane, but it did not within the timeout.\nSurfaces:\n\(surfaceDiagnostics(app))")
    }

    @MainActor
    func testOpencodeAutoBadgeAfterCtrlC() async throws {
        guard hasOpencodeBinary() else {
            throw XCTSkip("opencode not found at expected locations. Install it first.")
        }

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        app.typeText("opencode --model opencode/kimi-k2.5-free")
        app.typeKey("\n", modifierFlags: [])
        // Let opencode fully initialize before evaluating badge state.
        try await Task.sleep(for: .seconds(5))

        guard let initialLabel = try await waitForBadgeLabel(
            app,
            containing: "opencode auto-detected",
            timeout: 45
        ) else {
            XCTFail("Expected an opencode auto-detected badge after launch. labels=\(agentBadgeLabels(app))")
            return
        }

        // Stop opencode and clear viewport text to mimic a "cleared terminal".
        app.typeKey("c", modifierFlags: .control)
        try await Task.sleep(for: .milliseconds(500))

        // Ensure Ctrl-C actually returned us to a shell prompt before we treat
        // this as a "cleared shell" scenario.
        NSPasteboard.general.clearContents()
        app.typeText("echo __SHELL_READY__ | pbcopy\n")
        var shellReady = try await waitForPasteboardValue("__SHELL_READY__", timeout: 2.5)
        if !shellReady {
            // Some TUIs consume the first Ctrl-C as "cancel generation" and
            // keep running; try one more interrupt.
            app.typeKey("c", modifierFlags: .control)
            try await Task.sleep(for: .milliseconds(500))
            app.typeText("echo __SHELL_READY__ | pbcopy\n")
            shellReady = try await waitForPasteboardValue("__SHELL_READY__", timeout: 2.5)
        }
        guard shellReady else {
            XCTFail(
                """
                Ctrl-C did not return to shell in this run; opencode likely still active.
                badgeLabels=\(agentBadgeLabels(app))
                surfaces=
                \(surfaceDiagnostics(app))
                """
            )
            return
        }

        app.typeText("clear\n")
        try await Task.sleep(for: .seconds(2))

        let clearedAfterCtrlC = try await waitForNoBadgeLabel(
            app,
            containing: "opencode auto-detected",
            timeout: 10
        )
        XCTAssertTrue(
            clearedAfterCtrlC,
            """
            Expected opencode auto-detected badge to clear after Ctrl-C + clear.
            initial=\(initialLabel)
            labels=\(agentBadgeLabels(app))
            surfaces=
            \(surfaceDiagnostics(app))
            """
        )
    }

    @MainActor
    func testAutoFocusAttentionWorksWithOpencodeWhenFocusFollowsMouseEnabled() async throws {
        guard hasOpencodeBinary() else {
            throw XCTSkip("opencode not found at expected locations. Install it first.")
        }

        // Override default config for this scenario.
        try applyBaseConfig(focusFollowsMouse: true)

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

        // Focus pane B and capture its identifier.
        clickPane(normalizedX: 0.75)
        try await Task.sleep(for: .milliseconds(200))
        try await cdTmp(app)

        guard let expectedFocusedID = focusedSurfaceIdentifier(app) else {
            XCTFail("Couldn't find focused surface identifier for pane B")
            return
        }

        app.typeText("opencode --model opencode/kimi-k2.5-free")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .seconds(6))
        app.typeText("What time is it?\n")

        // Move focus to pane A and then leave the focused surface to resume.
        clickPane(normalizedX: 0.25)
        moveMouseOutsideWindow(window, startX: 0.25, startY: 0.75)

        if try await waitForFocus(app, expectedID: expectedFocusedID, timeout: 120) {
            return
        }

        XCTFail("Expected focus to return to the opencode pane with focus-follows-mouse=true.\nSurfaces:\n\(surfaceDiagnostics(app))")
    }

    @MainActor
    func testAutoFocusAttentionWorksWithOpencodeAcrossTabs() async throws {
        guard hasOpencodeBinary() else {
            throw XCTSkip("opencode not found at expected locations. Install it first.")
        }

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create tab 2 and switch to it.
        window.typeKey("t", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        window.typeKey("2", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        try await cdTmp(app)

        // Capture the expected focused surface identifier for tab 2.
        guard let expectedFocusedID = focusedSurfaceIdentifier(app) else {
            XCTFail("Couldn't find focused surface identifier in tab 2")
            return
        }

        // Start opencode in tab 2.
        app.typeText("opencode --model opencode/kimi-k2.5-free")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .seconds(6))

        // Submit prompt and immediately switch away.
        app.typeText("What time is it?\n")
        window.typeKey("1", modifierFlags: .command)
        moveMouseOutsideWindow(window, startX: 0.25, startY: 0.75)

        // Wait for output-idle attention to bring focus back to tab 2.
        if try await waitForFocus(app, expectedID: expectedFocusedID, timeout: 120) {
            return
        }

        XCTFail("Expected focus to return to the opencode tab, but it did not within the timeout.\nSurfaces:\n\(surfaceDiagnostics(app))")
    }

    @MainActor
    func testAutoFocusAttentionWorksWithSSHOpencodeAndNormalCommands() async throws {
        guard hasOpencodeBinary() else {
            throw XCTSkip("opencode not found at expected locations. Install it first.")
        }

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        // Create two more tabs so we can exercise attention across tabs.
        window.typeKey("t", modifierFlags: .command) // tab 2
        try await Task.sleep(for: .milliseconds(300))
        window.typeKey("t", modifierFlags: .command) // tab 3
        try await Task.sleep(for: .milliseconds(300))

        // Tab 2: SSH + remote opencode.
        window.typeKey("2", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        try await cdTmp(app)

        guard let expectedTab2FocusID = focusedSurfaceIdentifier(app) else {
            XCTFail("Couldn't find focused surface identifier in tab 2")
            return
        }

        // Preflight: make sure SSH works without prompting.
        // If you don't have key-based auth set up, this will fail fast and we skip.
        let host = uiTestSSHHost()
        let sshBase = "ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \(host)"
        let sshOK = try await runLocalCommandAndCaptureExitCode(app, cmd: "\(sshBase) 'true'")
        guard sshOK == 0 else {
            throw XCTSkip("SSH preflight failed (need key-based auth): exit=\(sshOK)")
        }

        // Preflight: ensure opencode exists on the remote host.
        let opencodeOK = try await runLocalCommandAndCaptureExitCode(app, cmd: "\(sshBase) 'command -v opencode >/dev/null'")
        guard opencodeOK == 0 else {
            throw XCTSkip("Remote opencode not found on \(host): exit=\(opencodeOK)")
        }

        // Start an interactive SSH session (we already verified it won't prompt).
        app.typeText("ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 \(host)")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .seconds(2))

        // Remote: start opencode and submit a prompt.
        app.typeText("cd /tmp\n")
        try await Task.sleep(for: .milliseconds(300))

        app.typeText("opencode --model opencode/kimi-k2.5-free\n")
        try await Task.sleep(for: .seconds(7))
        app.typeText("What time is it?\n")

        // Switch away immediately (tab 1).
        window.typeKey("1", modifierFlags: .command)
        moveMouseOutsideWindow(window, startX: 0.25, startY: 0.75)
        app.activate()

        // Wait for output-idle attention to bring focus back to tab 2.
        let returnedToTab2 = try await waitForFocus(
            app,
            expectedID: expectedTab2FocusID,
            timeout: 60,
            activateAppWhileWaiting: true
        )
        guard returnedToTab2 else {
            XCTFail(
                "Expected focus to return to tab 2 (SSH opencode) within 60s.\nSurfaces:\n\(surfaceDiagnostics(app))"
            )
            return
        }

        // Best-effort: stop the remote TUI to avoid it stealing focus later.
        app.typeKey("c", modifierFlags: .control)
        try await Task.sleep(for: .milliseconds(300))
        app.typeText("exit\n")
        try await Task.sleep(for: .milliseconds(500))

        // Tab 3: normal command output-idle attention should also bring focus back.
        window.typeKey("3", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(300))
        try await cdTmp(app)

        guard let expectedTab3FocusID = focusedSurfaceIdentifier(app) else {
            XCTFail("Couldn't find focused surface identifier in tab 3")
            return
        }

        // Start a noisy command and immediately switch away.
        app.typeText("(for i in 1 2 3 4 5; do printf x; sleep 0.2; done; echo done) ; true\n")
        window.typeKey("1", modifierFlags: .command)
        moveMouseOutsideWindow(window, startX: 0.25, startY: 0.75)

        if try await waitForFocus(app, expectedID: expectedTab3FocusID, timeout: 20) {
            return
        }

        XCTFail("Expected focus to return to tab 3 after normal command output idle, but it did not.\nSurfaces:\n\(surfaceDiagnostics(app))")
    }

    @MainActor
    func testOpencodePromptMentioningOtherAgentsDoesNotReclassifyProvider() async throws {
        guard hasOpencodeBinary() else {
            throw XCTSkip("opencode not found at expected locations. Install it first.")
        }

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        app.typeText("opencode --model opencode/kimi-k2.5-free")
        app.typeKey("\n", modifierFlags: [])

        // Let opencode finish UI init before prompting.
        try await Task.sleep(for: .seconds(6))

        // First establish provider detection with a neutral prompt.
        app.typeText("What time is it?\n")

        guard let initial = try await waitForBadgeLabel(
            app,
            containing: "opencode auto-detected",
            timeout: 60
        ) else {
            XCTFail("Expected opencode auto-detected badge after neutral prompt. labels=\(agentBadgeLabels(app))")
            return
        }

        // Mention other provider names in a normal query; provider detection should
        // remain opencode and should not flip to claude/codex/etc.
        app.typeText("How do I use Claude CLI, Codex, Gemini CLI, AG-TUI, and Vibe? Keep it short.\n")

        let stability = try await ensureProviderStability(
            app,
            expected: "opencode auto-detected",
            forbidden: [
                "claude auto-detected",
                "codex auto-detected",
                "gemini auto-detected",
                "ag-tui auto-detected",
                "vibe auto-detected",
            ],
            duration: 20
        )
        XCTAssertTrue(
            stability.ok,
            "Expected opencode detection to remain stable after cross-agent prompt. initial=\(initial) reason=\(stability.reason)"
        )

        // Best-effort cleanup.
        app.typeKey("c", modifierFlags: .control)
    }
}
