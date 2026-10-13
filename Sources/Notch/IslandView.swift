import SwiftUI

/// The island outline: a body with rounded bottom corners and two small
/// concave "ears" at the top, so it blends into the notch / screen edge.
struct IslandShape: Shape {
    var earRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(earRadius, bottomRadius) }
        set { earRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let e = max(0, earRadius)
        let b = max(0, min(bottomRadius, (r.width - 2 * e) / 2, r.height - e))
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + e + b, y: r.maxY), control: CGPoint(x: r.minX + e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - b), control: CGPoint(x: r.maxX - e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var settings: Settings
    @EnvironmentObject var claude: ClaudeService

    var body: some View {
        let palette = settings.theme.palette
        let themed = model.state == .peek || model.state == .expanded
        let shape = IslandShape(earRadius: model.earRadius, bottomRadius: model.bottomRadius)
        let notch = model.geometry.notchSize

        ZStack(alignment: .top) {
            shape
                .fill(themed ? palette.background : Color.black)
                .shadow(color: .black.opacity(model.state == .resting ? 0 : 0.35), radius: 14, y: 6)

            // The real notch: always black.
            UnevenRoundedRectangle(bottomLeadingRadius: Layout.notchRadius,
                                   bottomTrailingRadius: Layout.notchRadius)
                .fill(Color.black)
                .frame(width: notch.width, height: notch.height)

            content(palette: palette)
                .frame(width: model.size.width, height: model.size.height, alignment: .top)
                .clipShape(shape)
        }
        .frame(width: model.size.width, height: model.size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: model.state)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: model.size)
        .animation(.easeInOut(duration: 0.2), value: settings.theme)
    }

    @ViewBuilder
    private func content(palette: Palette) -> some View {
        let notch = model.geometry.notchSize
        switch model.state {
        case .resting:
            Color.clear
        case .compact:
            ClaudeCompactView(palette: palette, notchSize: notch)
                .transition(.opacity)
        case .peek:
            if let peek = model.peek {
                PeekView(peek: peek, palette: palette)
                    .padding(.top, notch.height)
                    .frame(height: notch.height + Layout.peekExtraHeight)
                    .transition(.opacity)
            }
        case .expanded:
            if let request = claude.current {
                PermissionCard(request: request, palette: palette, pendingCount: claude.requests.count)
                    .id(request.id)
                    .padding(.top, notch.height)
                    .transition(.opacity)
            } else {
                ExpandedView(palette: palette, settings: settings, showsLyrics: model.showsLyrics)
                    .padding(.top, notch.height + Layout.tileTopGap)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
    }
}

struct PeekView: View {
    let peek: Peek
    let palette: Palette

    var body: some View {
        HStack(spacing: 8) {
            if let icon = peek.icon {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else if let symbol = peek.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
            Text(peek.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.text)
            if let subtitle = peek.subtitle {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondary)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 16)
    }
}
