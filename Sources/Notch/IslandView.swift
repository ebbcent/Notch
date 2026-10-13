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
                .shadow(color: .black.opacity(model.needsShadowRoom ? 0.35 : 0), radius: 14, y: 6)

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
        case .resting, .compact:
            Color.clear // the live activity is in PillView
        case .peek:
            if let peek = model.peek {
                PeekView(peek: peek, palette: palette)
                    .padding(.top, notch.height)
                    .frame(height: notch.height + Layout.peekExtraHeight)
                    .transition(.opacity)
            }
        case .expanded:
            ExpandedView(palette: palette, settings: settings, showsLyrics: model.showsLyrics)
                .padding(.top, notch.height + Layout.tileTopGap)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
        }
    }
}

/// Live activity in the black pill beside the notch: the focus timer while it runs,
/// otherwise the music playing (cover and title on the left, moving bars on the right).
/// The pill is always black, so it always uses the Dark Matte colours.
struct LiveActivityView: View {
    let notchSize: CGSize
    @EnvironmentObject var timer: FocusTimer
    @EnvironmentObject var music: MusicService
    @EnvironmentObject var island: IslandModel

    private let palette = ThemeKind.darkMatte.palette

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: island.compactSide + Layout.pillEar, alignment: timer.isRunning ? .center : .leading)
            Spacer().frame(width: notchSize.width)
            trailing
                .frame(width: island.compactSide + Layout.pillEar, alignment: timer.isRunning ? .center : .trailing)
        }
        .frame(height: notchSize.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder private var leading: some View {
        if timer.isRunning {
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.accent)
        } else if let track = music.nowPlaying {
            HStack(spacing: 7) {
                cover
                Text(track.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, Layout.pillEar + 8)
            .padding(.trailing, 6)
        }
    }

    @ViewBuilder private var cover: some View {
        if let artwork = music.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(palette.tile)
                .frame(width: 20, height: 20)
                .overlay(Image(systemName: "music.note")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(palette.accent))
        }
    }

    @ViewBuilder private var trailing: some View {
        if timer.isRunning {
            Text(timer.label)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(palette.accent)
                .minimumScaleFactor(0.8)
        } else {
            EqualizerBars(color: palette.accent, playing: music.nowPlaying?.isPlaying == true)
                .padding(.trailing, Layout.pillEar + 10)
        }
    }

    private var accessibilityText: String {
        if timer.isRunning { return "Focus timer, \(timer.label) left" }
        if let track = music.nowPlaying { return "Playing \(track.title) by \(track.artist)" }
        return ""
    }
}

/// The live activity pill, in a window that never takes the mouse: what is under it in
/// the menu bar stays clickable. It sits below the island window, which covers it when open.
struct PillView: View {
    @EnvironmentObject var island: IslandModel

    var body: some View {
        let notch = island.geometry.notchSize
        let shown = island.compactActive
        let size = shown ? island.pillSize : notch
        ZStack(alignment: .top) {
            IslandShape(earRadius: shown ? Layout.pillEar : 0, bottomRadius: shown ? 12 : Layout.notchRadius)
                .fill(Color.black)
            if shown {
                LiveActivityView(notchSize: notch)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .opacity(shown ? 1 : 0)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: shown)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: island.compactSide)
    }
}

/// Four bars moving like a level meter (flat, accent colour).
struct EqualizerBars: View {
    let color: Color
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * (5 + Double(i) * 1.3) + Double(i) * 1.7
                    let level = playing ? 0.35 + 0.65 * abs(sin(phase)) : 0.3
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: 12 * level)
                }
            }
            .frame(height: 12)
        }
    }
}

struct PeekView: View {
    let peek: Peek
    let palette: Palette
    @EnvironmentObject var music: MusicService

    var body: some View {
        HStack(spacing: 8) {
            if peek.music, let cover = music.artwork {
                Image(nsImage: cover)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else if let icon = peek.icon {
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
