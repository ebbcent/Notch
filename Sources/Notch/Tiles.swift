import SwiftUI

/// The open island: a row of tiles and, below, the current lyrics.
struct ExpandedView: View {
    let palette: Palette
    @ObservedObject var settings: Settings
    let showsLyrics: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Layout.tileGap) {
                ForEach(settings.visibleTiles, id: \.self) { kind in
                    switch kind {
                    case .music: MusicTile(palette: palette)
                    case .weather: WeatherTile(palette: palette)
                    case .calendar: CalendarTile(palette: palette)
                    case .timer: TimerTile(palette: palette)
                    }
                }
            }
            if showsLyrics {
                LyricsView(palette: palette)
                    .frame(height: Layout.lyricsHeight)
                    .transition(.opacity)
            }
        }
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

/// A short message in a tile (no data, no permission…).
struct TileMessage: View {
    let palette: Palette
    let symbol: String
    let text: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(palette.secondary)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.accent)
            }
        }
        .padding(.horizontal, 10)
    }
}

/// Plain icon button used in the tiles.
struct IconButton: View {
    let symbol: String
    let size: CGFloat
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Music

struct MusicTile: View {
    let palette: Palette
    @EnvironmentObject var music: MusicService

    var body: some View {
        Tile(palette: palette, width: Layout.wideTile) {
            if let track = music.nowPlaying {
                HStack(spacing: 10) {
                    cover
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(track.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.text)
                        Text(track.artist)
                            .font(.system(size: 13))
                            .foregroundStyle(palette.secondary)
                            .padding(.top, 1)
                        Spacer(minLength: 0)
                        TimelineView(.periodic(from: .now, by: 0.5)) { context in
                            ProgressBar(fraction: track.duration > 0 ? track.position(at: context.date) / track.duration : 0,
                                        palette: palette)
                        }
                        .padding(.bottom, 4)
                        HStack(spacing: 0) {
                            IconButton(symbol: "backward.fill", size: 12, color: palette.text) { music.previous() }
                            Spacer(minLength: 0)
                            IconButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 14,
                                       color: palette.text) { music.playPause() }
                            Spacer(minLength: 0)
                            IconButton(symbol: "forward.fill", size: 12, color: palette.text) { music.next() }
                        }
                        .padding(.horizontal, -6)
                    }
                    .lineLimit(1)
                    .frame(height: 64)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if let denied = music.deniedPlayer {
                TileMessage(palette: palette, symbol: "lock",
                            text: "Allow Notch to control \(denied.name) in System Settings › Privacy › Automation")
            } else {
                TileMessage(palette: palette, symbol: "music.note", text: "Nothing playing in Spotify or Music")
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let artwork = music.artwork {
            Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                palette.secondary.opacity(0.18)
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(palette.secondary)
            }
        }
    }
}

struct ProgressBar: View {
    let fraction: Double
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.secondary.opacity(0.25))
                Capsule().fill(palette.text).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 3)
    }
}

struct LyricsView: View {
    let palette: Palette
    @EnvironmentObject var music: MusicService

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let position = music.nowPlaying?.position(at: context.date) ?? 0
            let lines = music.lyricLines(at: position)
            VStack(spacing: 2) {
                Text(lines?.current.isEmpty == false ? lines!.current : "♪")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(palette.text)
                Text(lines?.next ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, Layout.outerPadding)
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.easeInOut(duration: 0.2), value: lines?.current)
        }
    }
}

// MARK: - Weather

struct WeatherTile: View {
    let palette: Palette
    @EnvironmentObject var weather: WeatherService

    var body: some View {
        Tile(palette: palette, width: Layout.wideTile) {
            switch weather.status {
            case .ready(let now):
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(Int(now.temperature.rounded()))°")
                                .font(.system(size: 31))
                                .foregroundStyle(palette.text)
                            Text(now.city)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(palette.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        icon(now.symbol)
                    }
                    Spacer(minLength: 0)
                    Text("H \(Int(now.high.rounded()))°  L \(Int(now.low.rounded()))°")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.secondary)
                }
                .padding(.top, 8)
                .padding(.bottom, 10)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .noCity:
                TileMessage(palette: palette, symbol: "location", text: "Set a city in the menu bar › Weather City…")
            case .loading:
                ProgressView().controlSize(.small)
            case .cityNotFound:
                TileMessage(palette: palette, symbol: "questionmark", text: "City not found")
            case .offline:
                TileMessage(palette: palette, symbol: "wifi.slash", text: "Weather unavailable")
            }
        }
    }

    @ViewBuilder
    private func icon(_ symbol: String) -> some View {
        let image = Image(systemName: symbol).font(.system(size: 26))
        if symbol.hasPrefix("cloud") {
            // Cloud in the text colour, rain/sun/bolt in the accent: flat, no gradient.
            image.symbolRenderingMode(.palette).foregroundStyle(palette.text, palette.accent)
        } else {
            image.foregroundStyle(palette.accent)
        }
    }
}

// MARK: - Calendar

struct CalendarTile: View {
    let palette: Palette
    @EnvironmentObject var calendar: CalendarService

    var body: some View {
        Tile(palette: palette, width: Layout.wideTile) {
            switch calendar.status {
            case .event(let title, let start, let end, let allDay):
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Self.weekday(start))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.secondary)
                        Text(Self.day(start))
                            .font(.system(size: 31))
                            .foregroundStyle(palette.text)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(palette.text)
                            .lineLimit(2)
                        Text(allDay ? "All day" : "\(Self.time(start)) - \(Self.time(end))")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 10)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            case .empty:
                TileMessage(palette: palette, symbol: "calendar", text: "No upcoming events")
            case .denied:
                TileMessage(palette: palette, symbol: "lock", text: "Calendar access is off",
                            action: ("Open Settings", { calendar.openPrivacySettings() }))
            case .notAsked:
                TileMessage(palette: palette, symbol: "calendar", text: "Calendar")
            }
        }
    }

    private static func weekday(_ date: Date) -> String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE")
        return f.string(from: date).uppercased().replacingOccurrences(of: ".", with: "")
    }

    private static func day(_ date: Date) -> String {
        String(Calendar.current.component(.day, from: date))
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Focus timer

struct TimerTile: View {
    let palette: Palette
    @EnvironmentObject var timer: FocusTimer

    var body: some View {
        Tile(palette: palette, width: Layout.narrowTile) {
            VStack(spacing: 7) {
                Text(timer.label)
                    .font(.system(size: 17).monospacedDigit())
                    .foregroundStyle(timer.isRunning ? palette.accent : palette.text)
                HStack(spacing: 4) {
                    pill(timer.isRunning ? "pause.fill" : "play.fill") { timer.toggle() }
                    if !timer.isAtStart {
                        pill("arrow.counterclockwise") { timer.reset() }
                    }
                }
            }
            .padding(.top, 9)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func pill(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(palette.text)
                .frame(width: 30, height: 22)
                .background(Capsule().fill(palette.secondary.opacity(0.2)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
