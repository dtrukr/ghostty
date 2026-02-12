import Cocoa
import SwiftUI
import Combine
import GhosttyKit

/// A base class for windows that can contain Ghostty windows. This base class implements
/// the bare minimum functionality that every terminal window in Ghostty should implement.
///
/// Usage: Specify this as the base class of your window controller for the window that contains
/// a terminal. The window controller must also be the window delegate OR the window delegate
/// functions on this base class must be called by your own custom delegate. For the terminal
/// view the TerminalView SwiftUI view must be used and this class is the view model and
/// delegate.
///
/// Special considerations to implement:
///
///   - Fullscreen: you must manually listen for the right notification and implement the
///   callback that calls toggleFullscreen on this base class.
///
/// Notably, things this class does NOT implement (not exhaustive):
///
///   - Tabbing, because there are many ways to get tabbed behavior in macOS and we
///   don't want to be opinionated about it.
///   - Window restoration or save state
///   - Window visual styles (such as titlebar colors)
///
/// The primary idea of all the behaviors we don't implement here are that subclasses may not
/// want these behaviors.
class BaseTerminalController: NSWindowController,
                              NSWindowDelegate,
                              TerminalViewDelegate,
                              TerminalViewModel,
                              ClipboardConfirmationViewDelegate,
                              FullscreenDelegate
{
    /// The app instance that this terminal view will represent.
    let ghostty: Ghostty.App

    /// The currently focused surface.
    var focusedSurface: Ghostty.SurfaceView? = nil {
        didSet { syncFocusToSurfaceTree() }
    }

    /// The tree of splits within this terminal window.
    @Published var surfaceTree: SplitTree<Ghostty.SurfaceView> = .init() {
        didSet { surfaceTreeDidChange(from: oldValue, to: surfaceTree) }
    }

    /// This can be set to show/hide the command palette.
    @Published var commandPaletteIsShowing: Bool = false
    
    /// Set if the terminal view should show the update overlay.
    @Published var updateOverlayIsVisible: Bool = false

    /// Debug UI overlay text for the attention/cycling engine.
    @Published var attentionOverlayText: String = ""

    /// Debug UI overlay text for agent status detection (Codex/OpenCode/etc).
    @Published var agentStatusOverlayText: String = ""

    /// Whether the terminal surface should focus when the mouse is over it.
    var focusFollowsMouse: Bool {
        self.derivedConfig.focusFollowsMouse
    }

    /// Non-nil when an alert is active so we don't overlap multiple.
    private var alert: NSAlert? = nil

    /// The clipboard confirmation window, if shown.
    private var clipboardConfirmation: ClipboardConfirmationController? = nil

    /// Fullscreen state management.
    private(set) var fullscreenStyle: FullscreenStyle?

    /// Event monitor (see individual events for why)
    private var eventMonitor: Any? = nil

    /// The previous frame information from the window
    private var savedFrame: SavedFrame? = nil

    /// Cache previously applied appearance to avoid unnecessary updates
    private var appliedColorScheme: ghostty_color_scheme_e?

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private var derivedConfig: DerivedConfig

    /// Track whether background is forced opaque (true) or using config transparency (false)
    var isBackgroundOpaque: Bool = false

    /// The cancellables related to our focused surface.
    private var focusedSurfaceCancellables: Set<AnyCancellable> = []

    // Bell-state subscriptions for all surfaces in this controller.
    private var surfaceBellCancellables: Set<AnyCancellable> = []

    /// An override title for the tab/window set by the user via prompt_tab_title.
    /// When set, this takes precedence over the computed title from the terminal.
    var titleOverride: String? = nil {
        didSet { applyTitleToWindow() }
    }

    /// The last computed title from the focused surface (without the override).
    private var lastComputedTitle: String = "👻"

    /// Most recent user activity time (seconds since boot). Used to gate auto-focus.
    private var lastUserActivityUptime: TimeInterval = ProcessInfo.processInfo.systemUptime

    /// Debounce state for auto-focus-attention.
    private var autoFocusAttentionWorkItem: DispatchWorkItem? = nil

    /// Monotonic token used to ensure canceled auto-focus work items don't run.
    /// `DispatchWorkItem.cancel()` does not reliably prevent execution; it only
    /// marks the item as canceled. We explicitly gate on this token.
    private var autoFocusAttentionToken: UInt64 = 0

    /// Set when an attention event occurs but auto-focus-attention is paused.
    private var autoFocusAttentionPending: Bool = false

    /// When we entered the pending state (or last updated it due to a new
    /// attention mark). Used to enforce a minimum attention age before
    /// auto-focus triggers.
    private var autoFocusAttentionPendingSinceUptime: TimeInterval? = nil

    /// When auto-focus moves focus to a surface, we "lock" on that surface and
    /// treat it as active user interest until the user focuses away.
    ///
    /// This avoids a noisy failure mode where attention in another tab can
    /// immediately steal focus back while you're reading the surface that was
    /// just auto-focused (even if you don't move the mouse or type).
    private var autoFocusAttentionFocusLockSurfaceId: UUID? = nil

    /// The surface that was focused when we first entered the paused+pending state.
    /// Used (optionally) to resume when the user switches to a different surface.
    private var autoFocusAttentionPausedSurfaceId: UUID? = nil

    /// True when the mouse cursor is inside the focused surface. Used as an
    /// explicit "I'm reading/using this pane" signal to pause auto-focus.
    private var autoFocusAttentionMouseInsideFocusedSurface: Bool = true


    /// Debug-only metadata used to render live attention countdown + next action.
    private var attentionOverlayHint: String = "idle"
    private var attentionOverlayPlanDeadlineUptime: TimeInterval? = nil
    private var attentionOverlayPlanReason: String? = nil
    /// Last cycled attention surface per tab group, so cycling continues smoothly
    /// when it crosses tabs.
    private static var attentionCycleState: [ObjectIdentifier: UUID] = [:]

    // MARK: Agent Detection / Surface Badges

    private enum AgentProvider: String, CaseIterable {
        case codex
        case opencode
        case ag_tui = "ag-tui"
        case claude
        case vibe
        case gemini
        case unknown
    }

    private enum AgentStatus: String {
        case running, waiting, idle
    }

    private enum AgentDetectionSource: String {
        case none
        case marked
        case title
        case viewport
        case diagnostic
    }

    private struct AgentObservedState {
        var provider: AgentProvider
        var status: AgentStatus
        var badgeProvider: String?
        var source: AgentDetectionSource
        var sinceUptime: TimeInterval
    }

    private struct AgentStableState {
        var provider: AgentProvider
        var status: AgentStatus
        var badgeProvider: String?
        var source: AgentDetectionSource
    }

    private struct AgentProviderLockState {
        var provider: AgentProvider
        var mismatchProvider: AgentProvider = .unknown
        var mismatchCount: Int = 0
        var unknownIdlePromptCount: Int = 0
        var unknownStreakCount: Int = 0
        var lastPositiveEvidenceUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    }

    private let agentProviderLockSwitchPolls: Int = 3
    private let agentProviderLockPromptClearPolls: Int = 3
    private let agentProviderLockUnknownClearPolls: Int = 6

    private var agentStatusTimer: Timer? = nil
    private var agentObserved: [UUID: AgentObservedState] = [:]
    private var agentStable: [UUID: AgentStableState] = [:]
    private var agentProviderLocks: [UUID: AgentProviderLockState] = [:]
    private var agentUnknownScanCursor: Int = 0

    // Focused-surface autodetection trace (on-demand diagnostics).
    private var focusedAgentTraceEnabled: Bool = false
    private var focusedAgentTraceStartedAt: Date? = nil
    private var focusedAgentTracePollIndex: UInt64 = 0
    private var focusedAgentTraceLines: [String] = []
    private var focusedAgentTraceLastViewportHash: Int? = nil
    private var focusedAgentTraceLastSurfaceId: UUID? = nil
    private var focusedAgentTraceAutoExportWorkItem: DispatchWorkItem? = nil
    private var agentDebugLogAutoExportWorkItem: DispatchWorkItem? = nil

    private let focusedAgentTraceAutoCaptureSeconds: TimeInterval = 5.0

    // Always-on lightweight trace for auto-focus attention decisions (no viewport capture).
    private var autoFocusTraceSeq: UInt64 = 0
    private var autoFocusTraceStartedAt: Date? = nil
    private var autoFocusTraceRing: [String?] = []
    private var autoFocusTraceRingWriteIndex: Int = 0
    private var autoFocusTraceRingCount: Int = 0
    private let autoFocusTraceDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    var focusedAgentTraceActive: Bool {
        focusedAgentTraceEnabled
    }

    /// The time that undo/redo operations that contain running ptys are valid for.
    var undoExpiration: Duration {
        ghostty.config.undoTimeout
    }

    /// The undo manager for this controller is the undo manager of the window,
    /// which we set via the delegate method.
    override var undoManager: ExpiringUndoManager? {
        // This should be set via the delegate method windowWillReturnUndoManager
        if let result = window?.undoManager as? ExpiringUndoManager {
            return result
        }

        // If the window one isn't set, we fallback to our global one.
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            return appDelegate.undoManager
        }

        return nil
    }

    struct SavedFrame {
        let window: NSRect
        let screen: NSRect
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    init(_ ghostty: Ghostty.App,
         baseConfig base: Ghostty.SurfaceConfiguration? = nil,
         surfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil
    ) {
        self.ghostty = ghostty
        self.derivedConfig = DerivedConfig(ghostty.config)

        super.init(window: nil)

        // Initialize our initial surface.
        guard let ghostty_app = ghostty.app else { preconditionFailure("app must be loaded") }
        self.surfaceTree = tree ?? .init(view: Ghostty.SurfaceView(ghostty_app, baseConfig: base))

        // Setup our notifications for behaviors
        let center = NotificationCenter.default
        center.addObserver(
            self,
            selector: #selector(onConfirmClipboardRequest),
            name: Ghostty.Notification.confirmClipboard,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(didChangeScreenParametersNotification),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyConfigDidChangeBase(_:)),
            name: .ghosttyConfigDidChange,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyCommandPaletteDidToggle(_:)),
            name: .ghosttyCommandPaletteDidToggle,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyMaximizeDidToggle(_:)),
            name: .ghosttyMaximizeDidToggle,
            object: nil)

        // Splits
        center.addObserver(
            self,
            selector: #selector(ghosttyDidCloseSurface(_:)),
            name: Ghostty.Notification.ghosttyCloseSurface,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidNewSplit(_:)),
            name: Ghostty.Notification.ghosttyNewSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidEqualizeSplits(_:)),
            name: Ghostty.Notification.didEqualizeSplits,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidFocusSplit(_:)),
            name: Ghostty.Notification.ghosttyFocusSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidToggleSplitZoom(_:)),
            name: Ghostty.Notification.didToggleSplitZoom,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidResizeSplit(_:)),
            name: Ghostty.Notification.didResizeSplit,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidPresentTerminal(_:)),
            name: Ghostty.Notification.ghosttyPresentTerminal,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttyDidGotoAttention(_:)),
            name: Ghostty.Notification.ghosttyGotoAttention,
            object: nil)
        center.addObserver(
            self,
            selector: #selector(ghosttySurfaceDragEndedNoTarget(_:)),
            name: .ghosttySurfaceDragEndedNoTarget,
            object: nil)

        // Attention marks (bell/notifications). Used for auto-focus-attention.
        center.addObserver(
            self,
            selector: #selector(ghosttyBellDidRing(_:)),
            name: .ghosttyBellDidRing,
            object: nil)

        // Listen for local events that we need to know of outside of
        // single surface handlers.
        self.eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .flagsChanged,
                .keyDown,
                .leftMouseDown,
                .leftMouseDragged,
                .mouseMoved,
                .rightMouseDown,
                .otherMouseDown,
                .scrollWheel,
            ]
        ) { [weak self] event in self?.localEventHandler(event) }

        // Bell changes drive transient tab-level attention highlighting.
        rebindSurfaceBellObservers()

        // Start/stop agent detection (debug overlay and/or per-surface badges).
        syncAgentStatusDetection()

        // Initialize always-on auto-focus trace configuration.
        syncAutoFocusTraceConfig()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        undoManager?.removeAllActions(withTarget: self)
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        agentStatusTimer?.invalidate()
        focusedAgentTraceAutoExportWorkItem?.cancel()
        agentDebugLogAutoExportWorkItem?.cancel()
        focusedAgentTraceEnabled = false
    }

    // MARK: Methods

    /// Create a new split.
    @discardableResult
    func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        // We can only create new splits for surfaces in our tree.
        guard surfaceTree.root?.node(view: oldView) != nil else { return nil }

        // Create a new surface view
        guard let ghostty_app = ghostty.app else { return nil }
        let newView = Ghostty.SurfaceView(ghostty_app, baseConfig: config)

        // Do the split
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(
                view: newView,
                at: oldView,
                direction: direction)
        } catch {
            // If splitting fails for any reason (it should not), then we just log
            // and return. The new view we created will be deinitialized and its
            // no big deal.
            Ghostty.logger.warning("failed to insert split: \(error)")
            return nil
        }

        replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: "New Split")

        return newView
    }

    /// Move focus to a surface view.
    func focusSurface(_ view: Ghostty.SurfaceView) {
        // Check if target surface is in our tree
        guard surfaceTree.contains(view) else { return }

        // Treat programmatic focus changes as "activity" for the purposes of
        // auto-focus-attention. This prevents immediate focus cycling away from
        // a surface we just switched to (manual or automatic).
        lastUserActivityUptime = ProcessInfo.processInfo.systemUptime

        // Move focus to the target surface and activate the window/app
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: view)
            if self.ghostty.config.attentionClearOnFocus {
                // Programmatic focus changes (goto-attention / auto-focus) should
                // clear stale attention marks just like direct focus interactions.
                view.clearAttention(reason: "programmaticFocus")
            }
            view.window?.makeKeyAndOrderFront(nil)
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Called when the surfaceTree variable changed.
    ///
    /// Subclasses should call super first.
    func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        // If our surface tree becomes empty then we have no focused surface.
        if (to.isEmpty) {
            focusedSurface = nil
        }

        rebindSurfaceBellObservers()
    }

    /// Update all surfaces with the focus state. This ensures that libghostty has an accurate view about
    /// what surface is focused. This must be called whenever a surface OR window changes focus.
    func syncFocusToSurfaceTree() {
        for surfaceView in surfaceTree {
            // Our focus state requires that this window is key and our currently
            // focused surface is the surface in this view.
            let focused: Bool = (window?.isKeyWindow ?? false) &&
                !commandPaletteIsShowing &&
                focusedSurface != nil &&
                surfaceView == focusedSurface!
            surfaceView.focusDidChange(focused)
        }
    }

    private func rebindSurfaceBellObservers() {
        surfaceBellCancellables.removeAll()

        for surface in surfaceTree {
            surface.$bell
                .removeDuplicates()
                .sink { [weak self] _ in
                    self?.syncAttentionTabHighlight()
                }
                .store(in: &surfaceBellCancellables)
        }

        syncAttentionTabHighlight()
    }

    private func syncAttentionTabHighlight() {
        guard let terminalWindow = window as? TerminalWindow else { return }

        let hasPendingAttention = !attentionSurfaces(in: self, applyWatchFilter: true).isEmpty
        terminalWindow.setTransientTabColor(hasPendingAttention ? .yellow : nil)
    }

    // Call this whenever the frame changes
    private func windowFrameDidChange() {
        // We need to update our saved frame information in case of monitor
        // changes (see didChangeScreenParameters notification).
        savedFrame = nil
        guard let window, let screen = window.screen else { return }
        savedFrame = .init(window: window.frame, screen: screen.visibleFrame)
    }

    func confirmClose(
        messageText: String,
        informativeText: String,
        completion: @escaping () -> Void
    ) {
        // If we already have an alert, we need to wait for that one.
        guard alert == nil else { return }

        // If there is no window to attach the modal then we assume success
        // since we'll never be able to show the modal.
        guard let window else {
            completion()
            return
        }

        // If we need confirmation by any, show one confirmation for all windows
        // in the tab group.
        let alert = NSAlert()
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window) { response in
            let alertWindow = alert.window
            self.alert = nil
            if response == .alertFirstButtonReturn {
                // This is important so that we avoid losing focus when Stage
                // Manager is used (#8336)
                alertWindow.orderOut(nil)
                completion()
            }
        }

        // Store our alert so we only ever show one.
        self.alert = alert
    }

    /// Prompt the user to change the tab/window title.
    func promptTabTitle() {
        guard let window else { return }

        let alert = NSAlert()
        alert.messageText = "Change Tab Title"
        alert.informativeText = "Leave blank to restore the default."
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = titleOverride ?? window.title
        alert.accessoryView = textField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }

            let newTitle = textField.stringValue
            if newTitle.isEmpty {
                self.titleOverride = nil
            } else {
                self.titleOverride = newTitle
            }
        }
    }

    struct QuickSurfaceAgentProvider {
        let token: String
        let displayName: String
    }

    static let quickSurfaceAgentProviders: [QuickSurfaceAgentProvider] = [
        .init(token: "codex", displayName: "Codex"),
        .init(token: "opencode", displayName: "OpenCode"),
        .init(token: "ag-tui", displayName: "AG-TUI"),
        .init(token: "claude", displayName: "Claude"),
        .init(token: "vibe", displayName: "Vibe"),
        .init(token: "gemini", displayName: "Gemini"),
    ]

    func markSurfaceAgent(_ name: String, surface: Ghostty.SurfaceView? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let target = surface ?? focusedSurface
        target?.setAttentionAgentTag(
            name: trimmed,
            prefix: ghostty.config.attentionSurfaceTagPrefix,
            suffix: ghostty.config.attentionSurfaceTagSuffix
        )
    }

    func promptSurfaceAgentMark(_ surface: Ghostty.SurfaceView? = nil) {
        guard let window else { return }
        guard let target = surface ?? focusedSurface else { return }

        let alert = NSAlert()
        alert.messageText = "Mark Terminal as Agent"
        alert.informativeText = "Enter a provider name such as codex or opencode."
        alert.alertStyle = .informational

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        textField.stringValue = "codex"
        alert.accessoryView = textField

        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = textField

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertFirstButtonReturn else { return }

            let name = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            self.markSurfaceAgent(name, surface: target)
        }
    }

    func clearSurfaceAgentMark(_ surface: Ghostty.SurfaceView? = nil) {
        let target = surface ?? focusedSurface
        target?.clearAttentionAgentTag(
            prefix: ghostty.config.attentionSurfaceTagPrefix,
            suffix: ghostty.config.attentionSurfaceTagSuffix
        )
    }

    func exportAgentAutodetectionDebugLog(_ surface: Ghostty.SurfaceView? = nil) {
        guard window != nil else { return }
        guard let target = surface ?? focusedSurface else { return }

        let targetSurfaceId = target.id

        // If a focused trace is already running, export immediately.
        if focusedAgentTraceEnabled {
            finalizeFocusedAgentTrace(reason: "export-debug")
            if let resolvedTarget = resolveSurfaceForAgentDebugExport(preferredSurfaceId: targetSurfaceId) {
                exportAgentAutodetectionDebugLogToSavePanel(targetSurface: resolvedTarget)
            }
            return
        }

        // Otherwise, auto-capture a short trace window before exporting.
        startFocusedAgentAutodetectionTrace()

        agentDebugLogAutoExportWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.agentDebugLogAutoExportWorkItem = nil

            if self.focusedAgentTraceEnabled {
                self.finalizeFocusedAgentTrace(reason: "export-debug-auto")
            }
            guard let resolvedTarget = self.resolveSurfaceForAgentDebugExport(preferredSurfaceId: targetSurfaceId) else {
                return
            }
            self.exportAgentAutodetectionDebugLogToSavePanel(targetSurface: resolvedTarget)
        }

        agentDebugLogAutoExportWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + focusedAgentTraceAutoCaptureSeconds, execute: work)
    }


    private func resolveSurfaceForAgentDebugExport(preferredSurfaceId: UUID) -> Ghostty.SurfaceView? {
        if let window {
            let controllers: [BaseTerminalController] = (window.tabGroup?.windows ?? [window])
                .compactMap { $0.windowController as? BaseTerminalController }
            let surfaces: [Ghostty.SurfaceView] = controllers.flatMap { $0.surfaceTree.map { $0 } }
            if let match = surfaces.first(where: { $0.id == preferredSurfaceId }) {
                return match
            }
        }

        return windowFirstResponderSurfaceView() ?? focusedSurface
    }

    private func agentBadgeSummary(for surface: Ghostty.SurfaceView?) -> String {
        guard let surface else { return "none" }

        let provider = surface.attentionAgentBadgeProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty else { return "none" }

        let sourceSuffix: String = {
            switch surface.attentionAgentBadgeSource {
            case .marked: return "M"
            case .detected: return "A"
            case .diagnostic: return "D"
            case .none: return ""
            }
        }()

        if sourceSuffix.isEmpty { return provider }
        return "\(provider) \(sourceSuffix)"
    }

    private func copyExportPathToClipboardAndNotify(url: URL, surface: Ghostty.SurfaceView?, kind: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)

        let badgeSummary = agentBadgeSummary(for: surface)
        let message = "\(kind) exported. Path copied to clipboard. current surface area showing badge '\(badgeSummary)'"
        Ghostty.logger.info("\(message, privacy: .public)")

        if ghostty.config.desktopNotifications, let surface {
            surface.showUserNotification(title: "Ghostty Export", body: message)
        }
    }
    private func exportAgentAutodetectionDebugLogToSavePanel(targetSurface: Ghostty.SurfaceView) {
        guard let window else { return }

        let panel = NSSavePanel()
        panel.title = "Export Agent Detection Snapshot"
        panel.message = "Exports a one-shot snapshot of title, visible terminal text, and heuristic inputs."
        panel.nameFieldStringValue = "ghostty-agent-detection-\(debugLogTimestamp()).log"
        panel.canCreateDirectories = true
        panel.allowedFileTypes = ["log", "txt"]
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }

            do {
                let payload = self.buildAgentAutodetectionDebugLog(targetSurface: targetSurface)
                try payload.write(to: url, atomically: true, encoding: .utf8)
                Ghostty.logger.info("exported agent detection debug log to \(url.path, privacy: .public)")
                self.copyExportPathToClipboardAndNotify(url: url, surface: targetSurface, kind: "Agent detection snapshot")
            } catch {
                let alert = NSAlert()
                alert.messageText = "Failed to Export Detection Log"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    func startFocusedAgentAutodetectionTrace() {
        guard !focusedAgentTraceEnabled else { return }

        focusedAgentTraceAutoExportWorkItem?.cancel()
        focusedAgentTraceAutoExportWorkItem = nil
        agentDebugLogAutoExportWorkItem?.cancel()
        agentDebugLogAutoExportWorkItem = nil

        focusedAgentTraceEnabled = true
        focusedAgentTraceStartedAt = Date()
        focusedAgentTracePollIndex = 0
        focusedAgentTraceLines.removeAll(keepingCapacity: true)
        focusedAgentTraceLastViewportHash = nil
        focusedAgentTraceLastSurfaceId = nil

        appendFocusedAgentTraceHeader()
        syncAgentStatusDetection()
        captureFocusedAgentTracePoll(reason: "start")
    }

    func stopFocusedAgentAutodetectionTrace() {
        finalizeFocusedAgentTrace(reason: "stop")
    }

    func exportFocusedAgentAutodetectionTraceAndStop() {
        guard window != nil else { return }

        // If a focused trace is already running, export immediately.
        if focusedAgentTraceEnabled {
            finalizeFocusedAgentTrace(reason: "export")
            exportFocusedAgentAutodetectionTraceToSavePanel()
            return
        }

        // Otherwise, auto-capture a short trace window before exporting.
        startFocusedAgentAutodetectionTrace()

        focusedAgentTraceAutoExportWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.focusedAgentTraceAutoExportWorkItem = nil

            if self.focusedAgentTraceEnabled {
                self.finalizeFocusedAgentTrace(reason: "export-auto")
            }
            self.exportFocusedAgentAutodetectionTraceToSavePanel()
        }

        focusedAgentTraceAutoExportWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + focusedAgentTraceAutoCaptureSeconds, execute: work)
    }

    private func exportFocusedAgentAutodetectionTraceToSavePanel() {
        guard let window else { return }

        guard !focusedAgentTraceLines.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Agent Trace Data"
            alert.informativeText = "Start a focused detection trace first, then export it."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window, completionHandler: nil)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Focused Agent Detection Poll Trace"
        panel.message = "Exports per-poll autodetection diagnostics for the active surface only."
        panel.nameFieldStringValue = "ghostty-agent-focused-trace-\(debugLogTimestamp()).log"
        panel.canCreateDirectories = true
        panel.allowedFileTypes = ["log", "txt"]
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }

            do {
                let payload = self.focusedAgentTraceLines.joined(separator: "\n")
                try payload.write(to: url, atomically: true, encoding: .utf8)
                Ghostty.logger.info("exported focused agent trace to \(url.path, privacy: .public)")
                let target = self.windowFirstResponderSurfaceView() ?? self.focusedSurface
                self.copyExportPathToClipboardAndNotify(url: url, surface: target, kind: "Focused agent poll trace")
            } catch {
                let alert = NSAlert()
                alert.messageText = "Failed to Export Focused Trace"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    func clearAutoFocusAttentionTrace() {
        let wasEnabled = autoFocusTraceIsEnabled()
        clearAutoFocusTraceBuffer(keepEnabled: true)
        if wasEnabled {
            recordAutoFocusTrace(event: "trace-cleared", reason: "manual")
        }
    }

    func exportAutoFocusAttentionTrace() {
        guard let window else { return }

        let lines = autoFocusTraceSnapshotLines()
        guard !lines.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Auto-Focus Trace Data"
            alert.informativeText = "Enable attention-auto-focus-trace and reproduce the issue first."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window, completionHandler: nil)
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Auto-Focus Attention Trace"
        panel.message = "Exports always-on auto-focus decision timeline (no terminal output)."
        panel.nameFieldStringValue = "ghostty-auto-focus-trace-\(debugLogTimestamp()).log"
        panel.canCreateDirectories = true
        panel.allowedFileTypes = ["log", "txt"]
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }

            do {
                let payload = self.buildAutoFocusTraceLog()
                try payload.write(to: url, atomically: true, encoding: .utf8)
                Ghostty.logger.info("exported auto-focus trace to \(url.path, privacy: .public)")
                let target = self.windowFirstResponderSurfaceView() ?? self.focusedSurface
                self.copyExportPathToClipboardAndNotify(url: url, surface: target, kind: "Auto-focus trace")
            } catch {
                let alert = NSAlert()
                alert.messageText = "Failed to Export Auto-Focus Trace"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .critical
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    private func autoFocusTraceIsEnabled() -> Bool {
        ghostty.config.attentionAutoFocusTrace
    }

    private func normalizedAutoFocusTraceCapacity() -> Int {
        let raw = Int(ghostty.config.attentionAutoFocusTraceCapacity)
        let fallback = 4000
        let v = raw > 0 ? raw : fallback
        return max(128, min(v, 20000))
    }

    private func clearAutoFocusTraceBuffer(keepEnabled: Bool = false) {
        autoFocusTraceSeq = 0
        autoFocusTraceStartedAt = nil
        autoFocusTraceRingWriteIndex = 0
        autoFocusTraceRingCount = 0
        autoFocusTraceRing.removeAll(keepingCapacity: false)

        if keepEnabled, autoFocusTraceIsEnabled() {
            autoFocusTraceRing = Array(repeating: nil, count: normalizedAutoFocusTraceCapacity())
            autoFocusTraceStartedAt = Date()
        }
    }

    private func syncAutoFocusTraceConfig() {
        guard autoFocusTraceIsEnabled() else {
            clearAutoFocusTraceBuffer(keepEnabled: false)
            return
        }

        let capacity = normalizedAutoFocusTraceCapacity()
        if autoFocusTraceRing.count != capacity {
            let old = autoFocusTraceSnapshotLines().suffix(capacity)
            autoFocusTraceRing = Array(repeating: nil, count: capacity)
            autoFocusTraceRingWriteIndex = 0
            autoFocusTraceRingCount = 0
            for line in old {
                appendAutoFocusTraceLine(line)
            }
        } else if autoFocusTraceRing.isEmpty {
            autoFocusTraceRing = Array(repeating: nil, count: capacity)
        }

        if autoFocusTraceStartedAt == nil {
            autoFocusTraceStartedAt = Date()
            recordAutoFocusTrace(event: "trace-enabled", reason: "config")
        }
    }

    private func appendAutoFocusTraceLine(_ line: String) {
        guard !autoFocusTraceRing.isEmpty else { return }
        autoFocusTraceRing[autoFocusTraceRingWriteIndex] = line
        autoFocusTraceRingWriteIndex = (autoFocusTraceRingWriteIndex + 1) % autoFocusTraceRing.count
        if autoFocusTraceRingCount < autoFocusTraceRing.count {
            autoFocusTraceRingCount += 1
        }
    }

    private func autoFocusTraceSnapshotLines() -> [String] {
        guard autoFocusTraceRingCount > 0, !autoFocusTraceRing.isEmpty else { return [] }

        var lines: [String] = []
        lines.reserveCapacity(autoFocusTraceRingCount)
        let start = (autoFocusTraceRingWriteIndex - autoFocusTraceRingCount + autoFocusTraceRing.count) % autoFocusTraceRing.count
        for i in 0..<autoFocusTraceRingCount {
            let idx = (start + i) % autoFocusTraceRing.count
            if let line = autoFocusTraceRing[idx] {
                lines.append(line)
            }
        }

        return lines
    }

    private func traceQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        return "\"\(escaped)\""
    }

    private func traceShortId(_ id: UUID?) -> String {
        guard let id else { return "-" }
        return String(id.uuidString.prefix(8))
    }

    private func traceShortSurface(_ surface: Ghostty.SurfaceView?) -> String {
        traceShortId(surface?.id)
    }

    private func recordAutoFocusTrace(
        event: String,
        reason: String? = nil,
        target: Ghostty.SurfaceView? = nil,
        details: [String: String] = [:]
    ) {
        guard autoFocusTraceIsEnabled() else { return }
        syncAutoFocusTraceConfig()

        autoFocusTraceSeq &+= 1

        let nowUptime = ProcessInfo.processInfo.systemUptime
        let pendingAgeMs: Int = {
            guard let since = autoFocusAttentionPendingSinceUptime else { return -1 }
            return Int(max(0, (nowUptime - since) * 1000.0))
        }()

        var parts: [String] = []
        parts.append("seq=\(autoFocusTraceSeq)")
        parts.append("ts=\(traceQuoted(autoFocusTraceDateFormatter.string(from: Date())))")
        parts.append("uptime=\(String(format: "%.3f", nowUptime))")
        parts.append("event=\(traceQuoted(event))")
        if let reason {
            parts.append("reason=\(traceQuoted(reason))")
        }

        parts.append("window=\(window?.windowNumber ?? -1)")
        parts.append("watch_mode=\(traceQuoted(ghostty.config.autoFocusAttentionWatchMode.rawValue))")
        parts.append("pending=\(autoFocusAttentionPending ? 1 : 0)")
        parts.append("pending_age_ms=\(pendingAgeMs)")
        parts.append("token=\(autoFocusAttentionToken)")
        parts.append("focused=\(traceShortSurface(windowFirstResponderSurfaceView() ?? focusedSurface))")
        parts.append("lock=\(traceShortId(autoFocusAttentionFocusLockSurfaceId))")
        parts.append("paused=\(traceShortId(autoFocusAttentionPausedSurfaceId))")

        let bellSurfaces = attentionSurfacesAcrossTabGroup(applyWatchFilter: false)
        let watchableCount = bellSurfaces.filter { isAttentionSurfaceWatchableForTrace($0) }.count
        let allCount = bellSurfaces.count
        parts.append("marks_watchable=\(watchableCount)")
        parts.append("marks_all=\(allCount)")

        if let target {
            parts.append("target=\(traceShortSurface(target))")
            parts.append("target_window=\(target.window?.windowNumber ?? -1)")
            parts.append("target_watchable=\(isAttentionSurfaceWatchableForTrace(target) ? 1 : 0)")
            parts.append("target_bell=\(target.bell ? 1 : 0)")
            parts.append("target_badge=\(traceQuoted(agentBadgeSummary(for: target)))")
        }

        if !details.isEmpty {
            for key in details.keys.sorted() {
                if let value = details[key] {
                    parts.append("\(key)=\(traceQuoted(value))")
                }
            }
        }

        appendAutoFocusTraceLine(parts.joined(separator: " "))
    }

    private func buildAutoFocusTraceLog() -> String {
        var lines: [String] = []
        lines.append("# Ghostty Auto-Focus Attention Trace")
        lines.append("generated_at=\(autoFocusTraceDateFormatter.string(from: Date()))")
        if let started = autoFocusTraceStartedAt {
            lines.append("started_at=\(autoFocusTraceDateFormatter.string(from: started))")
        }
        lines.append("trace_enabled=\(autoFocusTraceIsEnabled())")
        lines.append("trace_capacity=\(autoFocusTraceRing.count)")
        lines.append("trace_events=\(autoFocusTraceRingCount)")
        lines.append("auto_focus_attention=\(ghostty.config.autoFocusAttention)")
        lines.append("auto_focus_attention_idle_ms=\(ghostty.config.autoFocusAttentionIdle)")
        lines.append("auto_focus_attention_resume_delay_ms=\(ghostty.config.autoFocusAttentionResumeDelay)")
        lines.append("auto_focus_attention_min_age_ms=\(ghostty.config.autoFocusAttentionMinAge)")
        lines.append("auto_focus_attention_resume_on_surface_switch=\(ghostty.config.autoFocusAttentionResumeOnSurfaceSwitch)")
        lines.append("auto_focus_attention_resume_on_focused_idle_ms=\(ghostty.config.autoFocusAttentionResumeOnFocusedIdle)")
        lines.append("auto_focus_attention_watch_mode=\(ghostty.config.autoFocusAttentionWatchMode.rawValue)")
        lines.append("attention_watch_providers=\(ghostty.config.attentionWatchProviders)")
        lines.append("attention_provider_lock=\(ghostty.config.attentionProviderLock)")
        lines.append("")

        lines.append(contentsOf: autoFocusTraceSnapshotLines())
        return lines.joined(separator: "\n")
    }

    private func captureFocusedAgentTracePollIfActive(
        reason: String,
        surfaces: [Ghostty.SurfaceView]? = nil
    ) {
        guard focusedAgentTraceEnabled else { return }
        captureFocusedAgentTracePoll(reason: reason, surfaces: surfaces)
    }

    private func finalizeFocusedAgentTrace(reason: String) {
        focusedAgentTraceAutoExportWorkItem?.cancel()
        focusedAgentTraceAutoExportWorkItem = nil
        agentDebugLogAutoExportWorkItem?.cancel()
        agentDebugLogAutoExportWorkItem = nil

        let wasActive = focusedAgentTraceEnabled
        focusedAgentTraceEnabled = false

        if wasActive {
            captureFocusedAgentTracePoll(reason: reason)
        }

        guard !focusedAgentTraceLines.isEmpty else { return }

        if focusedAgentTraceLines.last?.hasPrefix("# End focused trace") != true {
            appendFocusedAgentTraceFooter(reason: reason)
        }

        syncAgentStatusDetection()
    }

    private func appendFocusedAgentTraceHeader() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        focusedAgentTraceLines.append("# Ghostty Focused Agent Detection Trace")
        focusedAgentTraceLines.append("started_at=\(iso.string(from: Date()))")
        focusedAgentTraceLines.append("auto_focus_attention_watch_mode=\(ghostty.config.autoFocusAttentionWatchMode.rawValue)")
        focusedAgentTraceLines.append("attention_autodetect_diagnostics=\(ghostty.config.attentionAutodetectDiagnostics.rawValue)")
        focusedAgentTraceLines.append("attention_watch_providers=\(ghostty.config.attentionWatchProviders)")
        focusedAgentTraceLines.append("attention_surface_tag_providers=\(ghostty.config.attentionSurfaceTagProviders)")
        focusedAgentTraceLines.append("attention_provider_lock=\(ghostty.config.attentionProviderLock)")
        focusedAgentTraceLines.append("attention_surface_tag_prefix=\(ghostty.config.attentionSurfaceTagPrefix)")
        focusedAgentTraceLines.append("attention_surface_tag_suffix=\(ghostty.config.attentionSurfaceTagSuffix)")
        focusedAgentTraceLines.append("attention_surface_tag_allow_any=\(ghostty.config.attentionSurfaceTagAllowAny)")
        focusedAgentTraceLines.append("")
    }

    private func appendFocusedAgentTraceFooter(reason: String) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        focusedAgentTraceLines.append("# End focused trace")
        focusedAgentTraceLines.append("ended_at=\(iso.string(from: Date()))")
        focusedAgentTraceLines.append("end_reason=\(reason)")
    }

    private func captureFocusedAgentTracePoll(
        reason: String,
        surfaces: [Ghostty.SurfaceView]? = nil
    ) {
        focusedAgentTracePollIndex &+= 1

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        focusedAgentTraceLines.append("[poll.\(focusedAgentTracePollIndex)]")
        focusedAgentTraceLines.append("timestamp=\(iso.string(from: Date()))")
        focusedAgentTraceLines.append("reason=\(reason)")
        let nowUptime = ProcessInfo.processInfo.systemUptime
        focusedAgentTraceLines.append("uptime=\(nowUptime)")

        if let started = focusedAgentTraceStartedAt {
            let elapsedMs = Int(Date().timeIntervalSince(started) * 1000.0)
            focusedAgentTraceLines.append("elapsed_ms=\(elapsedMs)")
        }

        let activeSurface = windowFirstResponderSurfaceView() ?? focusedSurface
        let surface = activeSurface ?? surfaces?.first(where: { $0.id == focusedSurface?.id }) ?? surfaces?.first

        guard let surface else {
            focusedAgentTraceLines.append("active_surface=<none>")
            focusedAgentTraceLines.append("")
            return
        }

        let title = surface.title
        let explicitMark = extractAttentionAgentTag(title)
        let viewportText = surface.cachedVisibleContents.get()
        let titleProvider = detectAgentProviderFromTitle(title)
        let viewportProvider = detectAgentProviderFromViewport(viewportText)
        let viewportHash = viewportText.hashValue
        let viewportChanged = (focusedAgentTraceLastViewportHash != viewportHash) || (focusedAgentTraceLastSurfaceId != surface.id)

        focusedAgentTraceLines.append("surface_id=\(surface.id.uuidString)")
        focusedAgentTraceLines.append("surface_focused=\(focusedSurface?.id == surface.id)")
        focusedAgentTraceLines.append("surface_bell=\(surface.bell)")
        focusedAgentTraceLines.append("title=\(title.isEmpty ? "<empty>" : title)")
        focusedAgentTraceLines.append("pwd=\(surface.pwd ?? "<nil>")")
        focusedAgentTraceLines.append("explicit_mark=\(explicitMark ?? "<none>")")
        focusedAgentTraceLines.append("watchable_under_current_mode=\(isAttentionSurfaceWatchable(surface))")
        focusedAgentTraceLines.append("title_provider=\(titleProvider.rawValue)")
        focusedAgentTraceLines.append("viewport_provider=\(viewportProvider.rawValue)")

        if let stable = agentStable[surface.id] {
            focusedAgentTraceLines.append("stable.provider=\(stable.provider.rawValue)")
            focusedAgentTraceLines.append("stable.status=\(stable.status.rawValue)")
            focusedAgentTraceLines.append("stable.badge_provider=\(stable.badgeProvider ?? "<none>")")
            focusedAgentTraceLines.append("stable.source=\(stable.source.rawValue)")
        } else {
            focusedAgentTraceLines.append("stable=<none>")
        }

        if let observed = agentObserved[surface.id] {
            focusedAgentTraceLines.append("observed.provider=\(observed.provider.rawValue)")
            focusedAgentTraceLines.append("observed.status=\(observed.status.rawValue)")
            focusedAgentTraceLines.append("observed.badge_provider=\(observed.badgeProvider ?? "<none>")")
            focusedAgentTraceLines.append("observed.source=\(observed.source.rawValue)")
            focusedAgentTraceLines.append("observed.since_uptime=\(observed.sinceUptime)")
        } else {
            focusedAgentTraceLines.append("observed=<none>")
        }

        if let lock = agentProviderLocks[surface.id] {
            focusedAgentTraceLines.append("lock.provider=\(lock.provider.rawValue)")
            focusedAgentTraceLines.append("lock.mismatch_provider=\(lock.mismatchProvider.rawValue)")
            focusedAgentTraceLines.append("lock.mismatch_count=\(lock.mismatchCount)")
            focusedAgentTraceLines.append("lock.unknown_idle_prompt_count=\(lock.unknownIdlePromptCount)")
            focusedAgentTraceLines.append("lock.unknown_streak_count=\(lock.unknownStreakCount)")
            let lockAgeMs = Int(max(0, (nowUptime - lock.lastPositiveEvidenceUptime) * 1000.0))
            focusedAgentTraceLines.append("lock.last_positive_age_ms=\(lockAgeMs)")
        } else {
            focusedAgentTraceLines.append("lock=<none>")
        }

        focusedAgentTraceLines.append("viewport_hash=\(viewportHash)")
        focusedAgentTraceLines.append("viewport_changed=\(viewportChanged)")

        if viewportChanged {
            let tail = lastLines(nonEmptyLines(viewportText), count: 40)
            focusedAgentTraceLines.append("viewport_tail_begin")
            focusedAgentTraceLines.append(tail)
            focusedAgentTraceLines.append("viewport_tail_end")
        }

        focusedAgentTraceLines.append("")

        focusedAgentTraceLastViewportHash = viewportHash
        focusedAgentTraceLastSurfaceId = surface.id
    }

    private func debugLogTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func buildAgentAutodetectionDebugLog(targetSurface: Ghostty.SurfaceView) -> String {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let currentWindow = window
        let tabWindows: [NSWindow] = if let currentWindow {
            currentWindow.tabGroup?.windows ?? [currentWindow]
        } else {
            []
        }
        let controllers: [BaseTerminalController] = tabWindows.compactMap { $0.windowController as? BaseTerminalController }
        let surfaces: [Ghostty.SurfaceView] = controllers.flatMap { $0.surfaceTree.map { $0 } }

        let focusedId = focusedSurface?.id
        let watchedRaw = ghostty.config.attentionWatchProviders
        let watchedCanonical = watchedProviders().sorted().joined(separator: ",")
        let tagProvidersRaw = ghostty.config.attentionSurfaceTagProviders
        let tagProvidersCanonical = parseProviderSet(tagProvidersRaw).sorted().joined(separator: ",")
        let tagProvidersEffectiveCanonical = surfaceTagProviders().sorted().joined(separator: ",")
        let diagnosticsMode = ghostty.config.attentionAutodetectDiagnostics
        let autoDetectionEnabled = agentAutodetectionEnabled()

        var lines: [String] = []
        lines.reserveCapacity(200)

        lines.append("# Ghostty Agent Autodetection Debug Snapshot")
        lines.append("generated_at=\(isoFormatter.string(from: Date()))")
        lines.append("target_surface_id=\(targetSurface.id.uuidString)")
        lines.append("")

        lines.append("[config]")
        lines.append("auto_focus_attention_watch_mode=\(ghostty.config.autoFocusAttentionWatchMode.rawValue)")
        lines.append("attention_watch_providers_raw=\(watchedRaw)")
        lines.append("attention_watch_providers_canonical=\(watchedCanonical)")
        lines.append("attention_provider_lock=\(ghostty.config.attentionProviderLock)")
        lines.append("attention_surface_tag_prefix=\(ghostty.config.attentionSurfaceTagPrefix)")
        lines.append("attention_surface_tag_suffix=\(ghostty.config.attentionSurfaceTagSuffix)")
        lines.append("attention_surface_tag_allow_any=\(ghostty.config.attentionSurfaceTagAllowAny)")
        lines.append("attention_surface_tag_providers_raw=\(tagProvidersRaw)")
        lines.append("attention_surface_tag_providers_canonical=\(tagProvidersCanonical)")
        lines.append("attention_surface_tag_providers_effective_canonical=\(tagProvidersEffectiveCanonical)")
        lines.append("attention_debug=\(ghostty.config.attentionDebug)")
        lines.append("agent_status_stable_ms=\(ghostty.config.agentStatusStable)")
        lines.append("attention_autodetect_diagnostics=\(diagnosticsMode.rawValue)")
        lines.append("auto_detection_enabled=\(autoDetectionEnabled)")
        lines.append("")

        lines.append("[tab-group]")
        lines.append("window_count=\(tabWindows.count)")
        lines.append("surface_count=\(surfaces.count)")
        lines.append("")

        for (index, surface) in surfaces.enumerated() {
            let title = surface.title
            let explicitMark = extractAttentionAgentTag(title)
            let titleProvider = autoDetectionEnabled ? detectAgentProviderFromTitle(title) : .unknown
            let viewportText = surface.cachedVisibleContents.get()
            let viewportProvider = autoDetectionEnabled ? detectAgentProviderFromViewport(viewportText) : .unknown
            let isTarget = surface.id == targetSurface.id
            let isFocused = surface.id == focusedId

            lines.append("[surface.\(index + 1)]")
            lines.append("id=\(surface.id.uuidString)")
            lines.append("target=\(isTarget)")
            lines.append("focused=\(isFocused)")
            lines.append("bell=\(surface.bell)")
            lines.append("title=\(title.isEmpty ? "<empty>" : title)")
            lines.append("pwd=\(surface.pwd ?? "<nil>")")
            lines.append("explicit_mark=\(explicitMark ?? "<none>")")
            lines.append("title_provider=\(titleProvider.rawValue)")
            lines.append("viewport_provider=\(viewportProvider.rawValue)")
            lines.append("watchable_under_current_mode=\(isAttentionSurfaceWatchable(surface))")

            if let stable = agentStable[surface.id] {
                lines.append("stable.provider=\(stable.provider.rawValue)")
                lines.append("stable.status=\(stable.status.rawValue)")
                lines.append("stable.badge_provider=\(stable.badgeProvider ?? "<none>")")
                lines.append("stable.source=\(stable.source.rawValue)")
            } else {
                lines.append("stable=<none>")
            }

            if let observed = agentObserved[surface.id] {
                lines.append("observed.provider=\(observed.provider.rawValue)")
                lines.append("observed.status=\(observed.status.rawValue)")
                lines.append("observed.badge_provider=\(observed.badgeProvider ?? "<none>")")
                lines.append("observed.source=\(observed.source.rawValue)")
                lines.append("observed.since_uptime=\(observed.sinceUptime)")
            } else {
                lines.append("observed=<none>")
            }

            if let lock = agentProviderLocks[surface.id] {
                lines.append("lock.provider=\(lock.provider.rawValue)")
                lines.append("lock.mismatch_provider=\(lock.mismatchProvider.rawValue)")
                lines.append("lock.mismatch_count=\(lock.mismatchCount)")
                lines.append("lock.unknown_idle_prompt_count=\(lock.unknownIdlePromptCount)")
                lines.append("lock.unknown_streak_count=\(lock.unknownStreakCount)")
                let lockAgeMs = Int(max(0, (ProcessInfo.processInfo.systemUptime - lock.lastPositiveEvidenceUptime) * 1000.0))
                lines.append("lock.last_positive_age_ms=\(lockAgeMs)")
            } else {
                lines.append("lock=<none>")
            }

            for provider in AgentProvider.allCases where provider != .unknown {
                let status = detectAgentStatus(provider: provider, viewportText: viewportText)
                lines.append("heuristic.status.\(provider.rawValue)=\(status.rawValue)")
            }

            lines.append("viewport_text_begin")
            lines.append(viewportText)
            lines.append("viewport_text_end")
            lines.append("")
        }

        lines.append("# End of snapshot")
        return lines.joined(separator: "\n")
    }

    /// Close a surface from a view.
    func closeSurface(
        _ view: Ghostty.SurfaceView,
        withConfirmation: Bool = true
    ) {
        guard let node = surfaceTree.root?.node(view: view) else { return }
        closeSurface(node, withConfirmation: withConfirmation)
    }

    /// Close a surface node (which may contain splits), requesting confirmation if necessary.
    ///
    /// This will also insert the proper undo stack information in.
    func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // This node must be part of our tree
        guard surfaceTree.contains(node) else { return }

        // If the child process is not alive, then we exit immediately
        guard withConfirmation else {
            removeSurfaceNode(node)
            return
        }

        // Confirm close. We use an NSAlert instead of a SwiftUI confirmationDialog
        // due to SwiftUI bugs (see Ghostty #560). To repeat from #560, the bug is that
        // confirmationDialog allows the user to Cmd-W close the alert, but when doing
        // so SwiftUI does not update any of the bindings to note that window is no longer
        // being shown, and provides no callback to detect this.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) { [weak self] in
            if let self {
                self.removeSurfaceNode(node)
            }
        }
    }

    // MARK: Split Tree Management

    /// Find the next surface to focus when a node is being closed.
    /// Goes to previous split unless we're the leftmost leaf, then goes to next.
    private func findNextFocusTargetAfterClosing(node: SplitTree<Ghostty.SurfaceView>.Node) -> Ghostty.SurfaceView? {
        guard let root = surfaceTree.root else { return nil }
        
        // If we're the leftmost, then we move to the next surface after closing.
        // Otherwise, we move to the previous.
        if root.leftmostLeaf() == node.leftmostLeaf() {
            return surfaceTree.focusTarget(for: .next, from: node)
        } else {
            return surfaceTree.focusTarget(for: .previous, from: node)
        }
    }
    
    /// Remove a node from the surface tree and move focus appropriately.
    ///
    /// This also updates the undo manager to support restoring this node.
    ///
    /// This does no confirmation and assumes confirmation is already done.
    private func removeSurfaceNode(_ node: SplitTree<Ghostty.SurfaceView>.Node) {
        // Move focus if the closed surface was focused and we have a next target
        let nextFocus: Ghostty.SurfaceView? = if node.contains(
            where: { $0 == focusedSurface }
        ) {
            findNextFocusTargetAfterClosing(node: node)
        } else {
            nil
        }

        replaceSurfaceTree(
            surfaceTree.removing(node),
            moveFocusTo: nextFocus,
            moveFocusFrom: focusedSurface,
            undoAction: "Close Terminal"
        )
    }

    func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // Setup our new split tree
        let oldTree = surfaceTree
        surfaceTree = newTree
        if let newView {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: newView, from: oldView)
            }
        }
        
        // Setup our undo
        guard let undoManager else { return }
        if let undoAction {
            undoManager.setActionName(undoAction)
        }
        
        undoManager.registerUndo(
            withTarget: self,
            expiresAfter: undoExpiration
        ) { target in
            target.surfaceTree = oldTree
            if let oldView {
                DispatchQueue.main.async {
                    Ghostty.moveFocus(to: oldView, from: target.focusedSurface)
                }
            }
            
            undoManager.registerUndo(
                withTarget: target,
                expiresAfter: target.undoExpiration
            ) { target in
                target.replaceSurfaceTree(
                    newTree,
                    moveFocusTo: newView,
                    moveFocusFrom: target.focusedSurface,
                    undoAction: undoAction)
            }
        }
    }

    // MARK: Notifications

    @objc private func didChangeScreenParametersNotification(_ notification: Notification) {
        // If we have a window that is visible and it is outside the bounds of the
        // screen then we clamp it back to within the screen.
        guard let window else { return }
        guard window.isVisible else { return }

        // We ignore fullscreen windows because macOS automatically resizes
        // those back to the fullscreen bounds.
        guard !window.styleMask.contains(.fullScreen) else { return }

        guard let screen = window.screen else { return }
        let visibleFrame = screen.visibleFrame
        var newFrame = window.frame

        // Clamp width/height
        if newFrame.size.width > visibleFrame.size.width {
            newFrame.size.width = visibleFrame.size.width
        }
        if newFrame.size.height > visibleFrame.size.height {
            newFrame.size.height = visibleFrame.size.height
        }

        // Ensure the window is on-screen. We only do this if the previous frame
        // was also on screen. If a user explicitly wanted their window off screen
        // then we let it stay that way.
        x: if newFrame.origin.x < visibleFrame.origin.x {
            if let savedFrame, savedFrame.window.origin.x < savedFrame.screen.origin.x {
                break x;
            }

            newFrame.origin.x = visibleFrame.origin.x
        }
        y: if newFrame.origin.y < visibleFrame.origin.y {
            if let savedFrame, savedFrame.window.origin.y < savedFrame.screen.origin.y {
                break y;
            }

            newFrame.origin.y = visibleFrame.origin.y
        }

        // Apply the new window frame
        window.setFrame(newFrame, display: true)
    }

    @objc private func ghosttyConfigDidChangeBase(_ notification: Notification) {
        // We only care if the configuration is a global configuration, not a
        // surface-specific one.
        guard notification.object == nil else { return }

        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // Update our derived config
        self.derivedConfig = DerivedConfig(config)

        // Start/stop agent detection based on debug/watch-mode config.
        syncAgentStatusDetection()
        syncAutoFocusTraceConfig()
        syncAttentionTabHighlight()
    }

    @objc private func ghosttyCommandPaletteDidToggle(_ notification: Notification) {
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        toggleCommandPalette(nil)
    }

    @objc private func ghosttyMaximizeDidToggle(_ notification: Notification) {
        guard let window else { return }
        guard let surfaceView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(surfaceView) else { return }
        window.zoom(nil)
    }

    @objc private func ghosttyDidCloseSurface(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let node = surfaceTree.root?.node(view: target) else { return }
        closeSurface(
            node,
            withConfirmation: (notification.userInfo?["process_alive"] as? Bool) ?? false)
    }

    @objc private func ghosttyDidNewSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let oldView = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.root?.node(view: oldView) != nil else { return }

        // Notification must contain our base config
        let configAny = notification.userInfo?[Ghostty.Notification.NewSurfaceConfigKey]
        let config = configAny as? Ghostty.SurfaceConfiguration

        // Determine our desired direction
        guard let directionAny = notification.userInfo?["direction"] else { return }
        guard let direction = directionAny as? ghostty_action_split_direction_e else { return }
        let splitDirection: SplitTree<Ghostty.SurfaceView>.NewDirection
        switch (direction) {
        case GHOSTTY_SPLIT_DIRECTION_RIGHT: splitDirection = .right
        case GHOSTTY_SPLIT_DIRECTION_LEFT: splitDirection = .left
        case GHOSTTY_SPLIT_DIRECTION_DOWN: splitDirection = .down
        case GHOSTTY_SPLIT_DIRECTION_UP: splitDirection = .up
        default: return
        }

        newSplit(at: oldView, direction: splitDirection, baseConfig: config)
    }

    @objc private func ghosttyDidEqualizeSplits(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        
        // Check if target surface is in current controller's tree
        guard surfaceTree.contains(target) else { return }
        
        // Equalize the splits
        surfaceTree = surfaceTree.equalized()
    }
    
    @objc private func ghosttyDidFocusSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.root?.node(view: target) != nil else { return }

        // Get the direction from the notification
        guard let directionAny = notification.userInfo?[Ghostty.Notification.SplitDirectionKey] else { return }
        guard let direction = directionAny as? Ghostty.SplitFocusDirection else { return }

        // Find the node for the target surface
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }
        
        // Find the next surface to focus
        guard let nextSurface = surfaceTree.focusTarget(for: direction.toSplitTreeFocusDirection(), from: targetNode) else {
            return
        }

        if surfaceTree.zoomed != nil {
            if derivedConfig.splitPreserveZoom.contains(.navigation) {
                surfaceTree = SplitTree(
                    root: surfaceTree.root,
                    zoomed: surfaceTree.root?.node(view: nextSurface))
            } else {
                surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
            }
        }

        // Move focus to the next surface
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: nextSurface, from: target)
        }
    }
    
    @objc private func ghosttyDidToggleSplitZoom(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }

        // Toggle the zoomed state
        if surfaceTree.zoomed == targetNode {
            // Already zoomed, unzoom it
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: nil)
        } else {
            // We require that the split tree have splits
            guard surfaceTree.isSplit else { return }

            // Not zoomed or different node zoomed, zoom this node
            surfaceTree = SplitTree(root: surfaceTree.root, zoomed: targetNode)
        }

        // Move focus to our window. Importantly this ensures that if we click the
        // reset zoom button in a tab bar of an unfocused tab that we become focused.
        window?.makeKeyAndOrderFront(nil)

        // Ensure focus stays on the target surface. We lose focus when we do
        // this so we need to grab it again.
        DispatchQueue.main.async {
            Ghostty.moveFocus(to: target)
        }
    }
    
    @objc private func ghosttyDidResizeSplit(_ notification: Notification) {
        // The target must be within our tree
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }
        
        // Extract direction and amount from notification
        guard let directionAny = notification.userInfo?[Ghostty.Notification.ResizeSplitDirectionKey] else { return }
        guard let direction = directionAny as? Ghostty.SplitResizeDirection else { return }
        
        guard let amountAny = notification.userInfo?[Ghostty.Notification.ResizeSplitAmountKey] else { return }
        guard let amount = amountAny as? UInt16 else { return }
        
        // Convert Ghostty.SplitResizeDirection to SplitTree.Spatial.Direction
        let spatialDirection: SplitTree<Ghostty.SurfaceView>.Spatial.Direction
        switch direction {
        case .up: spatialDirection = .up
        case .down: spatialDirection = .down
        case .left: spatialDirection = .left
        case .right: spatialDirection = .right
        }
        
        // Use viewBounds for the spatial calculation bounds
        let bounds = CGRect(origin: .zero, size: surfaceTree.viewBounds())
        
        // Perform the resize using the new SplitTree resize method
        do {
            surfaceTree = try surfaceTree.resizing(node: targetNode, by: amount, in: spatialDirection, with: bounds)
        } catch {
            Ghostty.logger.warning("failed to resize split: \(error)")
        }
    }

    @objc private func ghosttyDidPresentTerminal(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }

        // Bring the window to front and focus the surface.
        window?.makeKeyAndOrderFront(nil)
        
        // We use a small delay to ensure this runs after any UI cleanup
        // (e.g., command palette restoring focus to its original surface).
        Ghostty.moveFocus(to: target)
        Ghostty.moveFocus(to: target, delay: 0.1)

        // Show a brief highlight to help the user locate the presented terminal.
        target.highlight()
    }

    @objc private func ghosttyDidGotoAttention(_ notification: Notification) {
        guard let source = notification.object as? Ghostty.SurfaceView else { return }
        guard let dirAny = notification.userInfo?[Ghostty.Notification.AttentionDirectionKey] else { return }
        guard let direction = dirAny as? Ghostty.AttentionFocusDirection else { return }

        // Only handle this action for the controller that owns the source surface.
        guard surfaceTree.contains(source) else { return }

        if ghostty.config.attentionDebug {
            let msg = "attention goto received controllerWindow=\(self.window?.windowNumber ?? -1) source=\(source.id.uuidString) direction=\(String(describing: direction))"
            Ghostty.logger.info("\(msg, privacy: .public)")
        }
        cycleAttention(direction: direction, preferCurrentTab: true)
    }

    @objc private func ghosttyBellDidRing(_ notification: Notification) {
        // Auto-focus is macOS-only behavior and opt-in via config.
        guard ghostty.config.autoFocusAttention else {
            recordAutoFocusTrace(event: "bell-ignored", reason: "auto-focus-disabled")
            return
        }

        guard let target = notification.object as? Ghostty.SurfaceView else {
            recordAutoFocusTrace(event: "bell-ignored", reason: "missing-target")
            return
        }
        guard let targetWindow = target.window else {
            recordAutoFocusTrace(event: "bell-ignored", reason: "missing-target-window", target: target)
            return
        }

        // Respect watch-mode filtering before we enqueue any auto-focus work.
        guard isAttentionSurfaceWatchable(target) else {
            recordAutoFocusTrace(event: "bell-ignored", reason: "watch-filter", target: target)
            if ghostty.config.attentionDebug {
                let msg = "attention autofocusing ignored reason=watchFilter surface=\(target.id.uuidString)"
                Ghostty.logger.info("\(msg, privacy: .public)")
            }
            return
        }

        // "Current window only": keep this within the current window's tab group.
        if let myGroup = window?.tabGroup, let targetGroup = targetWindow.tabGroup {
            guard myGroup === targetGroup else {
                recordAutoFocusTrace(event: "bell-ignored", reason: "other-tab-group", target: target)
                if ghostty.config.attentionDebug {
                    let msg = "attention autofocusing ignored reason=otherTabGroup myWindow=\(self.window?.windowNumber ?? -1) targetWindow=\(targetWindow.windowNumber)"
                    Ghostty.logger.info("\(msg, privacy: .public)")
                }
                return
            }
        } else {
            guard targetWindow === window else {
                recordAutoFocusTrace(event: "bell-ignored", reason: "other-window", target: target)
                if ghostty.config.attentionDebug {
                    let msg = "attention autofocusing ignored reason=otherWindow myWindow=\(self.window?.windowNumber ?? -1) targetWindow=\(targetWindow.windowNumber)"
                    Ghostty.logger.info("\(msg, privacy: .public)")
                }
                return
            }
        }

        // Suppressed when Ghostty isn't frontmost.
        guard NSApp.isActive else {
            recordAutoFocusTrace(event: "bell-suppressed", reason: "app-inactive", target: target)
            if ghostty.config.attentionDebug {
                let msg = "attention autofocusing suppressed reason=appInactive"
                Ghostty.logger.info("\(msg, privacy: .public)")
            }
            return
        }

        // Only auto-focus from the key window for this tab group.
        guard window?.isKeyWindow ?? false else {
            recordAutoFocusTrace(event: "bell-suppressed", reason: "window-not-key", target: target)
            if ghostty.config.attentionDebug {
                let msg = "attention autofocusing suppressed reason=windowNotKey window=\(self.window?.windowNumber ?? -1)"
                Ghostty.logger.info("\(msg, privacy: .public)")
            }
            return
        }
        guard !commandPaletteIsShowing else {
            recordAutoFocusTrace(event: "bell-suppressed", reason: "command-palette", target: target)
            if ghostty.config.attentionDebug {
                let msg = "attention autofocusing suppressed reason=commandPalette"
                Ghostty.logger.info("\(msg, privacy: .public)")
            }
            return
        }

        if ghostty.config.attentionDebug {
            let msg = "attention autofocusing scheduled target=\(target.id.uuidString) window=\(targetWindow.windowNumber)"
            Ghostty.logger.info("\(msg, privacy: .public)")
        }

        autoFocusAttentionPending = true
        autoFocusAttentionPendingSinceUptime = ProcessInfo.processInfo.systemUptime
        recordAutoFocusTrace(event: "bell-accepted", reason: "scheduled", target: target)
        scheduleAutoFocusAttention()
    }

    @objc private func ghosttySurfaceDragEndedNoTarget(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard let targetNode = surfaceTree.root?.node(view: target) else { return }
        
        // If our tree isn't split, then we never create a new window, because
        // it is already a single split.
        guard surfaceTree.isSplit else { return }
        
        // If we are removing our focused surface then we move it. We need to
        // keep track of our old one so undo sends focus back to the right place.
        let oldFocusedSurface = focusedSurface
        if focusedSurface == target {
            focusedSurface = findNextFocusTargetAfterClosing(node: targetNode)
        }

        // Remove the surface from our tree
        let removedTree = surfaceTree.removing(targetNode)

        // Create a new tree with the dragged surface and open a new window
        let newTree = SplitTree<Ghostty.SurfaceView>(view: target)
        
        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Split")
        defer {
            undoManager?.endUndoGrouping()
        }
        
        replaceSurfaceTree(removedTree, moveFocusFrom: oldFocusedSurface)
        _ = TerminalController.newWindow(
            ghostty,
            tree: newTree,
            position: notification.userInfo?[Notification.Name.ghosttySurfaceDragEndedNoTargetPointKey] as? NSPoint,
            confirmUndo: false)
    }

    private func scheduleAutoFocusAttention() {
        recordAutoFocusTrace(event: "schedule", reason: "entry")
        // Do not steal focus while the user is actively "reading" a focused surface.
        // We interpret "reading" as the mouse being inside the focused surface.
        //
        // If the surface is focused but the mouse is outside it, treat that as a
        // "done reading" signal and arm the resume countdown immediately.
        if windowFirstResponderSurfaceView() != nil {
            if shouldPauseAutoFocusAttentionBecauseSurfaceFocused() {
                // Capture the surface that the user was focused on when pending began.
                if autoFocusAttentionPausedSurfaceId == nil {
                    autoFocusAttentionPausedSurfaceId = windowFirstResponderSurfaceView()?.id
                }
                armAutoFocusAttentionResumeOnFocusedIdle(reason: "focusedIdle")
                setAttentionOverlay(autoFocusAttentionPending ? "paused(focused): pending" : "paused(focused)")
                if ghostty.config.attentionDebug {
                    let msg = "attention autofocusing suppressed reason=surfaceFocused+mouseInside"
                    Ghostty.logger.info("\(msg, privacy: .public)")
                }
                return
            }

            // Surface is focused but mouse is outside: resume via resume-delay (debounced).
            resumeAutoFocusAttention(reason: "mouseOutside")
            return
        }

        // If the user is actively "reading" a focused surface (mouse inside), pause.
        // When the mouse leaves the focused surface, `surfaceMouseInsideDidChange`
        // (and our local event monitor) will call `resumeAutoFocusAttention`.
        if shouldPauseAutoFocusAttentionBecauseSurfaceFocused() {
            // Capture the surface that the user was focused on when pending began.
            if autoFocusAttentionPausedSurfaceId == nil {
                autoFocusAttentionPausedSurfaceId = windowFirstResponderSurfaceView()?.id
            }
            armAutoFocusAttentionResumeOnFocusedIdle(reason: "focusedIdle")
            setAttentionOverlay(autoFocusAttentionPending ? "paused(focused): pending" : "paused(focused)")
            if ghostty.config.attentionDebug {
                let msg = "attention autofocusing suppressed reason=surfaceFocused+mouseInside"
                Ghostty.logger.info("\(msg, privacy: .public)")
            }
            return
        }

        autoFocusAttentionPausedSurfaceId = nil
        autoFocusAttentionWorkItem?.cancel()

        autoFocusAttentionToken &+= 1
        let token = autoFocusAttentionToken

        let work = DispatchWorkItem { [weak self] in
            self?.attemptAutoFocusAttention(token: token, bypassIdle: false, bypassFocusPause: false)
        }
        autoFocusAttentionWorkItem = work

        let idleMs = ghostty.config.autoFocusAttentionIdle
        let idleDeadline = ProcessInfo.processInfo.systemUptime + (Double(idleMs) / 1000.0)
        setAttentionOverlay("idleWait", deadlineUptime: idleDeadline, reason: "initial-idle-gate")
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(idleMs)),
            execute: work
        )
    }

    private func attemptAutoFocusAttention(token: UInt64, bypassIdle: Bool, bypassFocusPause: Bool) {
        recordAutoFocusTrace(event: "attempt", reason: "entry", details: ["token": "\(token)", "bypass_idle": "\(bypassIdle)", "bypass_focus_pause": "\(bypassFocusPause)"])
        guard ghostty.config.autoFocusAttention else {
            recordAutoFocusTrace(event: "attempt-abort", reason: "auto-focus-disabled")
            return
        }
        guard NSApp.isActive else {
            recordAutoFocusTrace(event: "attempt-abort", reason: "app-inactive")
            return
        }
        guard window?.isKeyWindow ?? false else {
            recordAutoFocusTrace(event: "attempt-abort", reason: "window-not-key")
            return
        }
        guard !commandPaletteIsShowing else {
            recordAutoFocusTrace(event: "attempt-abort", reason: "command-palette")
            return
        }
        if !bypassFocusPause, shouldPauseAutoFocusAttentionBecauseSurfaceFocused() {
            recordAutoFocusTrace(event: "attempt-paused", reason: "focused-surface")
            setAttentionOverlay(autoFocusAttentionPending ? "paused(focused): pending" : "paused(focused)")
            return
        }

        // Ignore stale work items.
        guard token == autoFocusAttentionToken else {
            recordAutoFocusTrace(event: "attempt-abort", reason: "stale-token", details: ["token": "\(token)"])
            return
        }

        // Enforce minimum attention age (optional).
        let minAgeMs = Double(ghostty.config.autoFocusAttentionMinAge)
        if minAgeMs > 0, let since = autoFocusAttentionPendingSinceUptime {
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - since) * 1000.0
            if elapsedMs < minAgeMs {
                let remainingMs = max(0.0, minAgeMs - elapsedMs)
                if ghostty.config.attentionDebug {
                    let msg = "attention autofocusing minAgeWait elapsedMs=\(Int(elapsedMs)) minAgeMs=\(Int(minAgeMs)) remainingMs=\(Int(remainingMs))"
                    Ghostty.logger.info("\(msg, privacy: .public)")
                }
                autoFocusAttentionWorkItem?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.attemptAutoFocusAttention(token: token, bypassIdle: bypassIdle, bypassFocusPause: bypassFocusPause)
                }
                autoFocusAttentionWorkItem = work
                setAttentionOverlay(
                    "minAgeWait",
                    deadlineUptime: ProcessInfo.processInfo.systemUptime + (remainingMs / 1000.0),
                    reason: "min-age")
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(remainingMs)), execute: work)
                return
            }
        }

        if !bypassIdle {
            let idleMs = Double(ghostty.config.autoFocusAttentionIdle)
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - lastUserActivityUptime) * 1000.0
            if elapsedMs < idleMs {
                // Not idle yet; reschedule for the remaining time.
                if ghostty.config.attentionDebug {
                    let msg = "attention autofocusing idleWait elapsedMs=\(Int(elapsedMs)) idleMs=\(Int(idleMs)) remainingMs=\(Int(max(0.0, idleMs - elapsedMs)))"
                    Ghostty.logger.info("\(msg, privacy: .public)")
                }
                let remainingMs = max(0.0, idleMs - elapsedMs)
                autoFocusAttentionWorkItem?.cancel()
                setAttentionOverlay(
                    "idleWait",
                    deadlineUptime: ProcessInfo.processInfo.systemUptime + (remainingMs / 1000.0),
                    reason: "idle-recheck")
                let work = DispatchWorkItem { [weak self] in
                    self?.attemptAutoFocusAttention(token: token, bypassIdle: false, bypassFocusPause: false)
                }
                autoFocusAttentionWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(remainingMs)), execute: work)
                return
            }
        }

        focusMostRecentAttentionAcrossTabGroup()
    }

    private func focusMostRecentAttentionAcrossTabGroup() {
        guard let (controller, surface) = mostRecentAttentionSurface(preferCurrentTab: true) else {
            if ghostty.config.attentionDebug {
                let msg = "attention autofocusing noCandidates"
                Ghostty.logger.info("\(msg, privacy: .public)")
            }
            recordAutoFocusTrace(event: "autofocus-no-candidates", reason: "none-watchable")
            autoFocusAttentionPending = false
            autoFocusAttentionPausedSurfaceId = nil
            autoFocusAttentionPendingSinceUptime = nil
            setAttentionOverlay("noCandidates")
            return
        }
        if ghostty.config.attentionDebug {
            let msg = "attention autofocusing focus surface=\(surface.id.uuidString) fromWindow=\(self.window?.windowNumber ?? -1) targetWindow=\(surface.window?.windowNumber ?? -1)"
            Ghostty.logger.info("\(msg, privacy: .public)")
        }
        autoFocusAttentionPending = false
        autoFocusAttentionPausedSurfaceId = nil
        autoFocusAttentionPendingSinceUptime = nil
        recordAutoFocusTrace(event: "autofocus-focus", reason: "selected-most-recent", target: surface)
        setAttentionOverlay("focus \(surface.id.uuidString.prefix(8))")
        controller.focusSurface(surface)

        // Lock on the surface we just auto-focused to. This prevents a second,
        // subsequent attention event (from another tab) from immediately
        // stealing focus away while the user is reading.
        controller.autoFocusAttentionFocusLockSurfaceId = surface.id
    }

    private func cycleAttention(direction: Ghostty.AttentionFocusDirection, preferCurrentTab: Bool) {
        guard let window else { return }

        let candidates: [Ghostty.SurfaceView]
        if preferCurrentTab {
            let local = attentionSurfaces(in: self, applyWatchFilter: true)
            if !local.isEmpty {
                candidates = sortAttentionSurfaces(local)
            } else {
                candidates = sortAttentionSurfaces(attentionSurfacesAcrossTabGroup(applyWatchFilter: true))
            }
        } else {
            candidates = sortAttentionSurfaces(attentionSurfacesAcrossTabGroup(applyWatchFilter: true))
        }

        guard !candidates.isEmpty else {
            if ghostty.config.attentionDebug {
                let msg = "attention cycle noCandidates preferCurrentTab=\(preferCurrentTab)"
                Ghostty.logger.info("\(msg, privacy: .public)")
            }
            return
        }

        let groupId = ObjectIdentifier(window.tabGroup ?? window)
        let lastId = Self.attentionCycleState[groupId]

        let next: Ghostty.SurfaceView = {
            if let lastId,
               let idx = candidates.firstIndex(where: { $0.id == lastId }) {
                switch direction {
                case .next:
                    return candidates[(idx + 1) % candidates.count]
                case .previous:
                    return candidates[(idx - 1 + candidates.count) % candidates.count]
                }
            }

            // No prior cycle state: start at most-recent (next) or least-recent (previous).
            switch direction {
            case .next:
                return candidates[0]
            case .previous:
                return candidates[candidates.count - 1]
            }
        }()

        Self.attentionCycleState[groupId] = next.id

        if ghostty.config.attentionDebug {
            let lastStr = lastId?.uuidString ?? "nil"
            let msg = "attention cycle pick direction=\(String(describing: direction)) preferCurrentTab=\(preferCurrentTab) candidates=\(candidates.count) last=\(lastStr) next=\(next.id.uuidString) targetWindow=\(next.window?.windowNumber ?? -1)"
            Ghostty.logger.info("\(msg, privacy: .public)")
        }
        guard let targetWindow = next.window,
              let targetController = targetWindow.windowController as? BaseTerminalController
        else { return }
        targetController.focusSurface(next)
    }

    private func attentionSurfaces(
        in controller: BaseTerminalController,
        applyWatchFilter: Bool = false
    ) -> [Ghostty.SurfaceView] {
        if applyWatchFilter {
            return controller.surfaceTree.filter { $0.bell && controller.isAttentionSurfaceWatchable($0) }
        }
        return controller.surfaceTree.filter { $0.bell }
    }

    private func attentionSurfacesAcrossTabGroup(applyWatchFilter: Bool = false) -> [Ghostty.SurfaceView] {
        guard let window else { return [] }
        let windows: [NSWindow] = window.tabGroup?.windows ?? [window]
        return windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .flatMap { attentionSurfaces(in: $0, applyWatchFilter: applyWatchFilter) }
    }

    private func sortAttentionSurfaces(_ surfaces: [Ghostty.SurfaceView]) -> [Ghostty.SurfaceView] {
        // Most recent first.
        return surfaces.sorted { a, b in
            let ai = a.bellInstant ?? -Double.greatestFiniteMagnitude
            let bi = b.bellInstant ?? -Double.greatestFiniteMagnitude
            if ai != bi { return ai > bi }
            return a.id.uuidString < b.id.uuidString
        }
    }

    private func mostRecentAttentionSurface(preferCurrentTab: Bool) -> (BaseTerminalController, Ghostty.SurfaceView)? {
        guard window != nil else { return nil }

        func pick(from surfaces: [Ghostty.SurfaceView]) -> (BaseTerminalController, Ghostty.SurfaceView)? {
            guard let best = sortAttentionSurfaces(surfaces).first else { return nil }
            guard let targetWindow = best.window,
                  let controller = targetWindow.windowController as? BaseTerminalController
            else { return nil }
            return (controller, best)
        }

        if preferCurrentTab {
            if let local = pick(from: attentionSurfaces(in: self, applyWatchFilter: true)) {
                return local
            }
        }

        // For auto-focus we want the most recent across the entire tab group.
        return pick(from: attentionSurfacesAcrossTabGroup(applyWatchFilter: true))
    }

    private func isAttentionSurfaceWatchable(_ surface: Ghostty.SurfaceView) -> Bool {
        switch ghostty.config.autoFocusAttentionWatchMode {
        case .all:
            return true
        case .marked:
            return hasWatchableExplicitAgentMark(surface.title)
        case .agents:
            return isDetectedWatchedProvider(surface)
        case .agents_or_marked:
            return hasWatchableExplicitAgentMark(surface.title) || isDetectedWatchedProvider(surface)
        }
    }

    private func isDetectedWatchedProvider(_ surface: Ghostty.SurfaceView) -> Bool {
        let watched = watchedProviders()
        guard !watched.isEmpty else { return false }

        // Prefer the debounced, poll-derived state used by badges/overlays.
        if let stable = agentStable[surface.id],
           stable.source != .none,
           let badgeProvider = stable.badgeProvider
        {
            let token = canonicalAgentProviderToken(badgeProvider) ?? badgeProvider
            return watched.contains(token)
        }

        let titleProvider = detectAgentProviderFromTitle(surface.title)
        if titleProvider != .unknown {
            return watched.contains(titleProvider.rawValue)
        }

        // Fall back to viewport content when title doesn't classify.
        let viewportProvider = detectAgentProviderFromViewport(surface.cachedVisibleContents.get())
        guard viewportProvider != .unknown else { return false }
        return watched.contains(viewportProvider.rawValue)
    }

    /// Lightweight watchability check for auto-focus trace logging only.
    /// This intentionally avoids viewport scans so trace mode stays low-overhead.
    private func isAttentionSurfaceWatchableForTrace(_ surface: Ghostty.SurfaceView) -> Bool {
        switch ghostty.config.autoFocusAttentionWatchMode {
        case .all:
            return true
        case .marked:
            return hasWatchableExplicitAgentMark(surface.title)
        case .agents:
            return isDetectedWatchedProviderForTrace(surface)
        case .agents_or_marked:
            return hasWatchableExplicitAgentMark(surface.title) || isDetectedWatchedProviderForTrace(surface)
        }
    }

    private func isDetectedWatchedProviderForTrace(_ surface: Ghostty.SurfaceView) -> Bool {
        let watched = watchedProviders()
        guard !watched.isEmpty else { return false }

        if let stable = agentStable[surface.id],
           stable.source != .none,
           let badgeProvider = stable.badgeProvider
        {
            let token = canonicalAgentProviderToken(badgeProvider) ?? badgeProvider
            return watched.contains(token)
        }

        let titleProvider = detectAgentProviderFromTitle(surface.title)
        guard titleProvider != .unknown else { return false }
        return watched.contains(titleProvider.rawValue)
    }

    private func hasWatchableExplicitAgentMark(_ title: String) -> Bool {
        extractAttentionAgentTag(title) != nil
    }

    private func parseProviderSet(_ raw: String) -> Set<String> {
        let pieces = raw
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        var result: Set<String> = []
        result.reserveCapacity(pieces.count)
        for piece in pieces {
            if let canonical = canonicalAgentProviderToken(piece) {
                result.insert(canonical)
            } else {
                result.insert(piece)
            }
        }

        return result
    }

    private func watchedProviders() -> Set<String> {
        parseProviderSet(ghostty.config.attentionWatchProviders)
    }

    private func surfaceTagProviders() -> Set<String> {
        let explicit = parseProviderSet(ghostty.config.attentionSurfaceTagProviders)
        if !explicit.isEmpty { return explicit }

        // Backward-compatible fallback for existing configs.
        return watchedProviders()
    }

    private func extractAttentionAgentTag(_ title: String) -> String? {
        let prefix = ghostty.config.attentionSurfaceTagPrefix
        let suffix = ghostty.config.attentionSurfaceTagSuffix
        guard !prefix.isEmpty, !suffix.isEmpty else { return nil }

        guard let prefixRange = title.range(of: prefix) else { return nil }
        let rest = title[prefixRange.upperBound...]
        guard let suffixRange = rest.range(of: suffix) else { return nil }

        let token = rest[..<suffixRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !token.isEmpty else { return nil }

        let normalized = canonicalAgentProviderToken(token) ?? token

        if !ghostty.config.attentionSurfaceTagAllowAny {
            let allowed = surfaceTagProviders()
            guard allowed.contains(normalized) else { return nil }
        }

        return normalized
    }

    private func agentAutodetectionEnabled() -> Bool {
        ghostty.config.autoFocusAttentionWatchMode != .marked ||
            ghostty.config.attentionAutodetectDiagnostics != .off
    }

    private func diagnosticsAutodetectAllowed(
        explicitMark: String?
    ) -> Bool {
        switch ghostty.config.attentionAutodetectDiagnostics {
        case .off:
            return false
        case .marked:
            return explicitMark != nil
        case .all:
            return true
        }
    }

    private func diagnosticsBadgeEnabled() -> Bool {
        ghostty.config.autoFocusAttentionWatchMode == .marked &&
            ghostty.config.attentionAutodetectDiagnostics != .off
    }

    // MARK: Local Events

    private func localEventHandler(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            return localEventFlagsChanged(event)

        case .mouseMoved, .leftMouseDragged:
            // If we're paused due to focus but have pending attention, update our notion
            // of "mouse focus" based on event location. This is more reliable than
            // NSTrackingArea alone in UI tests.
            updateAutoFocusAttentionMouseInsideFromEvent(event)
            noteUserActivity(event)
            return event

        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            noteUserActivity(event)
            return event

        default:
            return event
        }
    }

    private func updateAutoFocusAttentionMouseInsideFromEvent(_ event: NSEvent) {
        guard ghostty.config.autoFocusAttention else { return }
        guard autoFocusAttentionPending else { return }
        guard let window, event.window == window else { return }
        // Prefer the first responder surface, but fall back to our focusedSurface.
        // During certain UI interactions (dragging/transition animations), the
        // responder chain can be transiently out of sync, but we still want to
        // reliably detect mouse exit in UI tests.
        guard let surface = windowFirstResponderSurfaceView() ?? focusedSurface else { return }

        let locInWindow = event.locationInWindow
        let locInView = surface.convert(locInWindow, from: nil)
        let inside = surface.bounds.contains(locInView)
        if inside != autoFocusAttentionMouseInsideFocusedSurface {
            surfaceMouseInsideDidChange(surface: surface, inside: inside)
        }
    }

    private func windowFirstResponderSurfaceView() -> Ghostty.SurfaceView? {
        guard let window else { return nil }
        guard let responderView = window.firstResponder as? NSView else { return nil }

        var v: NSView? = responderView
        while let cur = v {
            if let s = cur as? Ghostty.SurfaceView { return s }
            v = cur.superview
        }

        return nil
    }

    private func noteUserActivity(_ event: NSEvent) {
        // Only track activity for events targeting our window.
        guard let window, event.window == window else { return }
        lastUserActivityUptime = ProcessInfo.processInfo.systemUptime
    }

    private func localEventFlagsChanged(_ event: NSEvent) -> NSEvent? {
        var surfaces: [Ghostty.SurfaceView] = surfaceTree.map { $0 }

        // If we're the main window receiving key input, then we want to avoid
        // calling this on our focused surface because that'll trigger a double
        // flagsChanged call.
        if NSApp.mainWindow == window {
            surfaces = surfaces.filter { $0 != focusedSurface }
        }
        
        for surface in surfaces {
            surface.flagsChanged(with: event)
        }

        return event
    }

    // MARK: TerminalViewDelegate

    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        let lastFocusedSurface = focusedSurface
        focusedSurface = to

        // Reset the user-idle timer on any focus change, including those
        // triggered by attention cycling/auto-focus. This ensures we don't
        // immediately cycle away from the surface we just switched to.
        let focusChanged: Bool = {
            switch (lastFocusedSurface, to) {
            case (nil, nil):
                return false
            case (nil, _), (_, nil):
                return true
            case (let a?, let b?):
                return a !== b
            }
        }()
        if focusChanged {
            lastUserActivityUptime = ProcessInfo.processInfo.systemUptime
            // Assume the mouse is inside the newly focused surface (common case:
            // focus via click). We'll update this via enter/exit events.
            autoFocusAttentionMouseInsideFocusedSurface = true

            // If we were locked on a surface (due to auto-focus) and focus moved
            // away from it, clear the lock so attention can resume as configured.
            if let lock = autoFocusAttentionFocusLockSurfaceId,
               let last = lastFocusedSurface,
               last.id == lock,
               let newSurface = windowFirstResponderSurfaceView() ?? to,
               newSurface.id != lock
            {
                autoFocusAttentionFocusLockSurfaceId = nil
            }
        }

        // Optional behavior: if we have pending attention and the user switches
        // to a different surface than the one they were reading when pending began,
        // treat that as a "done reading" signal and resume auto-focus.
        if ghostty.config.autoFocusAttentionResumeOnSurfaceSwitch,
           autoFocusAttentionPending,
           let pausedId = autoFocusAttentionPausedSurfaceId,
           let newSurface = windowFirstResponderSurfaceView() ?? to,
           newSurface.id != pausedId
        {
            resumeAutoFocusAttention(reason: "surfaceSwitch", bypassFocusPause: false)
        }

        // Important to cancel any prior subscriptions
        focusedSurfaceCancellables = []

        // Setup our title listener. If we have a focused surface we always use that.
        // Otherwise, we try to use our last focused surface. In either case, we only
        // want to care if the surface is in the tree so we don't listen to titles of
        // closed surfaces.
        if let titleSurface = focusedSurface ?? lastFocusedSurface,
           surfaceTree.contains(titleSurface) {
            // If we have a surface, we want to listen for title changes.
            titleSurface.$title
                .combineLatest(titleSurface.$bell)
                .map { [weak self] in self?.computeTitle(title: $0, bell: $1) ?? "" }
                .sink { [weak self] in self?.titleDidChange(to: $0) }
                .store(in: &focusedSurfaceCancellables)

            // Track responder focus changes so we can resume auto-focus-attention
            // when focus leaves the terminal surface.
            titleSurface.$focused
                .removeDuplicates()
                .sink { [weak self] focused in
                    self?.focusedSurfaceResponderDidChange(focused: focused)
                }
                .store(in: &focusedSurfaceCancellables)
        } else {
            // There is no surface to listen to titles for.
            titleDidChange(to: "👻")
        }
    }

    private func shouldPauseAutoFocusAttentionBecauseSurfaceFocused() -> Bool {
        // Auto-focus should never steal focus while the user is reading/working
        // in a focused surface.
        //
        // We interpret "reading" as the mouse being inside the focused surface.
        // This gives the user an explicit way to signal disinterest (move the
        // cursor out of the pane) without requiring defocus to a non-terminal
        // UI element (which may not exist).
        //
        // We consult both the responder chain and our focusedSurface state
        // because the responder can be transiently out of sync during tab/split
        // transitions.
        guard let window else { return false }

        // If we just auto-focused a surface, treat it as "reading" until the
        // user focuses away, even if responder state is temporarily weird.
        if let lock = autoFocusAttentionFocusLockSurfaceId {
            if focusedSurface?.id == lock { return true }
            if windowFirstResponderSurfaceView()?.id == lock { return true }
        }

        guard windowFirstResponderSurfaceView() != nil else { return false }
        return autoFocusAttentionMouseInsideFocusedSurface
    }

    private func focusedSurfaceResponderDidChange(focused: Bool) {
        if focused {
            // Being focused alone doesn't pause auto-focus; mouse-inside does.
            // However, if we're focused and pending, the most common state is
            // that the user is reading, so keep the overlay informative.
            if let lock = autoFocusAttentionFocusLockSurfaceId {
                setAttentionOverlay(autoFocusAttentionPending ? "paused(lock \(lock.uuidString.prefix(4))): pending" : "paused(lock)")
            } else {
                setAttentionOverlay(autoFocusAttentionPending ? "paused(focused): pending" : "paused(focused)")
            }
            armAutoFocusAttentionResumeOnFocusedIdle(reason: "focusedIdle")
            return
        }

        // Resigning focus from the surface is a strong "done reading" signal.
        autoFocusAttentionFocusLockSurfaceId = nil
        resumeAutoFocusAttention(reason: "resign")
    }

    func surfaceMouseInsideDidChange(surface: Ghostty.SurfaceView, inside: Bool) {
        // `focusedSurface` can lag behind during tab/split transitions. For the
        // attention engine, treat the window's current first responder surface as
        // the active one too.
        let active = (surface === focusedSurface) || (surface === windowFirstResponderSurfaceView())
        guard active else { return }
        autoFocusAttentionMouseInsideFocusedSurface = inside

        if inside {
            // If a resume timer is armed, cancel it. The user re-entered the pane,
            // which is a strong signal that they want to keep reading/working here.
            autoFocusAttentionWorkItem?.cancel()
            autoFocusAttentionWorkItem = nil
            autoFocusAttentionToken &+= 1
            setAttentionOverlay(autoFocusAttentionPending ? "paused(focused): pending" : "paused(focused)")
            armAutoFocusAttentionResumeOnFocusedIdle(reason: "focusedIdle")
        } else {
            resumeAutoFocusAttention(reason: "mouseExit")
        }
    }

    private func resumeAutoFocusAttention(reason: String, bypassFocusPause: Bool = false) {
        recordAutoFocusTrace(event: "resume", reason: reason, details: ["bypass_focus_pause": "\(bypassFocusPause)"])
        // If something is pending, resume after a "quiet" period (configurable via
        // auto-focus-attention-resume-delay) without waiting for idle.
        //
        // This resume delay is debounced: any user action during the countdown
        // resets it. Additionally, if the mouse re-enters the focused surface,
        // we pause entirely until the mouse leaves again.
        guard ghostty.config.autoFocusAttention else {
            recordAutoFocusTrace(event: "resume-abort", reason: "auto-focus-disabled")
            return
        }
        guard autoFocusAttentionPending else {
            recordAutoFocusTrace(event: "resume-abort", reason: "no-pending", details: ["resume_reason": reason])
            setAttentionOverlay("idle")
            return
        }
        guard NSApp.isActive else {
            recordAutoFocusTrace(event: "resume-abort", reason: "app-inactive", details: ["resume_reason": reason])
            return
        }
        guard window?.isKeyWindow ?? false else {
            recordAutoFocusTrace(event: "resume-abort", reason: "window-not-key", details: ["resume_reason": reason])
            return
        }
        guard !commandPaletteIsShowing else {
            recordAutoFocusTrace(event: "resume-abort", reason: "command-palette", details: ["resume_reason": reason])
            return
        }

        // If the user is actively reading (mouse inside focused surface), do not
        // arm a resume timer. We'll re-enter via mouse exit.
        if !bypassFocusPause, shouldPauseAutoFocusAttentionBecauseSurfaceFocused() {
            recordAutoFocusTrace(event: "resume-paused", reason: "focused-surface", details: ["resume_reason": reason])
            setAttentionOverlay(autoFocusAttentionPending ? "paused(focused): pending" : "paused(focused)")
            return
        }

        autoFocusAttentionWorkItem?.cancel()
        autoFocusAttentionWorkItem = nil
        autoFocusAttentionToken &+= 1
        let token = autoFocusAttentionToken

        let delayMs = ghostty.config.autoFocusAttentionResumeDelay
        recordAutoFocusTrace(event: "resume-armed", reason: reason, details: ["delay_ms": "\(delayMs)", "bypass_focus_pause": "\(bypassFocusPause)"])
        if delayMs == 0 {
            setAttentionOverlay("resumeNow", reason: reason)
        } else {
            let resumeDeadline = ProcessInfo.processInfo.systemUptime + (Double(delayMs) / 1000.0)
            setAttentionOverlay("resumeWait", deadlineUptime: resumeDeadline, reason: reason)
        }

        let work = DispatchWorkItem { [weak self] in
            self?.attemptResumeAutoFocusAttention(token: token, reason: reason, delayMs: delayMs, bypassFocusPause: bypassFocusPause)
        }
        autoFocusAttentionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(delayMs)), execute: work)
    }

    private func attemptResumeAutoFocusAttention(token: UInt64, reason: String, delayMs: UInt, bypassFocusPause: Bool) {
        recordAutoFocusTrace(event: "resume-attempt", reason: reason, details: ["token": "\(token)", "delay_ms": "\(delayMs)", "bypass_focus_pause": "\(bypassFocusPause)"])
        guard ghostty.config.autoFocusAttention else {
            recordAutoFocusTrace(event: "resume-attempt-abort", reason: "auto-focus-disabled", details: ["resume_reason": reason])
            return
        }
        guard autoFocusAttentionPending else {
            recordAutoFocusTrace(event: "resume-attempt-abort", reason: "no-pending", details: ["resume_reason": reason])
            setAttentionOverlay("idle")
            return
        }
        guard NSApp.isActive else {
            recordAutoFocusTrace(event: "resume-attempt-abort", reason: "app-inactive", details: ["resume_reason": reason])
            return
        }
        guard window?.isKeyWindow ?? false else {
            recordAutoFocusTrace(event: "resume-attempt-abort", reason: "window-not-key", details: ["resume_reason": reason])
            return
        }
        guard !commandPaletteIsShowing else {
            recordAutoFocusTrace(event: "resume-attempt-abort", reason: "command-palette", details: ["resume_reason": reason])
            return
        }
        guard token == autoFocusAttentionToken else {
            recordAutoFocusTrace(event: "resume-attempt-abort", reason: "stale-token", details: ["resume_reason": reason, "token": "\(token)"])
            return
        }

        // If the user is reading/working in a focused surface again, pause entirely.
        if !bypassFocusPause, shouldPauseAutoFocusAttentionBecauseSurfaceFocused() {
            recordAutoFocusTrace(event: "resume-attempt-paused", reason: "focused-surface", details: ["resume_reason": reason])
            setAttentionOverlay(autoFocusAttentionPending ? "paused(focused): pending" : "paused(focused)")
            return
        }

        // Debounce: require a full quiet period since the last activity.
        if delayMs > 0 {
            let elapsedMs = (ProcessInfo.processInfo.systemUptime - lastUserActivityUptime) * 1000.0
            if elapsedMs < Double(delayMs) {
                let remainingMs = UInt(max(0.0, Double(delayMs) - elapsedMs))
                if ghostty.config.attentionDebug {
                    let msg = "attention autofocusing resumeWait elapsedMs=\(Int(elapsedMs)) delayMs=\(delayMs) remainingMs=\(remainingMs) reason=\(reason)"
                    Ghostty.logger.info("\(msg, privacy: .public)")
                }
                autoFocusAttentionWorkItem?.cancel()
                autoFocusAttentionToken &+= 1
                setAttentionOverlay(
                    "resumeWait",
                    deadlineUptime: ProcessInfo.processInfo.systemUptime + (Double(remainingMs) / 1000.0),
                    reason: reason)
                let newToken = autoFocusAttentionToken
                let work = DispatchWorkItem { [weak self] in
                    self?.attemptResumeAutoFocusAttention(token: newToken, reason: reason, delayMs: delayMs, bypassFocusPause: bypassFocusPause)
                }
                autoFocusAttentionWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(remainingMs)), execute: work)
                return
            }
        }

        attemptAutoFocusAttention(token: token, bypassIdle: true, bypassFocusPause: bypassFocusPause)
    }

    private func armAutoFocusAttentionResumeOnFocusedIdle(reason: String) {
        guard ghostty.config.autoFocusAttention else { return }
        guard autoFocusAttentionPending else { return }

        let focusedIdleMs = ghostty.config.autoFocusAttentionResumeOnFocusedIdle
        guard focusedIdleMs > 0 else { return }

        // If we're no longer in the paused-by-focus state, let normal scheduling
        // logic handle auto-focus instead of forcing bypass behavior.
        guard shouldPauseAutoFocusAttentionBecauseSurfaceFocused() else { return }

        recordAutoFocusTrace(event: "focused-idle-armed", reason: reason, details: ["threshold_ms": "\(focusedIdleMs)"])

        let elapsedMs = (ProcessInfo.processInfo.systemUptime - lastUserActivityUptime) * 1000.0
        let remainingMs = max(0.0, Double(focusedIdleMs) - elapsedMs)
        if remainingMs <= 0 {
            recordAutoFocusTrace(event: "focused-idle-fire", reason: reason, details: ["threshold_ms": "\(focusedIdleMs)"])
            resumeAutoFocusAttention(reason: reason, bypassFocusPause: true)
            return
        }

        autoFocusAttentionWorkItem?.cancel()
        autoFocusAttentionWorkItem = nil
        autoFocusAttentionToken &+= 1
        let token = autoFocusAttentionToken

        setAttentionOverlay(
            "focusedIdleWait",
            deadlineUptime: ProcessInfo.processInfo.systemUptime + (remainingMs / 1000.0),
            reason: reason)

        let work = DispatchWorkItem { [weak self] in
            self?.attemptFocusedIdleResume(token: token, reason: reason, thresholdMs: focusedIdleMs)
        }
        autoFocusAttentionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(remainingMs)), execute: work)
    }

    private func attemptFocusedIdleResume(token: UInt64, reason: String, thresholdMs: UInt) {
        recordAutoFocusTrace(event: "focused-idle-attempt", reason: reason, details: ["token": "\(token)", "threshold_ms": "\(thresholdMs)"])
        guard ghostty.config.autoFocusAttention else {
            recordAutoFocusTrace(event: "focused-idle-abort", reason: "auto-focus-disabled", details: ["resume_reason": reason])
            return
        }
        guard autoFocusAttentionPending else {
            recordAutoFocusTrace(event: "focused-idle-abort", reason: "no-pending", details: ["resume_reason": reason])
            setAttentionOverlay("idle")
            return
        }
        guard NSApp.isActive else {
            recordAutoFocusTrace(event: "focused-idle-abort", reason: "app-inactive", details: ["resume_reason": reason])
            return
        }
        guard window?.isKeyWindow ?? false else {
            recordAutoFocusTrace(event: "focused-idle-abort", reason: "window-not-key", details: ["resume_reason": reason])
            return
        }
        guard !commandPaletteIsShowing else {
            recordAutoFocusTrace(event: "focused-idle-abort", reason: "command-palette", details: ["resume_reason": reason])
            return
        }
        guard token == autoFocusAttentionToken else {
            recordAutoFocusTrace(event: "focused-idle-abort", reason: "stale-token", details: ["resume_reason": reason, "token": "\(token)"])
            return
        }

        // If we are no longer paused-by-focus, regular scheduling should decide.
        guard shouldPauseAutoFocusAttentionBecauseSurfaceFocused() else {
            recordAutoFocusTrace(event: "focused-idle-handoff", reason: "focus-pause-cleared", details: ["resume_reason": reason])
            scheduleAutoFocusAttention()
            return
        }

        let elapsedMs = (ProcessInfo.processInfo.systemUptime - lastUserActivityUptime) * 1000.0
        if elapsedMs < Double(thresholdMs) {
            let remainingMs = UInt(max(0.0, Double(thresholdMs) - elapsedMs))
            if ghostty.config.attentionDebug {
                let msg = "attention autofocusing focusedIdleWait elapsedMs=\(Int(elapsedMs)) thresholdMs=\(thresholdMs) remainingMs=\(remainingMs) reason=\(reason)"
                Ghostty.logger.info("\(msg, privacy: .public)")
            }

            autoFocusAttentionWorkItem?.cancel()
            autoFocusAttentionToken &+= 1
            let newToken = autoFocusAttentionToken
            let work = DispatchWorkItem { [weak self] in
                self?.attemptFocusedIdleResume(token: newToken, reason: reason, thresholdMs: thresholdMs)
            }
            autoFocusAttentionWorkItem = work
            setAttentionOverlay(
                "focusedIdleWait",
                deadlineUptime: ProcessInfo.processInfo.systemUptime + (Double(remainingMs) / 1000.0),
                reason: reason)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(remainingMs)), execute: work)
            return
        }

        recordAutoFocusTrace(event: "focused-idle-fire", reason: reason, details: ["threshold_ms": "\(thresholdMs)"])
        resumeAutoFocusAttention(reason: reason, bypassFocusPause: true)
    }

    private func tabGroupPositionLabel(for window: NSWindow?) -> String {
        guard let window else { return "?" }
        if let group = window.tabGroup,
           let idx = group.windows.firstIndex(of: window)
        {
            return "\(idx + 1)/\(group.windows.count)"
        }
        return "1/1"
    }

    private func compactSurfaceTitleForOverlay(_ title: String) -> String {
        let flattened = title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flattened.isEmpty else { return "<untitled>" }
        if flattened.count <= 56 { return flattened }
        let idx = flattened.index(flattened.startIndex, offsetBy: 56)
        return String(flattened[..<idx]) + "…"
    }

    private func describePlannedAttentionTarget() -> String? {
        guard let (_, surface) = mostRecentAttentionSurface(preferCurrentTab: true) else { return nil }

        let tab = tabGroupPositionLabel(for: surface.window)
        let sid = String(surface.id.uuidString.prefix(8))
        let title = compactSurfaceTitleForOverlay(surface.title)
        return "switch tab \(tab) surface \(sid) title=\"\(title)\""
    }

    private func refreshAttentionOverlay() {
        guard ghostty.config.attentionDebug else { return }

        var pieces: [String] = []
        pieces.append(attentionOverlayHint)

        let now = ProcessInfo.processInfo.systemUptime
        if let deadline = attentionOverlayPlanDeadlineUptime {
            let remainingMs = max(0, Int((deadline - now) * 1000.0))
            pieces.append("t-\(remainingMs)ms")
        }

        if let reason = attentionOverlayPlanReason, !reason.isEmpty {
            pieces.append("reason=\(reason)")
        }

        let idleMs = Int(max(0, (now - lastUserActivityUptime) * 1000.0))
        pieces.append("idle=\(idleMs)ms")

        let watchableMarks = attentionSurfacesAcrossTabGroup(applyWatchFilter: true).count
        let totalMarks = attentionSurfacesAcrossTabGroup(applyWatchFilter: false).count
        pieces.append("marks=\(watchableMarks)/\(totalMarks)")

        if autoFocusAttentionPending {
            pieces.append("pending=1")
            pieces.append("next=\(describePlannedAttentionTarget() ?? "none")")
        } else {
            pieces.append("pending=0")
        }

        let text = pieces.joined(separator: " • ")
        if attentionOverlayText != text {
            attentionOverlayText = text
        }
    }

    private func setAttentionOverlay(_ text: String, deadlineUptime: TimeInterval? = nil, reason: String? = nil) {
        if autoFocusTraceIsEnabled() {
            var details: [String: String] = [:]
            if let deadlineUptime {
                let remainingMs = max(0, Int((deadlineUptime - ProcessInfo.processInfo.systemUptime) * 1000.0))
                details["remaining_ms"] = "\(remainingMs)"
            }
            if let reason {
                details["overlay_reason"] = reason
            }
            recordAutoFocusTrace(event: "overlay", reason: text, details: details)
        }

        guard ghostty.config.attentionDebug else { return }
        attentionOverlayHint = text
        attentionOverlayPlanDeadlineUptime = deadlineUptime
        attentionOverlayPlanReason = reason
        refreshAttentionOverlay()
    }

    // MARK: Agent Detection / Badges

    private func syncAgentStatusDetection() {
        // We run polling when debug overlays are enabled OR when watch-mode
        // filtering is active so per-surface agent badges stay up to date.
        if ghostty.config.attentionDebug || ghostty.config.autoFocusAttentionWatchMode != .all || ghostty.config.attentionAutodetectDiagnostics != .off || focusedAgentTraceEnabled {
            startAgentStatusDetectionIfNeeded()
        } else {
            stopAgentStatusDetection()
        }
    }

    private func startAgentStatusDetectionIfNeeded() {
        guard agentStatusTimer == nil else { return }

        // Keep this conservative: even with cachedVisibleContents, decoding viewport
        // text can be expensive across many panes.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollAgentStatuses()
        }
        agentStatusTimer = timer
        RunLoop.main.add(timer, forMode: .common)

        // Prime immediately so the overlay appears without waiting a full interval.
        pollAgentStatuses()
    }

    private func stopAgentStatusDetection() {
        agentStatusTimer?.invalidate()
        agentStatusTimer = nil
        agentObserved.removeAll()
        agentStable.removeAll()
        agentProviderLocks.removeAll()
        agentUnknownScanCursor = 0
        for surface in surfaceTree.map({ $0 }) {
            surface.clearAttentionAgentBadge()
        }
        if !agentStatusOverlayText.isEmpty {
            agentStatusOverlayText = ""
        }
        syncAttentionTabHighlight()
    }

    private func pollAgentStatuses() {
        guard let window else { return }

        // Collect all surfaces in the current tab group.
        let controllers: [BaseTerminalController] = (window.tabGroup?.windows ?? [window])
            .compactMap { $0.windowController as? BaseTerminalController }

        let allSurfaces: [Ghostty.SurfaceView] = controllers.flatMap { $0.surfaceTree.map { $0 } }
        if allSurfaces.isEmpty {
            captureFocusedAgentTracePollIfActive(reason: "autodetect-poll-empty")
            agentStatusOverlayText = ""
            syncAttentionTabHighlight()
            refreshAttentionOverlay()
            return
        }
        let scanOrder: [Ghostty.SurfaceView] = {
            let offset = allSurfaces.isEmpty ? 0 : (agentUnknownScanCursor % allSurfaces.count)
            agentUnknownScanCursor = allSurfaces.isEmpty ? 0 : ((offset + 1) % allSurfaces.count)
            if offset == 0 { return allSurfaces }
            return Array(allSurfaces[offset...] + allSurfaces[..<offset])
        }()

        let now = ProcessInfo.processInfo.systemUptime
        let stableMs = ghostty.config.agentStatusStable
        let stableWindow = Double(stableMs) / 1000.0
        let debugOverlayEnabled = ghostty.config.attentionDebug
        let markedOnlyMode = ghostty.config.autoFocusAttentionWatchMode == .marked
        let providerLockEnabled = ghostty.config.attentionProviderLock

        var nextStable = agentStable
        var nextObserved = agentObserved
        var nextProviderLocks = agentProviderLocks

        // Prune removed surfaces.
        let ids = Set(allSurfaces.map { $0.id })
        nextStable = nextStable.filter { ids.contains($0.key) }
        nextObserved = nextObserved.filter { ids.contains($0.key) }
        nextProviderLocks = nextProviderLocks.filter { ids.contains($0.key) }

        // To keep overhead bounded in large layouts, only scan a small number of
        // unknown-provider panes per tick.
        var unknownViewportScanBudget = 3

        for surface in scanOrder {
            let explicitMark = extractAttentionAgentTag(surface.title)
            let diagnosticsAllowedForSurface = diagnosticsAutodetectAllowed(explicitMark: explicitMark)
            let allowAutodetectionForSurface = !markedOnlyMode || diagnosticsAllowedForSurface
            let titleProvider: AgentProvider = allowAutodetectionForSurface ? detectAgentProviderFromTitle(surface.title) : .unknown
            let remembered = nextStable[surface.id] ?? nextObserved[surface.id].map {
                AgentStableState(
                    provider: $0.provider,
                    status: $0.status,
                    badgeProvider: $0.badgeProvider,
                    source: $0.source
                )
            }

            var provider: AgentProvider = titleProvider != .unknown ? titleProvider : .unknown
            var status: AgentStatus = debugOverlayEnabled ? (remembered?.status ?? .idle) : .idle

            var source: AgentDetectionSource = .none
            var badgeProvider: String? = nil
            var explicitMarkedProvider: AgentProvider? = nil
            if let explicitMark {
                source = .marked
                badgeProvider = explicitMark
                if let canonical = canonicalAgentProviderToken(explicitMark),
                   let markedProvider = AgentProvider(rawValue: canonical)
                {
                    provider = markedProvider
                    explicitMarkedProvider = markedProvider
                }
            } else if titleProvider != .unknown {
                source = .title
                badgeProvider = titleProvider.rawValue
            }

            let currentLock = nextProviderLocks[surface.id]
            var sampledViewportText: String? = nil

            let shouldReadViewport: Bool = {
                if !allowAutodetectionForSurface {
                    // Autodetection disabled for this surface; only sample
                    // explicitly marked panes when debug overlay needs status.
                    return source == .marked && debugOverlayEnabled
                }
                if providerLockEnabled, currentLock != nil {
                    return true
                }
                if source == .marked {
                    // Explicit marks don't need viewport classification for eligibility,
                    // but diagnostics mode may still sample viewport evidence.
                    if markedOnlyMode && diagnosticsAllowedForSurface { return true }
                    return debugOverlayEnabled
                }
                if source == .title {
                    // Title-only detection is prone to staleness (apps can leave
                    // provider-like titles behind after exit). Always validate
                    // against current viewport content.
                    return true
                }
                // Unknown title: sample a bounded rotating set each tick so
                // badges and filtering converge without sticking to stale labels.
                if unknownViewportScanBudget <= 0 { return false }
                unknownViewportScanBudget -= 1
                return true
            }()

            if shouldReadViewport {
                let text = surface.cachedVisibleContents.get()
                sampledViewportText = text
                let preferredProvider = currentLock?.provider ?? remembered?.provider
                let viewportProvider: AgentProvider = allowAutodetectionForSurface ? detectAgentProviderFromViewport(text, preferred: preferredProvider) : .unknown

                if allowAutodetectionForSurface {
                    if source == .none {
                        if viewportProvider != .unknown {
                            provider = viewportProvider
                            source = .viewport
                            badgeProvider = viewportProvider.rawValue
                        }
                    } else if source == .title {
                        if viewportProvider == .unknown {
                            if viewportLooksLikeReturnedShellPrompt(text) {
                                // Demote stale title-only classifications when the
                                // viewport has clearly returned to a regular shell prompt.
                                provider = .unknown
                                source = .none
                                badgeProvider = nil
                            } else {
                                // Keep title-based classification while the viewport is
                                // still in an active transcript (no shell prompt yet).
                                provider = titleProvider
                                source = .title
                                badgeProvider = titleProvider.rawValue
                            }
                        } else if viewportProvider != titleProvider {
                            let titleIsCodexOrOpenCode = titleProvider == .codex || titleProvider == .opencode
                            let viewportIsCodexOrOpenCode = viewportProvider == .codex || viewportProvider == .opencode
                            if !(titleIsCodexOrOpenCode && viewportIsCodexOrOpenCode) {
                                // Prefer live viewport evidence if it disagrees with title,
                                // except codex<->opencode where cross-mentions are common.
                                provider = viewportProvider
                                source = .viewport
                                badgeProvider = viewportProvider.rawValue
                            }
                        }
                    }

                    // In marked watch-mode with diagnostics enabled, keep
                    // autodetect results visible as diagnostic badges.
                    if markedOnlyMode && diagnosticsAllowedForSurface && viewportProvider != .unknown {
                        provider = viewportProvider
                        source = .diagnostic
                        badgeProvider = viewportProvider.rawValue
                    }
                }

                if debugOverlayEnabled, provider != .unknown {
                    status = detectAgentStatus(provider: provider, viewportText: text)
                }
            }

            if providerLockEnabled {
                let locked = applyAgentProviderLock(
                    surfaceId: surface.id,
                    explicitMarkedProvider: explicitMarkedProvider,
                    allowAutodetectionForSurface: allowAutodetectionForSurface,
                    detectedProvider: provider,
                    detectedSource: source,
                    detectedBadgeProvider: badgeProvider,
                    viewportText: sampledViewportText,
                    locks: &nextProviderLocks
                )
                provider = locked.provider
                source = locked.source
                badgeProvider = locked.badgeProvider
            }

            if debugOverlayEnabled, provider != .unknown, let text = sampledViewportText {
                status = detectAgentStatus(provider: provider, viewportText: text)
            }

            if var obs = nextObserved[surface.id] {
                if obs.provider != provider ||
                    obs.status != status ||
                    obs.badgeProvider != badgeProvider ||
                    obs.source != source
                {
                    // New candidate; reset debounce.
                    obs.provider = provider
                    obs.status = status
                    obs.badgeProvider = badgeProvider
                    obs.source = source
                    obs.sinceUptime = now
                    nextObserved[surface.id] = obs
                } else if (now - obs.sinceUptime) >= stableWindow {
                    // Candidate unchanged; promote to stable once it's held long enough.
                    nextStable[surface.id] = .init(
                        provider: provider,
                        status: status,
                        badgeProvider: badgeProvider,
                        source: source
                    )
                }
            } else {
                nextObserved[surface.id] = .init(
                    provider: provider,
                    status: status,
                    badgeProvider: badgeProvider,
                    source: source,
                    sinceUptime: now
                )
                // Don't immediately promote; require stability window.
            }
        }

        agentObserved = nextObserved
        agentStable = nextStable
        agentProviderLocks = nextProviderLocks

        captureFocusedAgentTracePollIfActive(reason: "autodetect-poll", surfaces: allSurfaces)

        applyAgentBadges(from: nextStable, to: allSurfaces)

        if debugOverlayEnabled {
            let overlay = renderAgentStatusOverlay(from: nextStable)
            if agentStatusOverlayText != overlay {
                agentStatusOverlayText = overlay
            }
        } else if !agentStatusOverlayText.isEmpty {
            agentStatusOverlayText = ""
        }

        syncAttentionTabHighlight()
        refreshAttentionOverlay()
    }

    private func applyAgentBadges(
        from stable: [UUID: AgentStableState],
        to surfaces: [Ghostty.SurfaceView]
    ) {
        for surface in surfaces {
            guard let state = stable[surface.id],
                  let provider = state.badgeProvider,
                  !provider.isEmpty,
                  state.source != .none
            else {
                surface.clearAttentionAgentBadge()
                continue
            }

            let source: Ghostty.SurfaceView.AgentBadgeSource = {
                switch state.source {
                case .marked:
                    return .marked
                case .diagnostic:
                    return .diagnostic
                case .title, .viewport:
                    return diagnosticsBadgeEnabled() ? .diagnostic : .detected
                case .none:
                    return .none
                }
            }()
            surface.setAttentionAgentBadge(provider: provider, source: source)
        }
    }

    private func renderAgentStatusOverlay(from stable: [UUID: AgentStableState]) -> String {
        guard !stable.isEmpty else { return "" }

        // Counts per provider across the tab group.
        var counts: [AgentProvider: (waiting: Int, idle: Int, running: Int)] = [:]
        for (_, v) in stable {
            // Keep "unknown" internal only; do not show it in the debug overlay.
            if v.provider == .unknown { continue }
            var c = counts[v.provider] ?? (waiting: 0, idle: 0, running: 0)
            switch v.status {
            case .waiting: c.waiting += 1
            case .idle: c.idle += 1
            case .running: c.running += 1
            }
            counts[v.provider] = c
        }

        // Stable ordering (most useful first).
        let order: [AgentProvider] = [.codex, .opencode, .ag_tui, .claude, .vibe, .gemini]

        // Emojis to keep it compact:
        // - waiting: ⏳
        // - idle: 💤
        // - running: 🏃
        let pieces: [String] = order.compactMap { p in
            guard let c = counts[p] else { return nil }
            return "\(p.rawValue) ⏳\(c.waiting) 💤\(c.idle) 🏃\(c.running)"
        }

        return pieces.joined(separator: "  |  ")
    }

    private func providerLockAllowsSource(_ source: AgentDetectionSource) -> Bool {
        switch source {
        case .title, .viewport, .diagnostic:
            return true
        case .none, .marked:
            return false
        }
    }

    private func viewportLooksLikeReturnedShellPrompt(_ viewportText: String) -> Bool {
        guard let last = nonEmptyLines(viewportText).last else { return false }
        return looksLikeShellPromptLine(last)
    }

    private func applyAgentProviderLock(
        surfaceId: UUID,
        explicitMarkedProvider: AgentProvider?,
        allowAutodetectionForSurface: Bool,
        detectedProvider: AgentProvider,
        detectedSource: AgentDetectionSource,
        detectedBadgeProvider: String?,
        viewportText: String?,
        locks: inout [UUID: AgentProviderLockState]
    ) -> (provider: AgentProvider, source: AgentDetectionSource, badgeProvider: String?) {
        // Explicit marks are authoritative and should not be rewritten by
        // autodetection lock state.
        if explicitMarkedProvider != nil {
            locks[surfaceId] = nil
            return (detectedProvider, detectedSource, detectedBadgeProvider)
        }

        // Locking only applies to autodetection-enabled surfaces.
        guard allowAutodetectionForSurface else {
            locks[surfaceId] = nil
            return (detectedProvider, detectedSource, detectedBadgeProvider)
        }

        let lockableSource = providerLockAllowsSource(detectedSource)
        let now = ProcessInfo.processInfo.systemUptime
        var lockState = locks[surfaceId]

        // Acquire lock only after at least one observed confirmation so a single
        // noisy poll doesn't immediately stick a provider.
        if lockState == nil, lockableSource, detectedProvider != .unknown {
            if let observed = agentObserved[surfaceId],
               observed.provider == detectedProvider,
               observed.source == detectedSource
            {
                lockState = AgentProviderLockState(
                    provider: detectedProvider,
                    lastPositiveEvidenceUptime: now
                )
            } else {
                return (detectedProvider, detectedSource, detectedBadgeProvider)
            }
        }

        guard var lock = lockState else {
            locks[surfaceId] = nil
            return (detectedProvider, detectedSource, detectedBadgeProvider)
        }

        if lockableSource, detectedProvider != .unknown {
            lock.lastPositiveEvidenceUptime = now
            lock.unknownIdlePromptCount = 0
            lock.unknownStreakCount = 0

            if detectedProvider == lock.provider {
                lock.mismatchProvider = .unknown
                lock.mismatchCount = 0
            } else {
                if lock.mismatchProvider == detectedProvider {
                    lock.mismatchCount += 1
                } else {
                    lock.mismatchProvider = detectedProvider
                    lock.mismatchCount = 1
                }

                if lock.mismatchCount >= agentProviderLockSwitchPolls {
                    lock.provider = detectedProvider
                    lock.mismatchProvider = .unknown
                    lock.mismatchCount = 0
                }
            }
        } else {
            lock.mismatchProvider = .unknown
            lock.mismatchCount = 0

            if detectedProvider == .unknown {
                lock.unknownStreakCount += 1

                if let viewportText {
                    let lockedStatus = detectAgentStatus(provider: lock.provider, viewportText: viewportText)
                    if lockedStatus == .idle && viewportLooksLikeReturnedShellPrompt(viewportText) {
                        lock.unknownIdlePromptCount += 1
                    } else {
                        lock.unknownIdlePromptCount = 0
                    }
                } else {
                    lock.unknownIdlePromptCount = 0
                }
            } else {
                lock.unknownStreakCount = 0
                lock.unknownIdlePromptCount = 0
            }
        }

        if lock.unknownIdlePromptCount >= agentProviderLockPromptClearPolls ||
            lock.unknownStreakCount >= agentProviderLockUnknownClearPolls
        {
            locks[surfaceId] = nil
            return (detectedProvider, detectedSource, detectedBadgeProvider)
        }

        locks[surfaceId] = lock

        let lockedSource: AgentDetectionSource = {
            if detectedSource != .none {
                return detectedSource
            }
            return viewportText == nil ? .title : .viewport
        }()

        return (lock.provider, lockedSource, lock.provider.rawValue)
    }

    private func canonicalAgentProviderToken(_ token: String) -> String? {

        let t = token
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if t.contains("codex") || t.contains("openai codex") { return AgentProvider.codex.rawValue }
        if t.contains("opencode") || t.contains("open code") { return AgentProvider.opencode.rawValue }
        if t.contains("ag-tui") || t.contains("ag tui") || t.contains("antigod-tui") || t.contains("antigod tui") || t == "ag" { return AgentProvider.ag_tui.rawValue }
        if t.contains("claude") { return AgentProvider.claude.rawValue }
        if t.contains("vibe") { return AgentProvider.vibe.rawValue }
        if t.contains("gemini") { return AgentProvider.gemini.rawValue }

        return nil
    }

    private func detectAgentProviderFromTitle(_ title: String) -> AgentProvider {
        if let marked = extractAttentionAgentTag(title),
           let canonical = canonicalAgentProviderToken(marked),
           let provider = AgentProvider(rawValue: canonical)
        {
            return provider
        }

        let t = title.lowercased()
        let trimmedTitle = t.trimmingCharacters(in: .whitespacesAndNewlines)
        func hasAny(_ s: String, _ needles: [String]) -> Bool { needles.contains(where: s.contains) }

        // Prefer explicit title matches since they are often set to the running tool command.
        if hasAny(t, ["codex"]) { return .codex }
        if hasAny(t, ["opencode", "open code"]) { return .opencode }
        if trimmedTitle == "ag" || trimmedTitle == "antigod" || hasAny(t, ["ag-tui", "ag tui", "antigod-tui", "antigod tui", "antigod cli"]) { return .ag_tui }
        if hasAny(t, ["claude"]) { return .claude }
        if hasAny(t, ["vibe"]) { return .vibe }
        if hasAny(t, ["gemini"]) { return .gemini }

        return .unknown
    }

    private func hasCodexViewportSignature(_ lower: String) -> Bool {
        let markers = [
            "openai codex (v",
            " >_ openai codex",
            "codex --model",
            "codex --yolo",
            "codex cli",
            "codex>",
            " /review",
        ]
        return markers.contains(where: lower.contains)
    }

    private func hasOpenCodeViewportSignature(_ lower: String) -> Bool {
        let markers = [
            "opencode --",
            "opencode/",
            " opencode v",
            "opencode cli",
            "opencode",
        ]
        return markers.contains(where: lower.contains)
    }


    private func hasGeminiViewportSignature(_ lower: String) -> Bool {
        let markers = [
            "gemini cli",
            "gemini-cli",
            "google gemini",
            "gemini --",
            "gemini --model",
            "gemini>",
            " gemini v",
            "gemini api key",
            "gemini 2.5",
            "gemini 2.0",
        ]
        return markers.contains(where: lower.contains)
    }

    private func geminiMentionsLookLikeDiscussionText(_ lower: String) -> Bool {
        let lines = lower
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let mentionLines = lines.filter { $0.contains("gemini") }
        guard !mentionLines.isEmpty else { return false }

        if mentionLines.contains(where: hasGeminiViewportSignature) {
            return false
        }

        let discussionHints = [
            "not gemini",
            "is not gemini",
            "isn't gemini",
            "how to use gemini",
            "what is gemini",
            "remote trace",
            "attention-",
            "auto-focus-",
            "watch-providers",
            "values:",
            "example",
            "[gemini]",
            "provider",
            "detection",
        ]

        return mentionLines.allSatisfy { line in
            if line.hasPrefix("#") || line.hasPrefix("-") || line.hasPrefix("›") {
                return true
            }
            return discussionHints.contains(where: line.contains)
        }
    }
    private func opencodeMentionsLookLikeConfigText(_ lower: String) -> Bool {
        let lines = lower
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let mentionLines = lines.filter { $0.contains("opencode") }
        guard !mentionLines.isEmpty else { return false }

        let promptHints = ["➜", "$ ", "% ", "❯", "›", "│ >_", "model:"]
        if mentionLines.contains(where: { line in promptHints.contains(where: line.contains) }) {
            return false
        }

        let configHints = [
            "attention-",
            "auto-focus-",
            "notify-on-",
            "watch-providers",
            "surface-tag",
            "keybind",
            "values:",
            "example",
            "=",
            "[opencode]",
        ]

        return mentionLines.allSatisfy { line in
            if line.hasPrefix("#") { return true }
            return configHints.contains(where: line.contains)
        }
    }

    private func lastProviderMentionOffset(_ lower: String, needles: [String]) -> String.Index? {
        var best: String.Index? = nil
        for needle in needles {
            if let range = lower.range(of: needle, options: .backwards) {
                if let current = best {
                    if range.lowerBound > current {
                        best = range.lowerBound
                    }
                } else {
                    best = range.lowerBound
                }
            }
        }
        return best
    }

    private func detectAgentProviderFromViewport(_ viewportText: String, preferred: AgentProvider? = nil) -> AgentProvider {
        let tailLower = detectionTailLower(viewportText, lineCount: 36)
        let fullLower = viewportText.lowercased()
        func hasAny(_ s: String, _ needles: [String]) -> Bool { needles.contains(where: s.contains) }

        // Prefer evidence near the active prompt/status area (tail). This reduces
        // stale detections from older scrollback content.
        let codexMentionedTail = hasAny(tailLower, ["codex", "openai codex"])
        let opencodeMentionedTail = hasAny(tailLower, ["opencode"])
        let geminiMentionedTail = hasAny(tailLower, ["gemini"])

        var codexDetected = codexMentionedTail && hasCodexViewportSignature(tailLower)
        var opencodeDetected = opencodeMentionedTail && hasOpenCodeViewportSignature(tailLower) && !opencodeMentionsLookLikeConfigText(tailLower)
        var geminiDetected = geminiMentionedTail && hasGeminiViewportSignature(tailLower) && !geminiMentionsLookLikeDiscussionText(tailLower)
        var providerScanLower = tailLower

        // Fallback to full-viewport scan only if tail is inconclusive.
        if !codexDetected && !opencodeDetected && !geminiDetected {
            providerScanLower = fullLower
            let codexMentioned = hasAny(fullLower, ["codex", "openai codex"])
            let opencodeMentioned = hasAny(fullLower, ["opencode"])
            let geminiMentioned = hasAny(fullLower, ["gemini"])

            codexDetected = codexMentioned && hasCodexViewportSignature(fullLower)
            opencodeDetected = opencodeMentioned && hasOpenCodeViewportSignature(fullLower) && !opencodeMentionsLookLikeConfigText(fullLower)
            geminiDetected = geminiMentioned && hasGeminiViewportSignature(fullLower) && !geminiMentionsLookLikeDiscussionText(fullLower)
        }

        if codexDetected && opencodeDetected {
            if let preferred, preferred == .opencode || preferred == .codex {
                return preferred
            }
            let codexIdx = lastProviderMentionOffset(providerScanLower, needles: ["openai codex", "codex"])
            let opencodeIdx = lastProviderMentionOffset(providerScanLower, needles: ["opencode"])
            if let codexIdx, let opencodeIdx {
                return opencodeIdx > codexIdx ? .opencode : .codex
            }
            return .opencode
        }

        if opencodeDetected { return .opencode }
        if codexDetected { return .codex }
        if hasAny(tailLower, ["ag-tui", "ag tui", "antigod-tui", "antigod tui", "antigod cli"]) {
            return detectAgTuiStatus(viewportText) == .idle ? .unknown : .ag_tui
        }
        if hasAny(tailLower, ["claude"]) {
            return detectClaudeStatus(viewportText) == .idle ? .unknown : .claude
        }
        if hasAny(tailLower, ["vibe"]) {
            return detectVibeStatus(viewportText) == .idle ? .unknown : .vibe
        }
        if geminiDetected {
            return detectGeminiStatus(viewportText) == .idle ? .unknown : .gemini
        }

        return .unknown
    }

    private func detectAgentStatus(provider: AgentProvider, viewportText: String) -> AgentStatus {
        // Ported from agent-of-empires status detection (viewport-only).
        switch provider {
        case .claude:
            return detectClaudeStatus(viewportText)
        case .opencode:
            return detectOpenCodeStatus(viewportText)
        case .ag_tui:
            return detectAgTuiStatus(viewportText)
        case .vibe:
            return detectVibeStatus(viewportText)
        case .codex:
            return detectCodexStatus(viewportText)
        case .gemini:
            return detectGeminiStatus(viewportText)
        case .unknown:
            // Default to idle to avoid false "waiting" in generic shells.
            return .idle
        }
    }

    private static let aoeSpinnerChars: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private func detectionTailLower(_ content: String, lineCount: Int) -> String {
        let nonEmpty = nonEmptyLines(content)
        let tail = lastLines(nonEmpty, count: lineCount)
        return tail.lowercased()
    }


    private func nonEmptyLines(_ content: String) -> [String] {
        content
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private func lastLines(_ lines: [String], count: Int) -> String {
        let tail = lines.suffix(count)
        return tail.joined(separator: "\n")
    }

    private func containsSpinner(_ content: String) -> Bool {
        for sp in Self.aoeSpinnerChars where content.contains(sp) { return true }
        return false
    }

    private func stripAnsiLikeAoe(_ s: String) -> String {
        // Match AoE's simple strip: remove CSI sequences and OSC ... BEL.
        var out = s
        while let r = out.range(of: "\u{1b}[") {
            let rest = out[r.upperBound...]
            if let end = rest.firstIndex(where: { $0.isLetter }) {
                out.removeSubrange(r.lowerBound..<out.index(after: end))
            } else {
                break
            }
        }
        while let r = out.range(of: "\u{1b}]") {
            if let bel = out[r.lowerBound...].firstIndex(of: "\u{7}") {
                out.removeSubrange(r.lowerBound..<out.index(after: bel))
            } else {
                break
            }
        }
        return out
    }

    private func looksLikeShellPromptLine(_ line: String) -> Bool {
        let clean = stripAnsiLikeAoe(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }

        if clean.hasPrefix("➜ ") || clean.hasPrefix("$ ") || clean.hasPrefix("% ") || clean.hasPrefix("# ") {
            return true
        }
        if clean.hasSuffix("$") || clean.hasSuffix("%") || clean.hasSuffix("#") {
            return true
        }

        return false
    }

    private func detectClaudeStatus(_ content: String) -> AgentStatus {
        let lines = content.split(whereSeparator: \.isNewline).map { String($0) }
        let nonEmpty = nonEmptyLines(content)
        let last = lastLines(nonEmpty, count: 30)
        let lastLower = last.lowercased()

        if let lastLine = nonEmpty.last,
           looksLikeShellPromptLine(lastLine),
           !lastLower.contains("esc to interrupt"),
           !lastLower.contains("ctrl+c to interrupt"),
           !containsSpinner(content)
        {
            return .idle
        }
        if lastLower.contains("esc to interrupt") || lastLower.contains("ctrl+c to interrupt") {
            return .running
        }
        if containsSpinner(content) {
            return .running
        }
        if lastLower.contains("enter to select") || lastLower.contains("esc to cancel") {
            return .waiting
        }
        let permissionPrompts = [
            "Yes, allow once",
            "Yes, allow always",
            "Allow once",
            "Allow always",
            "❯ Yes",
            "❯ No",
            "Do you trust the files in this folder?",
        ]
        for p in permissionPrompts where last.contains(p) { return .waiting }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("❯"), trimmed.count > 2 {
                let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.hasPrefix("1.") || rest.hasPrefix("2.") || rest.hasPrefix("3.") {
                    return .waiting
                }
            }
        }

        for line in nonEmpty.suffix(10).reversed() {
            let clean = stripAnsiLikeAoe(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if clean == ">" || clean == "> " { return .waiting }
            if clean.hasPrefix("> "),
               !clean.lowercased().contains("esc"),
               clean.count < 100
            {
                return .waiting
            }
        }

        let yn = ["(Y/n)", "(y/N)", "[Y/n]", "[y/N]"]
        for p in yn where last.contains(p) { return .waiting }

        return .idle
    }

    private func detectOpenCodeStatus(_ content: String) -> AgentStatus {
        let lines = content.split(whereSeparator: \.isNewline).map { String($0) }
        let nonEmpty = nonEmptyLines(content)
        let last = lastLines(nonEmpty, count: 30)
        let lastLower = last.lowercased()

        if lastLower.contains("esc to interrupt") || lastLower.contains("esc interrupt") {
            return .running
        }
        if containsSpinner(content) {
            return .running
        }
        if lastLower.contains("enter to select") || lastLower.contains("esc to cancel") {
            return .waiting
        }

        let permission = ["(y/n)", "[y/n]", "continue?", "proceed?", "approve", "allow"]
        for p in permission where lastLower.contains(p) { return .waiting }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("❯"), trimmed.count > 2 {
                let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.hasPrefix("1.") || rest.hasPrefix("2.") || rest.hasPrefix("3.") {
                    return .waiting
                }
            }
        }
        if lines.contains(where: { $0.contains("❯") && ($0.contains(" 1.") || $0.contains(" 2.") || $0.contains(" 3.")) }) {
            return .waiting
        }

        for line in nonEmpty.suffix(10).reversed() {
            let clean = stripAnsiLikeAoe(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if clean == ">" || clean == "> " || clean == ">>" { return .waiting }
            if clean.hasPrefix("> "),
               !clean.lowercased().contains("esc"),
               clean.count < 100
            {
                return .waiting
            }
        }

        let completionIndicators = [
            "complete",
            "done",
            "finished",
            "ready",
            "what would you like",
            "what else",
            "anything else",
            "how can i help",
            "let me know",
        ]
        let hasCompletion = completionIndicators.contains(where: { lastLower.contains($0) })
        if hasCompletion {
            for line in nonEmpty.suffix(10).reversed() {
                let clean = stripAnsiLikeAoe(line).trimmingCharacters(in: .whitespacesAndNewlines)
                if clean == ">" || clean == "> " || clean == ">>" {
                    return .waiting
                }
            }
        }

        return .idle
    }

    private func detectVibeStatus(_ content: String) -> AgentStatus {
        let nonEmpty = nonEmptyLines(content)
        let last = lastLines(nonEmpty, count: 30)
        let lastLower = last.lowercased()

        let recentText = nonEmpty.suffix(50).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined()
        let recentLower = recentText.lowercased()

        if lastLower.contains("↑↓ navigate") || lastLower.contains("enter select") || lastLower.contains("esc reject") {
            return .waiting
        }
        if last.contains("⚠"), lastLower.contains("command") {
            return .waiting
        }
        let approval = ["yes and always allow", "no and tell the agent", "› 1.", "› 2.", "› 3."]
        for o in approval where lastLower.contains(o) { return .waiting }

        if content.split(whereSeparator: \.isNewline).contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("›") }) {
            return .waiting
        }

        if containsSpinner(recentText) { return .running }
        let activity = ["running", "reading", "writing", "executing", "processing", "generating", "thinking"]
        for a in activity where recentLower.contains(a) { return .running }
        if recentText.hasSuffix("…") || recentText.hasSuffix("...") { return .running }

        return .idle
    }

    private func detectAgTuiStatus(_ content: String) -> AgentStatus {
        let nonEmpty = nonEmptyLines(content)
        let last = lastLines(nonEmpty, count: 30)
        let lastLower = last.lowercased()

        if let lastLine = nonEmpty.last,
           looksLikeShellPromptLine(lastLine),
           !containsSpinner(content)
        {
            return .idle
        }

        if containsSpinner(content) { return .running }

        let runningIndicators = [
            "connecting",
            "loading",
            "starting",
            "retrying",
            "working",
            "thinking",
        ]
        for p in runningIndicators where lastLower.contains(p) { return .running }

        let waitingIndicators = [
            "antigod-tui",
            "type a message",
            "press 'i' to start typing",
            "esc normal",
            "enter send",
            "shift+enter newline",
            "ctrl+c clear",
            "select a workspace",
            "status: disconnected",
            "server unreachable",
            "press r to retry",
            "new chat",
            "workspace:",
        ]
        for p in waitingIndicators where lastLower.contains(p) { return .waiting }

        if lastLower.contains("j/k") && lastLower.contains("enter") && lastLower.contains("retry") {
            return .waiting
        }

        return .idle
    }

    private func detectCodexStatus(_ content: String) -> AgentStatus {
        let lines = content.split(whereSeparator: \.isNewline).map { String($0) }
        let nonEmpty = nonEmptyLines(content)
        let last = lastLines(nonEmpty, count: 30)
        let lastLower = last.lowercased()

        if lastLower.contains("esc to interrupt")
            || lastLower.contains("ctrl+c to interrupt")
            || lastLower.contains("working")
            || lastLower.contains("thinking")
        {
            return .running
        }
        if containsSpinner(content) { return .running }

        let approval = ["approve", "allow", "(y/n)", "[y/n]", "continue?", "proceed?", "execute?", "run command?"]
        for p in approval where lastLower.contains(p) { return .waiting }
        if lastLower.contains("enter to select") || lastLower.contains("esc to cancel") { return .waiting }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("❯"), trimmed.count > 2 {
                let rest = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                if rest.hasPrefix("1.") || rest.hasPrefix("2.") || rest.hasPrefix("3.") {
                    return .waiting
                }
            }
        }

        for line in nonEmpty.suffix(10).reversed() {
            let clean = stripAnsiLikeAoe(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if clean == ">" || clean == "> " || clean == "codex>" { return .waiting }
            if clean.hasPrefix("> "),
               !clean.lowercased().contains("esc"),
               clean.count < 100
            {
                return .waiting
            }
        }

        return .idle
    }

    private func detectGeminiStatus(_ content: String) -> AgentStatus {
        let nonEmpty = nonEmptyLines(content)
        let last = lastLines(nonEmpty, count: 30)
        let lastLower = last.lowercased()

        if lastLower.contains("esc to interrupt") || lastLower.contains("ctrl+c to interrupt") {
            return .running
        }
        if containsSpinner(content) { return .running }

        let approval = ["(y/n)", "[y/n]", "allow", "approve", "execute?", "enter to select", "esc to cancel"]
        for p in approval where lastLower.contains(p) { return .waiting }

        for line in nonEmpty.suffix(10).reversed() {
            let clean = stripAnsiLikeAoe(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if clean == ">" || clean == "> " { return .waiting }
        }

        return .idle
    }
    
    private func computeTitle(title: String, bell: Bool) -> String {
        var result = title
        if (bell && ghostty.config.bellFeatures.contains(.title)) {
            result = "🔔 \(result)"
        }

        return result
    }

    private func titleDidChange(to: String) {
        lastComputedTitle = to
        applyTitleToWindow()
    }

    private func applyTitleToWindow() {
        guard let window else { return }
        
        if let titleOverride {
            window.title = computeTitle(
                title: titleOverride,
                bell: focusedSurface?.bell ?? false)
            return
        }
        
        window.title = lastComputedTitle
    }
    
    func pwdDidChange(to: URL?) {
        guard let window else { return }

        if derivedConfig.macosTitlebarProxyIcon == .visible {
            // Use the 'to' URL directly
            window.representedURL = to
        } else {
            window.representedURL = nil
        }
    }


    func cellSizeDidChange(to: NSSize) {
        guard derivedConfig.windowStepResize else { return }
        // Stage manager can sometimes present windows in such a way that the
        // cell size is temporarily zero due to the window being tiny. We can't
        // set content resize increments to this value, so avoid an assertion failure.
        guard to.width > 0 && to.height > 0 else { return }
        self.window?.contentResizeIncrements = to
    }

    func performSplitAction(_ action: TerminalSplitOperation) {
        switch action {
        case .resize(let resize):
            splitDidResize(node: resize.node, to: resize.ratio)
        case .drop(let drop):
            splitDidDrop(source: drop.payload, destination: drop.destination, zone: drop.zone)
        }
    }

    private func splitDidResize(node: SplitTree<Ghostty.SurfaceView>.Node, to newRatio: Double) {
        let resizedNode = node.resizing(to: newRatio)
        do {
            surfaceTree = try surfaceTree.replacing(node: node, with: resizedNode)
        } catch {
            Ghostty.logger.warning("failed to replace node during split resize: \(error)")
        }
    }

    private func splitDidDrop(
        source: Ghostty.SurfaceView,
        destination: Ghostty.SurfaceView,
        zone: TerminalSplitDropZone
    ) {
        // Map drop zone to split direction
        let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = switch zone {
        case .top: .up
        case .bottom: .down
        case .left: .left
        case .right: .right
        }
        
        // Check if source is in our tree
        if let sourceNode = surfaceTree.root?.node(view: source) {
            // Source is in our tree - same window move
            let treeWithoutSource = surfaceTree.removing(sourceNode)
            let newTree: SplitTree<Ghostty.SurfaceView>
            do {
                newTree = try treeWithoutSource.inserting(view: source, at: destination, direction: direction)
            } catch {
                Ghostty.logger.warning("failed to insert surface during drop: \(error)")
                return
            }
            
            replaceSurfaceTree(
                newTree,
                moveFocusTo: source,
                moveFocusFrom: focusedSurface,
                undoAction: "Move Split")
            return
        }
        
        // Source is not in our tree - search other windows
        var sourceController: BaseTerminalController?
        var sourceNode: SplitTree<Ghostty.SurfaceView>.Node?
        for window in NSApp.windows {
            guard let controller = window.windowController as? BaseTerminalController else { continue }
            guard controller !== self else { continue }
            if let node = controller.surfaceTree.root?.node(view: source) {
                sourceController = controller
                sourceNode = node
                break
            }
        }
        
        guard let sourceController, let sourceNode else {
            Ghostty.logger.warning("source surface not found in any window during drop")
            return
        }
        
        // Remove from source controller's tree and add it to our tree.
        // We do this first because if there is an error then we can
        // abort.
        let newTree: SplitTree<Ghostty.SurfaceView>
        do {
            newTree = try surfaceTree.inserting(view: source, at: destination, direction: direction)
        } catch {
            Ghostty.logger.warning("failed to insert surface during cross-window drop: \(error)")
            return
        }
        
        // Treat our undo below as a full group.
        undoManager?.beginUndoGrouping()
        undoManager?.setActionName("Move Split")
        defer {
            undoManager?.endUndoGrouping()
        }
        
        // Remove the node from the source.
        sourceController.removeSurfaceNode(sourceNode)
        
        // Add in the surface to our tree
        replaceSurfaceTree(
            newTree,
            moveFocusTo: source,
            moveFocusFrom: focusedSurface)
    }

    func performAction(_ action: String, on surfaceView: Ghostty.SurfaceView) {
        guard let surface = surfaceView.surface else { return }
        let len = action.utf8CString.count
        if (len == 0) { return }
        _ = action.withCString { cString in
            ghostty_surface_binding_action(surface, cString, UInt(len - 1))
        }
    }

    // MARK: Appearance

    /// Toggle the background opacity between transparent and opaque states.
    /// Do nothing if the configured background-opacity is >= 1 (already opaque).
    /// Subclasses should override this to add platform-specific checks and sync appearance.
    func toggleBackgroundOpacity() {
        // Do nothing if config is already fully opaque
        guard ghostty.config.backgroundOpacity < 1 else { return }
        
        // Do nothing if in fullscreen (transparency doesn't apply in fullscreen)
        guard let window, !window.styleMask.contains(.fullScreen) else { return }

        // Toggle between transparent and opaque
        isBackgroundOpaque.toggle()
        
        // Update our appearance
        syncAppearance()
    }
    
    /// Override this to resync any appearance related properties. This will be called automatically
    /// when certain window properties change that affect appearance. The list below should be updated
    /// as we add new things:
    ///
    ///  - ``toggleBackgroundOpacity``
    func syncAppearance() {
        // Purposely a no-op. This lets subclasses override this and we can call
        // it virtually from here.
    }

    // MARK: Fullscreen

    /// Toggle fullscreen for the given mode.
    func toggleFullscreen(mode: FullscreenMode) {
        // We need a window to fullscreen
        guard let window = self.window else { return }

        // If we have a previous fullscreen style initialized, we want to check if
        // our mode changed. If it changed and we're in fullscreen, we exit so we can
        // toggle it next time. If it changed and we're not in fullscreen we can just
        // switch the handler.
        var newStyle = mode.style(for: window)
        newStyle?.delegate = self
        old: if let oldStyle = self.fullscreenStyle {
            // If we're not fullscreen, we can nil it out so we get the new style
            if !oldStyle.isFullscreen {
                self.fullscreenStyle = newStyle
                break old
            }

            assert(oldStyle.isFullscreen)

            // We consider our mode changed if the types change (obvious) but
            // also if its nil (not obvious) because nil means that the style has
            // likely changed but we don't support it.
            if newStyle == nil || type(of: newStyle!) != type(of: oldStyle) {
                // Our mode changed. Exit fullscreen (since we're toggling anyways)
                // and then set the new style for future use
                oldStyle.exit()
                self.fullscreenStyle = newStyle

                // We're done
                return
            }

            // Style is the same.
        } else {
            // We have no previous style
            self.fullscreenStyle = newStyle
        }
        guard let fullscreenStyle else { return }

        if fullscreenStyle.isFullscreen {
            fullscreenStyle.exit()
        } else {
            fullscreenStyle.enter()
        }
    }

    func fullscreenDidChange() {
        guard let fullscreenStyle else { return }
        
        // When we enter fullscreen, we want to show the update overlay so that it
        // is easily visible. For native fullscreen this is visible by showing the
        // menubar but we don't want to rely on that.
        if fullscreenStyle.isFullscreen {
            updateOverlayIsVisible = true
        } else {
            updateOverlayIsVisible = defaultUpdateOverlayVisibility()
        }
        
        // Always resync our appearance
        syncAppearance()
    }

    // MARK: Clipboard Confirmation

    @objc private func onConfirmClipboardRequest(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }
        guard let surface = target.surface else { return }

        // We need a window
        guard let window = self.window else { return }

        // Check whether we use non-native fullscreen
        guard let str = notification.userInfo?[Ghostty.Notification.ConfirmClipboardStrKey] as? String else { return }
        guard let state = notification.userInfo?[Ghostty.Notification.ConfirmClipboardStateKey] as? UnsafeMutableRawPointer? else { return }
        guard let request = notification.userInfo?[Ghostty.Notification.ConfirmClipboardRequestKey] as? Ghostty.ClipboardRequest else { return }

        // If we already have a clipboard confirmation view up, we ignore this request.
        // This shouldn't be possible...
        guard self.clipboardConfirmation == nil else {
            Ghostty.App.completeClipboardRequest(surface, data: "", state: state, confirmed: true)
            return
        }

        // Show our paste confirmation
        self.clipboardConfirmation = ClipboardConfirmationController(
            surface: surface,
            contents: str,
            request: request,
            state: state,
            delegate: self
        )
        window.beginSheet(self.clipboardConfirmation!.window!)
    }

    func clipboardConfirmationComplete(_ action: ClipboardConfirmationView.Action, _ request: Ghostty.ClipboardRequest) {
        // End our clipboard confirmation no matter what
        guard let cc = self.clipboardConfirmation else { return }
        self.clipboardConfirmation = nil

        // Close the sheet
        if let ccWindow = cc.window {
            window?.endSheet(ccWindow)
        }

        switch (request) {
        case let .osc_52_write(pasteboard):
            guard case .confirm = action else { break }
            let pb = pasteboard ?? NSPasteboard.general
            pb.declareTypes([.string], owner: nil)
            pb.setString(cc.contents, forType: .string)
        case .osc_52_read, .paste:
            let str: String
            switch (action) {
            case .cancel:
                str = ""

            case .confirm:
                str = cc.contents
            }

            Ghostty.App.completeClipboardRequest(cc.surface, data: str, state: cc.state, confirmed: true)
        }
    }

    // MARK: NSWindowController

    override func windowDidLoad() {
        super.windowDidLoad()

        // Setup our undo manager.

        // Everything beyond here is setting up the window
        guard let window else { return }

        // Window now exists; apply any existing attention highlight state.
        syncAttentionTabHighlight()

        // We always initialize our fullscreen style to native if we can because
        // initialization sets up some state (i.e. observers). If its set already
        // somehow we don't do this.
        if fullscreenStyle == nil {
            fullscreenStyle = NativeFullscreen(window)
            fullscreenStyle?.delegate = self
        }
        
        // Set our update overlay state
        updateOverlayIsVisible = defaultUpdateOverlayVisibility()
    }
    
    func defaultUpdateOverlayVisibility() -> Bool {
        guard let window else { return true }
        
        // No titlebar we always show the update overlay because it can't support
        // updates in the titlebar
        guard window.styleMask.contains(.titled) else {
            return true
        }
        
        // If it's a non terminal window we can't trust it has an update accessory,
        // so we always want to show the overlay.
        guard let window = window as? TerminalWindow else {
            return true
        }
        
        // Show the overlay if the window isn't.
        return !window.supportsUpdateAccessory
    }

    // MARK: NSWindowDelegate

    // This is called when performClose is called on a window (NOT when close()
    // is called directly). performClose is called primarily when UI elements such
    // as the "red X" are pressed.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // We must have a window. Is it even possible not to?
        guard let window = self.window else { return true }

        // If we have no surfaces, close.
        if surfaceTree.isEmpty { return true }

        // If we already have an alert, continue with it
        guard alert == nil else { return false }

        // If our surfaces don't require confirmation, close.
        if !surfaceTree.contains(where: { $0.needsConfirmQuit }) { return true }

        // We require confirmation, so show an alert as long as we aren't already.
        confirmClose(
            messageText: "Close Terminal?",
            informativeText: "The terminal still has a running process. If you close the terminal the process will be killed."
        ) {
            window.close()
        }

        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }

        // I don't know if this is required anymore. We previously had a ref cycle between
        // the view and the window so we had to nil this out to break it but I think this
        // may now be resolved. We should verify that no memory leaks and we can remove this.
        window.contentView = nil

        // Make sure we clean up all our undos
        window.undoManager?.removeAllActions(withTarget: self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // If when we become key our first responder is the window itself, then we
        // want to move focus to our focused terminal surface. This works around
        // various weirdness with moving surfaces around.
        if let window, window.firstResponder == window, let focusedSurface {
            DispatchQueue.main.async {
                Ghostty.moveFocus(to: focusedSurface)
            }
        }

        // Becoming/losing key means we have to notify our surface(s) that we have focus
        // so things like cursors blink, pty events are sent, etc.
        self.syncFocusToSurfaceTree()

    }

    func windowDidResignKey(_ notification: Notification) {
        // Becoming/losing key means we have to notify our surface(s) that we have focus
        // so things like cursors blink, pty events are sent, etc.
        self.syncFocusToSurfaceTree()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        let visible = self.window?.occlusionState.contains(.visible) ?? false
        for view in surfaceTree {
            if let surface = view.surface {
                ghostty_surface_set_occlusion(surface, visible)
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowDidMove(_ notification: Notification) {
        windowFrameDidChange()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return nil }
        return appDelegate.undoManager
    }

    // MARK: First Responder

    @IBAction func close(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.requestClose(surface: surface)
    }

    @IBAction func closeWindow(_ sender: Any) {
        guard let window = window else { return }
        window.performClose(sender)
    }

    @IBAction func changeTabTitle(_ sender: Any) {
        promptTabTitle()
    }

    @IBAction func splitRight(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_RIGHT)
    }

    @IBAction func splitLeft(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_LEFT)
    }

    @IBAction func splitDown(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_DOWN)
    }

    @IBAction func splitUp(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_UP)
    }

    @IBAction func splitZoom(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitToggleZoom(surface: surface)
    }


    @IBAction func splitMoveFocusPrevious(_ sender: Any) {
        splitMoveFocus(direction: .previous)
    }

    @IBAction func splitMoveFocusNext(_ sender: Any) {
        splitMoveFocus(direction: .next)
    }

    @IBAction func splitMoveFocusAbove(_ sender: Any) {
        splitMoveFocus(direction: .up)
    }

    @IBAction func splitMoveFocusBelow(_ sender: Any) {
        splitMoveFocus(direction: .down)
    }

    @IBAction func splitMoveFocusLeft(_ sender: Any) {
        splitMoveFocus(direction: .left)
    }

    @IBAction func splitMoveFocusRight(_ sender: Any) {
        splitMoveFocus(direction: .right)
    }

    @IBAction func equalizeSplits(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitEqualize(surface: surface)
    }

    @IBAction func moveSplitDividerUp(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .up, amount: 10)
    }

    @IBAction func moveSplitDividerDown(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .down, amount: 10)
    }

    @IBAction func moveSplitDividerLeft(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .left, amount: 10)
    }

    @IBAction func moveSplitDividerRight(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitResize(surface: surface, direction: .right, amount: 10)
    }

    private func splitMoveFocus(direction: Ghostty.SplitFocusDirection) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.splitMoveFocus(surface: surface, direction: direction)
    }

    @IBAction func increaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .increase(1))
    }

    @IBAction func decreaseFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .decrease(1))
    }

    @IBAction func resetFontSize(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.changeFontSize(surface: surface, .reset)
    }

    @IBAction func toggleCommandPalette(_ sender: Any?) {
        commandPaletteIsShowing.toggle()
    }
    
    @IBAction func find(_ sender: Any) {
        focusedSurface?.find(sender)
    }

    @IBAction func selectionForFind(_ sender: Any) {
        focusedSurface?.selectionForFind(sender)
    }

    @IBAction func scrollToSelection(_ sender: Any) {
        focusedSurface?.scrollToSelection(sender)
    }

    @IBAction func findNext(_ sender: Any) {
        focusedSurface?.findNext(sender)
    }
    
    @IBAction func findPrevious(_ sender: Any) {
        focusedSurface?.findNext(sender)
    }
    
    @IBAction func findHide(_ sender: Any) {
        focusedSurface?.findHide(sender)
    }

    @objc func resetTerminal(_ sender: Any) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.resetTerminal(surface: surface)
    }

    private struct DerivedConfig {
        let macosTitlebarProxyIcon: Ghostty.MacOSTitlebarProxyIcon
        let windowStepResize: Bool
        let focusFollowsMouse: Bool
        let splitPreserveZoom: Ghostty.Config.SplitPreserveZoom

        init() {
            self.macosTitlebarProxyIcon = .visible
            self.windowStepResize = false
            self.focusFollowsMouse = false
            self.splitPreserveZoom = .init()
        }

        init(_ config: Ghostty.Config) {
            self.macosTitlebarProxyIcon = config.macosTitlebarProxyIcon
            self.windowStepResize = config.windowStepResize
            self.focusFollowsMouse = config.focusFollowsMouse
            self.splitPreserveZoom = config.splitPreserveZoom
        }
    }
}

