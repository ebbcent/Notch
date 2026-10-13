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
        .animation(.easeInOut(duration: 0.2), value: settings.theme)
    }

    @ViewBuilder
    private func content(palette: Palette) -> some View {
        let notch = model.geometry.notchSize
        switch model.state {
        case .resting:
            Color.clear
        case .compact:
            CompactView(palette: palette, notchSize: notch)
                .transition(.opacity)
        case .peek:
            if let peek = model.peek {
                PeekView(peek: peek, palette: palette)
                    .padding(.top, notch.height)
                    .frame(height: notch.height + Layout.peekExtraHeight)
                    .transition(.opacity)
            }
        case .expanded:
            ExpandedView(palette: palette)
                .padding(.top, notch.height + Layout.tileTopGap)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }
}

/// Black pill to the sides of the notch. Filled in at the Claude Code step.
struct CompactView: View {
    let palette: Palette
    let notchSize: CGSize

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "sparkle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.accent)
                .frame(width: Layout.compactSide)
            Spacer().frame(width: notchSize.width)
            Circle()
                .fill(palette.accent)
                .frame(width: 6, height: 6)
                .frame(width: Layout.compactSide)
        }
        .frame(height: notchSize.height)
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

/// The open island: a row of tiles and, below, the lyrics.
/// Tiles are empty frames for now; their content comes in the next step.
struct ExpandedView: View {
    let palette: Palette

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Layout.tileGap) {
                Tile(palette: palette, width: Layout.wideTile) { placeholder("Music") }
                Tile(palette: palette, width: Layout.wideTile) { placeholder("Weather") }
                Tile(palette: palette, width: Layout.wideTile) { placeholder("Calendar") }
                Tile(palette: palette, width: Layout.narrowTile) { placeholder("Timer") }
            }
            .padding(.horizontal, Layout.outerPadding)
            Spacer(minLength: 0)
        }
    }

    private func placeholder(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(palette.secondary)
    }
}

struct Tile<Content: View>: View {
    let palette: Palette
    let width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(width: width, height: Layout.tileHeight)
            .background(RoundedRectangle(cornerRadius: Layout.tileRadius, style: .continuous).fill(palette.tile))
    }
}
