import AppKit
import SwiftUI
import Combine

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
    private var cancellables: Set<AnyCancellable> = []
    private let settings: Settings
    private let music: MusicService
    private let weather: WeatherService
    private let calendar: CalendarService
    private let timer: FocusTimer

    init(settings: Settings, music: MusicService, weather: WeatherService,
         calendar: CalendarService, timer: FocusTimer) {
        self.settings = settings
        self.music = music
        self.weather = weather
        self.calendar = calendar
        self.timer = timer
        panel = IslandPanel.make()
        tracker = MouseTracker()
        let screen = NotchGeometry.preferredScreen()
        model = IslandModel(geometry: screen.map { NotchGeometry(screen: $0) } ?? .fallback)

        let root = IslandView(model: model, settings: settings)
            .environmentObject(music)
            .environmentObject(weather)
            .environmentObject(calendar)
            .environmentObject(timer)
        let hosting = IslandHostingView(rootView: AnyView(root))
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
        installMonitors()
        observeContent()
    }

    /// Keeps the island size in step with the tiles, and wakes the tiles when it opens.
    private func observeContent() {
        let main = DispatchQueue.main
        settings.$tileOrder.map { _ in () }
            .merge(with: settings.$hiddenTiles.map { _ in () },
                   music.$nowPlaying.map { _ in () },
                   music.$lyrics.map { _ in () })
            .receive(on: main)
            .sink { [weak self] in self?.syncLayout() }
            .store(in: &cancellables)

        model.$state
            .removeDuplicates()
            .receive(on: main)
            .sink { [weak self] _ in self?.contentChanged() }
            .store(in: &cancellables)

        // Live activities keep the compact pill out: the focus timer, or music playing.
        timer.$isRunning.map { _ in () }
            .merge(with: music.$nowPlaying.map { _ in () }, settings.$liveActivity.map { _ in () })
            .receive(on: main)
            .sink { [weak self] in self?.syncLiveActivity() }
            .store(in: &cancellables)

        music.onTrackStart = { [weak self] track in
            guard let self, self.settings.liveActivity, self.model.state != .expanded else { return }
            self.model.showPeek(Peek(symbol: "music.note", icon: self.music.artwork,
                                     title: track.title, subtitle: track.artist), seconds: 3)
        }

        // The window follows the island's size (see fitWindow).
        Publishers.MergeMany(model.$state.map { _ in () }.eraseToAnyPublisher(),
                             model.$expandedBodyWidth.map { _ in () }.eraseToAnyPublisher(),
                             model.$showsLyrics.map { _ in () }.eraseToAnyPublisher(),
                             model.$geometry.map { _ in () }.eraseToAnyPublisher())
            .receive(on: main)
            .sink { [weak self] in self?.fitWindow() }
            .store(in: &cancellables)
    }

    private func syncLiveActivity() {
        let musicPlaying = settings.liveActivity && music.nowPlaying?.isPlaying == true
        model.compactActive = timer.isRunning || musicPlaying
    }

    private func syncLayout() {
        model.expandedBodyWidth = settings.expandedBodyWidth
        model.showsLyrics = settings.isVisible(.music) && music.nowPlaying != nil && !music.lyrics.isEmpty
    }

    /// Wakes the tiles when the island opens, and puts music polling to sleep when it closes.
    private func contentChanged() {
        let tilesShown = model.state == .expanded
        music.setActive(tilesShown && settings.isVisible(.music))
        guard tilesShown else { return }
        if settings.isVisible(.weather) { weather.refresh() }
        if settings.isVisible(.calendar) { calendar.activate() }
    }

    /// Re-reads the notch geometry (screens added, removed or rearranged).
    func reposition() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry(screen: screen)
        if geometry != model.geometry { model.geometry = geometry }
        fitWindow(immediately: true)
        panel.orderFrontRegardless()
    }

    /// The window is exactly as big as the island (plus room for the shadow when open),
    /// so it only takes the mouse where the island is. That lets a tracking area on the
    /// panel see the pointer arrive on the notch, without a timer or a global monitor.
    /// It grows at once when the island grows, and shrinks once the animation is over.
    private var shrinkGeneration = 0

    private func fitWindow(immediately: Bool = false) {
        let g = model.geometry
        let size = model.size
        let pad = model.needsShadowRoom ? Layout.shadowPad : 0
        let margin = model.needsShadowRoom ? 0 : Layout.hoverMargin
        let width = size.width + 2 * (pad + margin)
        let height = size.height + pad
        let target = CGRect(x: (g.screenFrame.midX - width / 2).rounded(),
                            y: g.screenFrame.maxY - height,
                            width: width.rounded(), height: height)
        shrinkGeneration += 1
        if immediately || panel.frame.isEmpty {
            panel.setFrame(target, display: true)
            return
        }
        let union = panel.frame.union(target)
        if union != panel.frame { panel.setFrame(union, display: true) }
        guard union != target else { return }
        let generation = shrinkGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.shrinkGeneration == generation else { return }
            self.panel.setFrame(target, display: true)
            self.mouseMoved() // the pointer may now be outside the window
        }
    }

    private func installMonitors() {
        // Clicks elsewhere release a pinned island (mouse-down events reach global monitors).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.model.hotRect.contains(NSEvent.mouseLocation) else { return }
                self.model.clickOutside()
            }
        }) { monitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                // A click keeps the island open.
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
        model.setHover(model.hotRect.contains(NSEvent.mouseLocation))
    }
}
