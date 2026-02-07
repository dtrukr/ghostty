import SwiftUI
import GhosttyKit
import os

/// This delegate is notified of actions and property changes regarding the terminal view. This
/// delegate is optional and can be used by a TerminalView caller to react to changes such as
/// titles being set, cell sizes being changed, etc.
protocol TerminalViewDelegate: AnyObject {
    /// Called when the currently focused surface changed. This can be nil.
    func focusedSurfaceDidChange(to: Ghostty.SurfaceView?)

    /// The URL of the pwd should change.
    func pwdDidChange(to: URL?)

    /// The cell size changed.
    func cellSizeDidChange(to: NSSize)

    /// Perform an action. At the time of writing this is only triggered by the command palette.
    func performAction(_ action: String, on: Ghostty.SurfaceView)
    
    /// A split tree operation
    func performSplitAction(_ action: TerminalSplitOperation)
}

/// The view model is a required implementation for TerminalView callers. This contains
/// the main state between the TerminalView caller and SwiftUI. This abstraction is what
/// allows AppKit to own most of the data in SwiftUI.
protocol TerminalViewModel: ObservableObject {
    /// The tree of terminal surfaces (splits) within the view. This is mutated by TerminalView
    /// and children. This should be @Published.
    var surfaceTree: SplitTree<Ghostty.SurfaceView> { get set }

    /// The command palette state.
    var commandPaletteIsShowing: Bool { get set }
    
    /// The update overlay should be visible.
    var updateOverlayIsVisible: Bool { get }

    /// Attention engine status overlay (debug UI).
    var attentionOverlayText: String { get }

    /// Agent status overlay (debug UI).
    var agentStatusOverlayText: String { get }
}

/// The main terminal view. This terminal view supports splits.
struct TerminalView<ViewModel: TerminalViewModel>: View {
    @ObservedObject var ghostty: Ghostty.App

    // The required view model
    @ObservedObject var viewModel: ViewModel

    // An optional delegate to receive information about terminal changes.
    weak var delegate: (any TerminalViewDelegate)? = nil
    
    // The most recently focused surface, equal to focusedSurface when
    // it is non-nil.
    @State private var lastFocusedSurface: Weak<Ghostty.SurfaceView> = .init()

    // This seems like a crutch after switching from SwiftUI to AppKit lifecycle.
    @FocusState private var focused: Bool

    // Various state values sent back up from the currently focused terminals.
    @FocusedValue(\.ghosttySurfaceView) private var focusedSurface
    @FocusedValue(\.ghosttySurfacePwd) private var surfacePwd
    @FocusedValue(\.ghosttySurfaceCellSize) private var cellSize

    // The pwd of the focused surface as a URL
    private var pwdURL: URL? {
        guard let surfacePwd, surfacePwd != "" else { return nil }
        return URL(fileURLWithPath: surfacePwd)
    }

