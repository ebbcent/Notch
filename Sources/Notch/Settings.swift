import Foundation

/// User preferences, stored in UserDefaults (local only).
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var theme: ThemeKind {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }

    private init() {
        theme = ThemeKind(rawValue: defaults.string(forKey: "theme") ?? "") ?? .darkMatte
    }
}
