import SwiftUI

/// The two flat themes. The black band of the real notch is never themed.
enum ThemeKind: String, CaseIterable {
    case darkMatte
    case whiteMatte

    var title: String {
        switch self {
        case .darkMatte: return "Dark Matte"
        case .whiteMatte: return "White Matte"
        }
    }

    var palette: Palette {
        switch self {
        case .darkMatte:
            return Palette(background: Color(hex: 0x16181F), tile: Color(hex: 0x21242D),
                           text: Color(hex: 0xE3E7EF), secondary: Color(hex: 0xA4ABBA),
                           accent: Color(hex: 0x8FC7FF))
        case .whiteMatte:
            return Palette(background: Color(hex: 0xF7F8FA), tile: Color(hex: 0xFBFBFC),
                           text: Color(hex: 0x1E2129), secondary: Color(hex: 0x545A69),
                           accent: Color(hex: 0x3B82D0))
        }
    }
}

struct Palette {
    let background: Color
    let tile: Color
    let text: Color
    let secondary: Color
    let accent: Color
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