    var body: some View {
        switch ghostty.readiness {
        case .loading:
            Text("Loading")
        case .error:
            ErrorView()
        case .ready:
            ZStack {
                VStack(spacing: 0) {
                    // If we're running in debug mode we show a warning so that users
                    // know that performance will be degraded.
                    if (Ghostty.info.mode == GHOSTTY_BUILD_MODE_DEBUG || Ghostty.info.mode == GHOSTTY_BUILD_MODE_RELEASE_SAFE) {
                        DebugBuildWarningView()
                    }

                    TerminalSplitTreeView(
                        tree: viewModel.surfaceTree,
                        action: { delegate?.performSplitAction($0) })
                        .environmentObject(ghostty)
                        .focused($focused)
                        .onAppear { self.focused = true }
                        .onChange(of: focusedSurface) { newValue in
                            // We want to keep track of our last focused surface so even if
                            // we lose focus we keep this set to the last non-nil value.
                            if newValue != nil {
                                lastFocusedSurface = .init(newValue)
                                self.delegate?.focusedSurfaceDidChange(to: newValue)
                            }
                        }
                        .onChange(of: pwdURL) { newValue in
                            self.delegate?.pwdDidChange(to: newValue)
                        }
                        .onChange(of: cellSize) { newValue in
                            guard let size = newValue else { return }
                            self.delegate?.cellSizeDidChange(to: size)
                        }
                        .frame(idealWidth: lastFocusedSurface.value?.initialSize?.width,
                               idealHeight: lastFocusedSurface.value?.initialSize?.height)
                }
                // Ignore safe area to extend up in to the titlebar region if we have the "hidden" titlebar style
                .ignoresSafeArea(.container, edges: ghostty.config.macosTitlebarStyle == "hidden" ? .top : [])

                if let surfaceView = lastFocusedSurface.value {
                    TerminalCommandPaletteView(
                        surfaceView: surfaceView,
                        isPresented: $viewModel.commandPaletteIsShowing,
                        ghosttyConfig: ghostty.config,
                        updateViewModel: (NSApp.delegate as? AppDelegate)?.updateViewModel) { action in
                        self.delegate?.performAction(action, on: surfaceView)
                    }
                }
                
                // Show update information above all else.
                if viewModel.updateOverlayIsVisible {
                    StatusOverlays(
                        showUpdate: true,
                        attentionText: ghostty.config.attentionDebug ? viewModel.attentionOverlayText : nil,
                        agentText: ghostty.config.attentionDebug ? viewModel.agentStatusOverlayText : nil
                    )
                } else if ghostty.config.attentionDebug,
                          (!viewModel.attentionOverlayText.isEmpty || !viewModel.agentStatusOverlayText.isEmpty)
                {
                    StatusOverlays(
                        showUpdate: false,
                        attentionText: viewModel.attentionOverlayText,
                        agentText: viewModel.agentStatusOverlayText
                    )
                }
            }
            .frame(maxWidth: .greatestFiniteMagnitude, maxHeight: .greatestFiniteMagnitude)
        }
    }
}

fileprivate struct StatusOverlays: View {
    let showUpdate: Bool
    let attentionText: String?
    let agentText: String?

    var body: some View {
        VStack {
            Spacer()

            HStack {
                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    if let attentionText, !attentionText.isEmpty {
                        AttentionPill(text: attentionText)
                    }

                    if let agentText, !agentText.isEmpty {
                        AgentStatusPill(text: agentText)
                    }

                    if showUpdate, let appDelegate = NSApp.delegate as? AppDelegate {
                        UpdatePill(model: appDelegate.updateViewModel)
                    }
                }
                .padding(.bottom, 9)
                .padding(.trailing, 9)
            }
        }
        .allowsHitTesting(false)
    }
}

fileprivate struct AttentionPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "bell")
                .font(.system(size: 11, weight: .semibold))
            Text(verbatim: text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("Ghostty.Attention.Overlay")
        .accessibilityLabel(text)
    }
}

fileprivate struct AgentStatusPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
            Text(verbatim: text)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.regularMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier("Ghostty.AgentStatus.Overlay")
        .accessibilityLabel(text)
    }
}

struct DebugBuildWarningView: View {
    @State private var isPopover = false

    var body: some View {
        HStack {
            Spacer()

            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text("You're running a debug build of Ghostty! Performance will be degraded.")
                .padding(.all, 8)
                .popover(isPresented: $isPopover, arrowEdge: .bottom) {
                    Text("""
                    Debug builds of Ghostty are very slow and you may experience
                    performance problems. Debug builds are only recommended during
                    development.
                    """)
                    .padding(.all)
                }

            Spacer()
        }
        .background(Color(.windowBackgroundColor))
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Debug build warning")
        .accessibilityValue("Debug builds of Ghostty are very slow and you may experience performance problems. Debug builds are only recommended during development.")
        .accessibilityAddTraits(.isStaticText)
        .onTapGesture {
            isPopover = true
        }
    }
}
