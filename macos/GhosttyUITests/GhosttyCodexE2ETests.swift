//
//  GhosttyCodexE2ETests.swift
//  GhosttyUITests
//
//  Created by Codex on 2026-02-11.
//

import AppKit
import Foundation
import XCTest

final class GhosttyCodexE2ETests: GhosttyCustomConfigCase {
    private func hasCodexBinary() -> Bool {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        if candidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return true
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = String(dir) + "/codex"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return true
            }
        }
        return false
    }

    private func agentBadgeLabels(_ app: XCUIApplication) -> [String] {
        app.otherElements.matching(identifier: "Ghostty.Surface.AgentBadge")
            .allElementsBoundByIndex
            .map { $0.label }
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

    private func codexAutoBadgeExists(_ app: XCUIApplication) -> Bool {
        let labels = agentBadgeLabels(app).map { $0.lowercased() }
        return labels.contains(where: { $0.contains("codex auto-detected") })
    }

    private func waitForCodexAutoBadge(
        _ app: XCUIApplication,
        timeout: TimeInterval
    ) async throws -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let labels = agentBadgeLabels(app)
            if let match = labels.first(where: { $0.lowercased().contains("codex auto-detected") }) {
                return match
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func ensureCodexAutoBadgeStaysVisible(
        _ app: XCUIApplication,
        duration: TimeInterval,
        sampleEvery: Duration = .milliseconds(250)
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if !codexAutoBadgeExists(app) {
                return false
            }
            try await Task.sleep(for: sampleEvery)
        }
        return true
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

    private func waitForRepoSetupResult(
        timeout: TimeInterval
    ) async throws -> (path: String, changedCount: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let raw = (NSPasteboard.general.string(forType: .string) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty {
                try await Task.sleep(for: .milliseconds(200))
                continue
            }

            let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
            if parts.count == 2, let changed = Int(parts[1]) {
                return (String(parts[0]), changed)
            }

            try await Task.sleep(for: .milliseconds(200))
        }
        return nil
    }

    @MainActor
    private func createChangedRepoFixture(_ app: XCUIApplication) async throws -> (path: String, changedCount: Int) {
        NSPasteboard.general.clearContents()
        app.typeText(
            """
            set -e
            REPO="$(mktemp -d /tmp/ghostty-codex-review-XXXXXX)"
            cd "$REPO"
            git init -q
            git config user.name "Ghostty UITest"
            git config user.email "ghostty-uitest@example.com"
            mkdir -p src
            for i in $(seq 1 60); do
              r=$(( (RANDOM % 900) + 100 ))
              printf "export function file_%d(value: number): number { return value + %d; }\\n" "$i" "$r" > "src/file_$i.ts"
            done
            git add .
            git commit -q -m "initial snapshot"
            for i in $(seq 1 60); do
              r=$(( (RANDOM % 900) + 100 ))
              printf "\\nexport function changed_%d(input: number): number { return input - %d; }\\n" "$i" "$r" >> "src/file_$i.ts"
            done
            CHANGED="$(git status --short | wc -l | tr -d ' ')"
            echo "$REPO|$CHANGED" | pbcopy
            """
        )
        app.typeKey("\n", modifierFlags: [])

        if let result = try await waitForRepoSetupResult(timeout: 25) {
            return result
        }

        XCTFail("Failed to create repo fixture or read changed-count from pasteboard.")
        throw XCTSkip("repo fixture unavailable")
    }

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        // Avoid running expensive E2E coverage twice (light/dark).
        false
    }

    override func setUp() async throws {
        try await super.setUp()
        try updateConfig(
            """
            title = "GhosttyCodexE2ETests"
            confirm-close-surface = false

            # Keep this test scoped to provider auto-detection.
            auto-focus-attention = false
            auto-focus-attention-watch-mode = agents
            attention-watch-providers = codex
            attention-surface-tag-allow-any = false

            # Lower stabilization latency so badges converge quickly in UI test runs.
            agent-status-stable = 200ms
            attention-debug = false
            focus-follows-mouse = true
            """
        )
    }

    @MainActor
    func testCodexAutoDetectionStaysVisibleDuringReviewOnLargeChangedRepo() async throws {
        guard hasCodexBinary() else {
            throw XCTSkip("codex not found in PATH. Install codex first.")
        }

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()

        let repoSetup = try await createChangedRepoFixture(app)
        XCTAssertGreaterThanOrEqual(
            repoSetup.changedCount,
            40,
            "Expected many changed files in fixture repo, got \(repoSetup.changedCount). path=\(repoSetup.path)"
        )

        // Launch codex and give it time to initialize before issuing /review.
        app.typeText("codex --yolo\n")
        try await Task.sleep(for: .seconds(5))

        guard let initialBadge = try await waitForCodexAutoBadge(app, timeout: 45) else {
            XCTFail(
                """
                Expected codex auto-detected badge after launching codex.
                repo=\(repoSetup.path)
                labels=\(agentBadgeLabels(app))
                surfaces=
                \(surfaceDiagnostics(app))
                """
            )
            return
        }

        // Check for pre-review stability before sending the review command.
        let stableBeforeReview = try await ensureCodexAutoBadgeStaysVisible(app, duration: 3)
        XCTAssertTrue(
            stableBeforeReview,
            """
            Expected codex auto-detected badge to remain visible during initialization window.
            initialBadge=\(initialBadge)
            labels=\(agentBadgeLabels(app))
            surfaces=
            \(surfaceDiagnostics(app))
            """
        )

        // Trigger Codex review workflow on the synthetic repo with many changes.
        app.typeText("/review\n")

        // Codex prompts for review mode selection. In our target workflow this
        // appears after a short delay; choose option 2 and submit.
        try await Task.sleep(for: .seconds(3))
        app.typeText("2\n")

        // Ensure auto-detection does not drop while codex is processing review.
        let stableDuringReview = try await ensureCodexAutoBadgeStaysVisible(app, duration: 12)
        XCTAssertTrue(
            stableDuringReview,
            """
            Expected codex auto-detected badge to remain visible after /review + mode selection.
            repo=\(repoSetup.path)
            labels=\(agentBadgeLabels(app))
            surfaces=
            \(surfaceDiagnostics(app))
            """
        )

        // Best-effort cleanup to avoid a long-running codex session after test.
        app.typeKey("c", modifierFlags: .control)
    }

    @MainActor
    func testCodexPromptMentioningOtherAgentsDoesNotReclassifyProvider() async throws {
        guard hasCodexBinary() else {
            throw XCTSkip("codex not found in PATH. Install codex first.")
        }

        // Include other providers so an accidental reclassification would be observable.
        try updateConfig(
            """
            title = "GhosttyCodexE2ETests"
            confirm-close-surface = false

            auto-focus-attention = false
            auto-focus-attention-watch-mode = agents
            attention-watch-providers = codex,opencode,claude,gemini,vibe,ag-tui
            attention-surface-tag-allow-any = false

            agent-status-stable = 200ms
            attention-debug = false
            focus-follows-mouse = true
            """
        )

        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()

        app.typeText("cd /tmp\n")
        try await Task.sleep(for: .milliseconds(250))

        app.typeText("codex --yolo\n")
        try await Task.sleep(for: .seconds(5))

        guard let initialBadge = try await waitForCodexAutoBadge(app, timeout: 45) else {
            XCTFail("Expected codex auto-detected badge after launching codex. labels=\(agentBadgeLabels(app))")
            return
        }

        app.typeText("How do I use Claude CLI, OpenCode, Gemini CLI, AG-TUI, and Vibe? Keep it short.\n")
        let stability = try await ensureProviderStability(
            app,
            expected: "codex auto-detected",
            forbidden: [
                "claude auto-detected",
                "opencode auto-detected",
                "gemini auto-detected",
                "ag-tui auto-detected",
                "vibe auto-detected",
            ],
            duration: 20
        )
        XCTAssertTrue(
            stability.ok,
            "Expected codex detection to remain stable after cross-agent prompt. initial=\(initialBadge) reason=\(stability.reason)"
        )

        app.typeKey("c", modifierFlags: .control)
    }
}
