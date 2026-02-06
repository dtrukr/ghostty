//
//  GhosttyCustomConfigCase.swift
//  Ghostty
//
//  Created by luca on 16.10.2025.
//

import XCTest

class GhosttyCustomConfigCase: XCTestCase {
    /// Shared SSH host used by UI tests that need a remote session (for
    /// opencode E2E coverage and smart-background coverage).
    ///
    /// Override with `GHOSTTY_UI_TEST_SSH_HOST` (for example: `user@host`).
    func uiTestSSHHost() -> String {
        ProcessInfo.processInfo.environment["GHOSTTY_UI_TEST_SSH_HOST"] ?? "dennis@100.115.128.116"
    }

    /// Extract a host string suitable for `file://<host>/path` OSC 7 payloads.
    /// If `sshTarget` contains a user (like `user@host`), the user is dropped.
    func uiTestOsc7Host(from sshTarget: String) -> String {
        if let at = sshTarget.lastIndex(of: "@") {
            return String(sshTarget[sshTarget.index(after: at)...])
        }
        return sshTarget
    }

    override class var defaultTestSuite: XCTestSuite {
        // Always run. (The Zig build system may sanitize environment variables,
        // so gating on env var presence here is unreliable.)
        return XCTestSuite(forTestCaseClass: Self.self)
    }

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    var configFile: URL?
    override func setUpWithError() throws {
        continueAfterFailure = false

        // Auto-dismiss system permission prompts that can appear during UI tests
        // (e.g. notifications permission). This keeps tests deterministic.
        _ = addUIInterruptionMonitor(withDescription: "System dialogs") { alert in
            for title in ["Allow", "OK", "Continue"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.click()
                    return true
                }
            }

            for title in ["Don’t Allow", "Don't Allow", "Cancel", "Not Now"] {
                let button = alert.buttons[title]
                if button.exists {
                    button.click()
                    return true
                }
            }

            let fallback = alert.buttons.firstMatch
            if fallback.exists {
                fallback.click()
                return true
            }

            return false
        }

        // Some of our UI tests rely on readable OSLog output and predictable
        // test behavior. Xcode sets this automatically, but CLI-driven runs
        // (such as `zig build test`) do not.
        setenv("IDE_DISABLED_OS_ACTIVITY_DT_MODE", "1", 0)
    }

    override func tearDown() async throws {
        if let configFile {
            try FileManager.default.removeItem(at: configFile)
        }
    }

    func updateConfig(_ newConfig: String) throws {
        if configFile == nil {
            let temporaryConfig = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("ghostty")
            configFile = temporaryConfig
        }
        try newConfig.write(to: configFile!, atomically: true, encoding: .utf8)
    }

    func ghosttyApplication() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        // Make the app treat this as an Xcode-launched run so it doesn't try
        // to interpret XCUITest-provided args as Ghostty CLI config args.
        app.launchEnvironment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] = "1"
        guard let configFile else {
            return app
        }
        app.launchEnvironment["GHOSTTY_CONFIG_PATH"] = configFile.path
        return app
    }
}
