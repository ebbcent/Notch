import AppKit
import SwiftUI

/// Borderless, transparent panel over the notch. Never takes focus.
final class IslandPanel: NSPanel {
    static func make() -> IslandPanel {
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.configure()
        return panel
    }

    private func configure() {
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3) // above the menu bar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false               // the shadow is drawn by SwiftUI
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true       // clicks pass through until the mouse is on the island
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets buttons inside the panel react to the first click without activating the app.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Receives the panel's tracking-area events.
final class MouseTracker: NSResponder {
    var onMove: () -> Void = {}
    override func mouseEntered(with event: NSEvent) { onMove() }
    override func mouseExited(with event: NSEvent) { onMove() }
    override func mouseMoved(with event: NSEvent) { onMove() }
}

@MainActor
final class IslandController {
    let model: IslandModel
    private let panel: IslandPanel
    private let tracker: MouseTracker
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    init(settings: Settings) {
        panel = IslandPanel.make()
        tracker = MouseTracker()
        let screen = NotchGeometry.preferredScreen()
        model = IslandModel(geometry: screen.map { NotchGeometry(screen: $0) } ?? .fallback)

        let hosting = IslandHostingView(rootView: IslandView(model: model, settings: settings))
        hosting.sizingOptions = []
        panel.contentView = hosting

        // Tracking area on the panel itself (the menu bar is not ours to track).
        tracker.onMove = { [weak self] in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        hosting.addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: tracker, userInfo: nil))

        reposition()
        panel.orderFrontRegardless()
        installMonitors()
    }

    /// Centre the panel on the notch of the screen that has one.
    func reposition() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        model.geometry = geometry
        let width = Layout.expandedBodyWidth + 2 * Layout.maxEar + 2 * Layout.shadowPad
        let height = geometry.notchSize.height + Layout.expandedExtraHeight + Layout.shadowPad
        let frame = CGRect(x: geometry.screenFrame.midX - width / 2,
                           y: geometry.screenFrame.maxY - height,
                           width: width, height: height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    private func installMonitors() {
        // While the mouse is elsewhere, the panel ignores events, so moves are seen globally.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { monitors.append(m) }

        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.model.hotRect.contains(NSEvent.mouseLocation) else { return }
                self.model.clickOutside()
            }
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window === self.panel, self.model.hotRect.contains(NSEvent.mouseLocation) {
                    self.model.click()
                }
            }
            return event
        }) { monitors.append(m) }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderFrontRegardless() }
        })
    }

    private func mouseMoved() {
        let inside = model.hotRect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }
        model.setHover(inside)
    }
}
