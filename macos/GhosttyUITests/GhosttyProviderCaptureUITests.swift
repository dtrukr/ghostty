//
//  GhosttyProviderCaptureUITests.swift
//  GhosttyUITests
//
//  Created by OpenCode on 2026-02-10.
//

import AppKit
import Foundation
import XCTest

final class GhosttyProviderCaptureUITests: GhosttyCustomConfigCase {
    private lazy var captureDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ghostty-provider-capture", isDirectory: true)
    }()

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        false
    }

    override func setUp() async throws {
        try await super.setUp()
        try updateConfig(
            """
            title = "GhosttyProviderCaptureUITests"
            confirm-close-surface = false
            focus-follows-mouse = false
            """
        )
    }

    @MainActor
    private func cdTmp(_ app: XCUIApplication) async throws {
        app.typeText("cd /tmp")
        app.typeKey("\n", modifierFlags: [])
        try await Task.sleep(for: .milliseconds(150))
    }

    private func readPasteboardString(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let s = NSPasteboard.general.string(forType: .string) else {
            XCTFail("Pasteboard did not contain a string", file: file, line: line)
            throw XCTSkip("Pasteboard empty")
        }
        return s
    }

    @MainActor
    private func focusedSurfaceLabel(_ app: XCUIApplication) -> String? {
        let surfaces = app.textViews.allElementsBoundByIndex
            .filter { $0.identifier.hasPrefix("Ghostty.SurfaceView.") }
        return surfaces.first(where: { $0.label.contains("focused") })?.label
    }

    private func focusedSurfaceValue(_ app: XCUIApplication) -> String? {
        let surfaces = app.textViews.allElementsBoundByIndex
            .filter { $0.identifier.hasPrefix("Ghostty.SurfaceView.") }
        guard let surface = surfaces.first(where: { $0.label.contains("focused") }) else {
            return nil
        }
        return surface.value as? String
    }

    @MainActor
    private func captureSelection(_ app: XCUIApplication) async throws -> String? {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("__ghostty_capture__", forType: .string)
        app.typeKey("a", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(150))
        app.typeKey("c", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(200))
        let value = try readPasteboardString().trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "__ghostty_capture__" { return nil }
        return value.isEmpty ? nil : value
    }

    @MainActor
    private func captureProvider(
        _ app: XCUIApplication,
        name: String,
        command: String,
        wait: Duration = .seconds(6)
    ) async throws {
        // Each provider gets a fresh shell tab so prior TUI state doesn't consume input.
        app.typeKey("t", modifierFlags: .command)
        try await Task.sleep(for: .milliseconds(400))
        try await cdTmp(app)

        app.typeText("\(command)\n")
        try await Task.sleep(for: wait)

        let captured = try await captureSelection(app)
            ?? focusedSurfaceValue(app)
            ?? focusedSurfaceLabel(app)
        guard let label = captured else {
            XCTFail("No captured output for \(name)")
            return
        }

        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let outputURL = captureDirectory.appendingPathComponent("\(name).txt")
        try label.write(to: outputURL, atomically: true, encoding: .utf8)
        print("Captured \(name) output to \(outputURL.path)")

        // Best-effort stop to avoid background output.
        app.typeKey("c", modifierFlags: .control)
        try await Task.sleep(for: .milliseconds(300))
        app.typeText("\n")
        try await Task.sleep(for: .milliseconds(300))
    }

    @MainActor
    func testCaptureProviderViewportOutput() async throws {
        let app = try ghosttyApplication()
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 2), "Main window should exist")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)).click()
        try await cdTmp(app)

        try await captureProvider(app, name: "codex", command: "codex")
        try await captureProvider(app, name: "opencode", command: "opencode")
        try await captureProvider(app, name: "claude", command: "claude")
        try await captureProvider(app, name: "gemini", command: "gemini")
    }
}
