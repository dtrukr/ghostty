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
    private func cdTmp(_ app: XCUIApplication) async throws {
        app.typeText("cd /tmp")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(150))
    }

    private func focusedSurfaceIdentifier(_ app: XCUIApplication) -> String? {
        // We expose per-surface identifiers via accessibilityIdentifier and
        // include "(focused)" in the accessibilityLabel. This gives us a stable
        // way to detect focus changes across splits/tabs.
        let surfaces = app.descendants(matching: .any).allElementsBoundByIndex.filter {
            $0.identifier.hasPrefix("Ghostty.SurfaceView.")
        }
        return surfaces.first(where: { $0.label.contains("focused") })?.identifier
    }

    private func surfaceDiagnostics(_ app: XCUIApplication) -> String {
        let surfaces = app.descendants(matching: .any).allElementsBoundByIndex.filter {
            $0.identifier.hasPrefix("Ghostty.SurfaceView.")
        }
        if surfaces.isEmpty { return "<no surface textViews found>" }
        return surfaces
            .map { "\($0.identifier): \($0.label)" }
            .joined(separator: "\n")
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

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        // Avoid running expensive E2E coverage twice (light/dark).
        false
    }

    override func setUp() async throws {
        try await super.setUp()

        try updateConfig(
            """
            title = "GhosttyOpencodeE2ETests"
            confirm-close-surface = false

            # We rely on output-idle to treat "generation finished" as the
            # terminal becoming quiet for a short period while unfocused.
            auto-focus-attention = true
            auto-focus-attention-idle = 200ms
            attention-on-output-idle = 750ms
            attention-debug = true
            """
        )
    }

    @MainActor
    func testAutoFocusAttentionWorksWithOpencode() async throws {
        // Best-effort check for `opencode` without executing a subprocess.
        // If it's not installed, skip cleanly.
        let candidates = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
        guard candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
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

        // Wait for output-idle attention to mark attention and auto-focus back to pane B.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if focusedSurfaceIdentifier(app) == expectedFocusedID { return }
            try await Task.sleep(for: .milliseconds(250))
        }

        XCTFail("Expected focus to return to the opencode pane, but it did not within the timeout.")
    }

    @MainActor
    func testAutoFocusAttentionWorksWithOpencodeAcrossTabs() async throws {
        let candidates = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
        guard candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
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

        // Wait for output-idle attention to bring focus back to tab 2.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if focusedSurfaceIdentifier(app) == expectedFocusedID { return }
            try await Task.sleep(for: .milliseconds(250))
        }

        XCTFail("Expected focus to return to the opencode tab, but it did not within the timeout.")
    }

    @MainActor
    func testAutoFocusAttentionWorksWithSSHOpencodeAndNormalCommands() async throws {
        let candidates = ["/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
        guard candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
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
        app.activate()

        // Wait for output-idle attention to bring focus back to tab 2.
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            // Keep Ghostty as the frontmost app while we wait. Auto-focus is
            // suppressed when Ghostty is not active.
            app.activate()

            if focusedSurfaceIdentifier(app) == expectedTab2FocusID { return }
            try await Task.sleep(for: .milliseconds(250))
        }

        XCTFail(
            "Expected focus to return to tab 2 (SSH opencode) within 60s.\nSurfaces:\n\(surfaceDiagnostics(app))"
        )

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

        let deadline2 = Date().addingTimeInterval(20)
        while Date() < deadline2 {
            if focusedSurfaceIdentifier(app) == expectedTab3FocusID { return }
            try await Task.sleep(for: .milliseconds(250))
        }

        XCTFail("Expected focus to return to tab 3 after normal command output idle, but it did not.")
    }
}
