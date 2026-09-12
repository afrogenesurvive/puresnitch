import AppKit
import SwiftUI

/// Borderless windows refuse key status by default, and a panel that can't
/// become key can't host a text field — the mini Rules tab has a search field.
private final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc. A `NSPopover` closed on Esc for free; a panel has to be told to.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The menu-bar dropdown, as a panel rather than a popover.
///
/// `NSPopover` cannot be resized by the user: it accepts only a programmatic
/// `contentSize`, and `NSHostingController` fights even that by exporting the
/// view's ideal size — the same hazard `WindowManager.makeWindow` documents for
/// `NSHostingView.sizingOptions`. A borderless non-activating `NSPanel` anchored
/// under the status item gets real drag-to-resize and a size that survives
/// relaunch. The cost is re-implementing what `NSPopover.behavior = .transient`
/// provided, which is `installDismissMonitors()` plus Esc below.
@MainActor
final class MenubarPanelController {

    static let defaultSize = NSSize(width: 420, height: 600)
    static let minimumSize = NSSize(width: 360, height: 420)

    /// Only the size is remembered. The position is always derived from the
    /// status item, so a frame saved on a display that is since gone can never
    /// strand the panel off-screen.
    private static let widthKey = "PSMenubarPanelWidth"
    private static let heightKey = "PSMenubarPanelHeight"

    private let panel: KeyablePanel
    /// Held for the app's lifetime on purpose: releasing the hosting controller
    /// while its view is still installed stops SwiftUI from updating.
    private let hosting: NSHostingController<AnyView>
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// The status item's window, exempted from click-outside dismissal because
    /// clicking it toggles the panel itself — hiding on that click would make
    /// the panel close and immediately reopen.
    private weak var anchorWindow: NSWindow?
    /// Captured when a resize drag begins. `DragGesture` reports a *cumulative*
    /// translation, so absolute sizes need the size the drag started from.
    private var resizeAnchor: (size: NSSize, topEdge: CGFloat)?

    var isVisible: Bool { panel.isVisible }

    init<Content: View>(rootView: Content) {
        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        // AppKit draws nothing for a borderless window, so the rounded corners
        // come from the SwiftUI root and the shadow from here. That needs a
        // transparent backing store.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentMinSize = Self.minimumSize
        panel.animationBehavior = .utilityWindow

        let hosting = NSHostingController(rootView: AnyView(rootView))
        // Keep SwiftUI from exporting an intrinsic size. This is the lesson from
        // `WindowManager.makeWindow`: assign the hosting *view*, and clear
        // `sizingOptions`, or the window resizes itself to the content's ideal
        // size the moment a text-heavy banner appears.
        hosting.sizingOptions = []
        hosting.view.autoresizingMask = [.width, .height]
        panel.contentView = hosting.view
        self.hosting = hosting

        // Esc has to go through `hide()` rather than `orderOut(_:)`, or the
        // click monitors outlive the panel and swallow the next click.
        panel.onCancel = { [weak self] in self?.hide() }
    }

    // MARK: - Presentation

    func toggle(relativeTo button: NSStatusBarButton) {
        if panel.isVisible { hide() } else { show(relativeTo: button) }
    }

    func show(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        anchorWindow = buttonWindow

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? buttonRect

        // Never wider than the screen, never taller than the gap between the
        // menu bar and the bottom of the visible area.
        var size = Self.restoredSize() ?? Self.defaultSize
        size.width = min(size.width, visible.width - 8)
        size.height = min(
            size.height,
            max(Self.minimumSize.height, buttonRect.minY - visible.minY - 4)
        )

        let origin = NSPoint(
            x: min(max(buttonRect.midX - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4),
            y: buttonRect.minY - 2 - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.makeKeyAndOrderFront(nil)
        installDismissMonitors()
    }

    func hide() {
        guard panel.isVisible else { return }
        removeDismissMonitors()
        resizeAnchor = nil
        Self.store(size: panel.frame.size)
        panel.orderOut(nil)
    }

    // MARK: - Resizing

    /// Called from the panel's bottom-right grip. The top edge is pinned so the
    /// panel grows downward from the menu bar, which is what a dropdown should
    /// do — meaning the origin has to be recomputed, not just the size.
    func resizeBy(_ translation: CGSize) {
        let anchor = resizeAnchor ?? (size: panel.frame.size, topEdge: panel.frame.maxY)
        resizeAnchor = anchor

        let visible = panel.screen?.visibleFrame ?? panel.frame
        let width = min(
            max(Self.minimumSize.width, anchor.size.width + translation.width),
            visible.width - 8
        )
        let height = min(
            max(Self.minimumSize.height, anchor.size.height + translation.height),
            max(Self.minimumSize.height, anchor.topEdge - visible.minY - 4)
        )
        panel.setFrame(
            NSRect(
                x: min(panel.frame.minX, visible.maxX - width - 4),
                y: anchor.topEdge - height,
                width: width,
                height: height
            ),
            display: true
        )
    }

    func endResize() {
        resizeAnchor = nil
        Self.store(size: panel.frame.size)
    }

    // MARK: - Dismissal

    /// `NSPopover.behavior = .transient` gave us click-outside dismissal for
    /// free. A panel has to arrange it: the global monitor catches other apps,
    /// the local monitor catches our own windows. Both are torn down on hide so
    /// a stale monitor can never linger.
    private func installDismissMonitors() {
        guard globalClickMonitor == nil else { return }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hide()
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            if event.window === self.anchorWindow { return event }
            self.hide()
            return event
        }

        // This panel is non-activating, which is the case where relying on
        // `hidesOnDeactivate` alone is least dependable, so the notification is
        // the real trigger. The hop to the main queue from a @Sendable
        // notification block is the same pattern `AppDelegate` already uses.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.hide() }
        }
    }

    private func removeDismissMonitors() {
        if let globalClickMonitor {
            NSEvent.removeMonitor(globalClickMonitor)
            self.globalClickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    // MARK: - Persistence

    private static func restoredSize() -> NSSize? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: widthKey) != nil,
              defaults.object(forKey: heightKey) != nil else { return nil }
        let size = NSSize(
            width: defaults.double(forKey: widthKey),
            height: defaults.double(forKey: heightKey)
        )
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }

    private static func store(size: NSSize) {
        guard size.width >= minimumSize.width, size.height >= minimumSize.height else { return }
        let defaults = UserDefaults.standard
        defaults.set(Double(size.width), forKey: widthKey)
        defaults.set(Double(size.height), forKey: heightKey)
    }
}

/// The panel's bottom-right resize affordance.
///
/// `NSPanel` edge-dragging is unreliable for a borderless window, so the panel
/// ships an explicit grip instead: always works, discoverable, and the cursor
/// change comes with it.
struct PanelResizeGrip: View {
    let onDrag: (CGSize) -> Void
    let onEnd: () -> Void

    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<(row + 1), id: \.self) { _ in
                            Circle()
                                .fill(PSTheme.textMuted)
                                .frame(width: 2, height: 2)
                        }
                    }
                }
            }
            .padding(4)
        }
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
        .onHover { inside in
            guard inside != hovering else { return }
            hovering = inside
            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { onDrag($0.translation) }
                .onEnded { _ in onEnd() }
        )
        .help("Drag to resize")
        .accessibilityLabel("Resize panel")
    }
}