extension BaseTerminalController: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(findHide):
            return focusedSurface?.searchState != nil

        default:
            return true
        }
    }
	
    // MARK: - Surface Color Scheme

    /// Update the surface tree's color scheme only when it actually changes.
    ///
    /// Calling ``ghostty_surface_set_color_scheme`` triggers
    /// ``syncAppearance(_:)`` via notification,
    /// so we avoid redundant calls.
    func updateColorSchemeForSurfaceTree() {
        /// Derive the target scheme from `window-theme` or system appearance.
        /// We set the scheme on surfaces so they pick the correct theme
        /// and let ``syncAppearance(_:)`` update the window accordingly.
        ///
        /// Using App's effectiveAppearance here to prevent incorrect updates.
        let themeAppearance = NSApplication.shared.effectiveAppearance
        let scheme: ghostty_color_scheme_e
        if themeAppearance.isDark {
            scheme = GHOSTTY_COLOR_SCHEME_DARK
        } else {
            scheme = GHOSTTY_COLOR_SCHEME_LIGHT
        }
        guard scheme != appliedColorScheme else {
            return
        }
        for surfaceView in surfaceTree {
            if let surface = surfaceView.surface {
                ghostty_surface_set_color_scheme(surface, scheme)
            }
        }
        appliedColorScheme = scheme
    }
}
