import Foundation

enum TileKind: String, CaseIterable, Codable {
    case music, weather, calendar, timer

    var title: String {
        switch self {
        case .music: return "Music"
        case .weather: return "Weather"
        case .calendar: return "Calendar"
        case .timer: return "Focus Timer"
        }
    }

    var width: CGFloat { self == .timer ? Layout.narrowTile : Layout.wideTile }
}

/// User preferences, stored in UserDefaults (local only).
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var theme: ThemeKind {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }
    @Published var city: String {
        didSet { defaults.set(city, forKey: "city") }
    }
    /// All tiles, in display order.
    @Published var tileOrder: [TileKind] {
        didSet { defaults.set(tileOrder.map(\.rawValue), forKey: "tileOrder") }
    }
    @Published var hiddenTiles: Set<TileKind> {
        didSet { defaults.set(hiddenTiles.map(\.rawValue), forKey: "hiddenTiles") }
    }
    /// Spotify only gives a URL for the cover, so showing it means a request to Spotify's servers.
    @Published var spotifyCovers: Bool {
        didSet { defaults.set(spotifyCovers, forKey: "spotifyCovers") }
    }

    /// Bubbles when a Focus (Do Not Disturb…) turns on or off. Off until the user turns it on.
    @Published var focusPeeks: Bool {
        didSet { defaults.set(focusPeeks, forKey: "focusPeeks") }
    }

    var visibleTiles: [TileKind] { tileOrder.filter { !hiddenTiles.contains($0) } }

    func isVisible(_ tile: TileKind) -> Bool { !hiddenTiles.contains(tile) }

    /// Width of the open island body for the visible tiles.
    var expandedBodyWidth: CGFloat {
        let tiles = visibleTiles
        let content = tiles.reduce(0) { $0 + $1.width } + CGFloat(max(tiles.count - 1, 0)) * Layout.tileGap
        return max(content + 2 * Layout.outerPadding, Layout.peekMinWidth)
    }

    private init() {
        theme = ThemeKind(rawValue: defaults.string(forKey: "theme") ?? "") ?? .darkMatte
        city = defaults.string(forKey: "city") ?? ""
        let stored = (defaults.stringArray(forKey: "tileOrder") ?? []).compactMap(TileKind.init(rawValue:))
        tileOrder = stored + TileKind.allCases.filter { !stored.contains($0) }
        hiddenTiles = Set((defaults.stringArray(forKey: "hiddenTiles") ?? []).compactMap(TileKind.init(rawValue:)))
        spotifyCovers = defaults.bool(forKey: "spotifyCovers")
        focusPeeks = defaults.bool(forKey: "focusPeeks")
    }
}
