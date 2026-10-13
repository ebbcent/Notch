import AppKit
import SwiftUI

/// Sizes measured on the reference screenshot (2x image, values in points).
enum Layout {
    static let expandedBodyWidth: CGFloat = 680   // 22 + 3×176 + 84 + 3×8 + 22 (all tiles)
    static let tilesBlockHeight: CGFloat = 132    // 18 + 96 + 18, below the notch band
    static let lyricsHeight: CGFloat = 54         // replaces the 18 pt bottom margin
    static var expandedExtraHeight: CGFloat { tilesBlockHeight - 18 + lyricsHeight }
    static let outerPadding: CGFloat = 22
    static let tileGap: CGFloat = 8
    static let tileTopGap: CGFloat = 18
    static let tileHeight: CGFloat = 96
    static let wideTile: CGFloat = 176
    static let narrowTile: CGFloat = 84
    static let tileRadius: CGFloat = 12

    static let compactSide: CGFloat = 38          // each side of the notch
    static let peekExtraHeight: CGFloat = 40
    static let peekMinWidth: CGFloat = 300

    static let notchRadius: CGFloat = 9           // bottom corners of the black band
    static let shadowPad: CGFloat = 40            // room for the shadow inside the window
    static let maxEar: CGFloat = 10
}

/// Where the notch is on the screen that has one (or where the fake one goes).
struct NotchGeometry: Equatable {
    var screenFrame: CGRect
    var notchSize: CGSize
    var hasNotch: Bool

    @MainActor
    init(screen: NSScreen) {
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchSize = CGSize(width: screen.frame.width - left.width - right.width,
                               height: screen.safeAreaInsets.top)
            hasNotch = true
        } else {
            let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
            notchSize = CGSize(width: 185, height: menuBar > 0 ? menuBar : 24)
            hasNotch = false
        }
    }

    init(screenFrame: CGRect, notchSize: CGSize, hasNotch: Bool) {
        self.screenFrame = screenFrame
        self.notchSize = notchSize
        self.hasNotch = hasNotch
    }

    /// Used only if macOS reports no screen at all.
    static let fallback = NotchGeometry(screenFrame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                                        notchSize: CGSize(width: 185, height: 32), hasNotch: false)

    /// The screen with a notch, else the main screen.
    @MainActor
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

/// A small bubble shown under the notch for a few seconds.
struct Peek: Equatable {
    var symbol: String?
    var icon: NSImage?
    var title: String
    var subtitle: String?
}

@MainActor
final class IslandModel: ObservableObject {
    enum State { case resting, compact, peek, expanded }

    @Published private(set) var state: State = .resting
    @Published private(set) var peek: Peek?
    @Published var geometry: NotchGeometry
    /// Something wants the compact pill (e.g. Claude Code is working).
    @Published var compactActive = false { didSet { update() } }
    /// Set from the visible tiles and the music state.
    @Published var expandedBodyWidth: CGFloat = Layout.expandedBodyWidth
    @Published var showsLyrics = false

    private(set) var pinned = false
    private var hovering = false
    private var wantsExpanded = false
    private var hoverTask: Task<Void, Never>?
    private var peekTask: Task<Void, Never>?

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    // MARK: Shape per state

    var earRadius: CGFloat {
        switch state {
        case .resting: return 0
        case .compact: return 6
        case .peek, .expanded: return Layout.maxEar
        }
    }

    var bottomRadius: CGFloat {
        switch state {
        case .resting: return Layout.notchRadius
        case .compact: return 12
        case .peek: return 18
        case .expanded: return 24
        }
    }

    /// Full size of the island, ears included.
    var size: CGSize {
        let n = geometry.notchSize
        let ears = 2 * earRadius
        switch state {
        case .resting:
            return n
        case .compact:
            return CGSize(width: n.width + 2 * Layout.compactSide + ears, height: n.height)
        case .peek:
            return CGSize(width: max(n.width + 2 * Layout.compactSide, Layout.peekMinWidth) + ears,
                          height: n.height + Layout.peekExtraHeight)
        case .expanded:
            let height = showsLyrics ? Layout.expandedExtraHeight : Layout.tilesBlockHeight
            return CGSize(width: expandedBodyWidth + ears, height: n.height + height)
        }
    }

    /// The area (screen coordinates) where the mouse counts as "on the island".
    var hotRect: CGRect {
        let s = size
        let f = geometry.screenFrame
        let body = CGRect(x: f.midX - s.width / 2 + earRadius, y: f.maxY - s.height,
                          width: s.width - 2 * earRadius, height: s.height)
        return state == .resting ? body.insetBy(dx: -6, dy: 0) : body
    }

    // MARK: Events

    func setHover(_ inside: Bool) {
        guard inside != hovering else { return }
        hovering = inside
        hoverTask?.cancel()
        if inside {
            hoverTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, self.hovering else { return }
                self.wantsExpanded = true
                self.update()
            }
        } else if !pinned {
            wantsExpanded = false
            update()
        }
    }

    /// A click on the island keeps it open; a second click releases it.
    func click() {
        hoverTask?.cancel()
        if pinned {
            pinned = false
        } else {
            pinned = true
            wantsExpanded = true
            update()
        }
    }

    func clickOutside() {
        guard pinned || wantsExpanded else { return }
        pinned = false
        if !hovering {
            wantsExpanded = false
            update()
        }
    }

    func expand(pin: Bool) {
        pinned = pin
        wantsExpanded = true
        update()
    }

    func collapse() {
        pinned = false
        wantsExpanded = false
        update()
    }

    func showPeek(_ peek: Peek, seconds: Double = 3) {
        self.peek = peek
        update()
        peekTask?.cancel()
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, !Task.isCancelled else { return }
            self.peek = nil
            self.update()
        }
    }

    private func update() {
        let next: State
        if wantsExpanded { next = .expanded }
        else if peek != nil { next = .peek }
        else if compactActive { next = .compact }
        else { next = .resting }
        if next != state { state = next }
    }
}
