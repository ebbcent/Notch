import AppKit
import Carbon
import CryptoKit

enum Player: String {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    var name: String { self == .spotify ? "Spotify" : "Music" }
}

struct NowPlaying: Equatable {
    var player: Player
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var position: Double
    var isPlaying: Bool
    var fetchedAt: Date
    var trackID: String

    /// Position now, interpolated between polls.
    func position(at date: Date) -> Double {
        let p = position + (isPlaying ? date.timeIntervalSince(fetchedAt) : 0)
        return duration > 0 ? min(max(p, 0), duration) : max(p, 0)
    }
}

struct LyricLine: Equatable {
    var time: Double
    var text: String
}

/// Reads Spotify and Music through AppleScript. Never launches them:
/// a player is only scripted while it is already running.
@MainActor
final class MusicService: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var lyrics: [LyricLine] = []
    /// Set when the user refused Automation for a player.
    @Published private(set) var deniedPlayer: Player?

    private let settings: Settings
    private var pollTask: Task<Void, Never>?
    private var checkedPermission: Set<Player> = []
    private var artworkTrack: String?
    private var lyricsTrack: String?

    init(settings: Settings) {
        self.settings = settings
    }

    /// Polls the players every second while the island is open, not at all otherwise.
    /// The first poll is also when macOS asks for the Automation permission.
    func setActive(_ on: Bool) {
        pollTask?.cancel()
        pollTask = nil
        guard on else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Controls

    func playPause() { send("playpause") }
    func next() { send("next track") }
    func previous() { send("previous track") }

    private func send(_ command: String) {
        guard let player = nowPlaying?.player else { return }
        Task {
            _ = await AppleScript.run("tell application id \"\(player.rawValue)\" to \(command)")
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
        }
    }

    // MARK: Polling

    private func runningPlayers() -> [Player] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return [Player.spotify, .music].filter { running.contains($0.rawValue) }
    }

    func refresh() async {
        var states: [NowPlaying] = []
        for player in runningPlayers() {
            if !checkedPermission.contains(player) {
                checkedPermission.insert(player)
                // Asks once per player; macOS remembers the answer.
                let status = await AppleScript.automationPermission(for: player.rawValue)
                if status == -1743 { // errAEEventNotPermitted
                    deniedPlayer = player
                    continue
                }
                if deniedPlayer == player { deniedPlayer = nil }
            }
            if deniedPlayer == player { continue }
            if let state = await Self.read(player) { states.append(state) }
        }
        let current = states.first(where: \.isPlaying) ?? states.first
        if current != nowPlaying { nowPlaying = current }
        if let current {
            if artworkTrack != current.trackID { loadArtwork(for: current) }
            if lyricsTrack != current.trackID { loadLyrics(for: current) }
        } else {
            artwork = nil
            lyrics = []
            artworkTrack = nil
            lyricsTrack = nil
        }
    }

    private static func read(_ player: Player) async -> NowPlaying? {
        let source: String
        switch player {
        case .spotify:
            source = """
            tell application id "com.spotify.client"
                set s to player state as text
                if s is "stopped" then return {s}
                set t to current track
                return {s, name of t, artist of t, album of t, (duration of t) / 1000, player position, id of t}
            end tell
            """
        case .music:
            source = """
            tell application id "com.apple.Music"
                set s to player state as text
                if s is "stopped" then return {s}
                try
                    set t to current track
                    return {s, name of t, artist of t, album of t, duration of t, player position, (persistent ID of t) as text}
                on error
                    return {"stopped"}
                end try
            end tell
            """
        }
        let values = await AppleScript.run(source)
        guard values.count >= 7, case .text(let state)? = values.first else { return nil }
        return NowPlaying(player: player,
                          title: values[1].string, artist: values[2].string, album: values[3].string,
                          duration: values[4].number, position: values[5].number,
                          isPlaying: state == "playing", fetchedAt: Date(),
                          trackID: player.rawValue + ":" + values[6].string)
    }

    // MARK: Artwork

    private func loadArtwork(for track: NowPlaying) {
        artworkTrack = track.trackID
        artwork = nil
        Task {
            var image: NSImage?
            switch track.player {
            case .music:
                let values = await AppleScript.run("""
                tell application id "com.apple.Music"
                    try
                        return {raw data of artwork 1 of current track}
                    end try
                end tell
                """)
                if case .data(let data)? = values.first { image = NSImage(data: data) }
            case .spotify:
                // Off by default: fetching the cover is a request to Spotify's servers.
                guard settings.spotifyCovers else { break }
                let values = await AppleScript.run("tell application id \"com.spotify.client\" to return {artwork url of current track}")
                if let url = URL(string: values.first?.string ?? ""),
                   let result = try? await Net.session.data(from: url) {
                    image = NSImage(data: result.0)
                }
            }
            if artworkTrack == track.trackID { artwork = image }
        }
    }

    // MARK: Lyrics

    private func loadLyrics(for track: NowPlaying) {
        lyricsTrack = track.trackID
        lyrics = []
        Task {
            let lines = await LyricsStore.lyrics(title: track.title, artist: track.artist,
                                                 album: track.album, duration: track.duration)
            if lyricsTrack == track.trackID { lyrics = lines }
        }
    }

    /// The current line and the next one at a given position.
    func lyricLines(at position: Double) -> (current: String, next: String)? {
        guard !lyrics.isEmpty else { return nil }
        let p = position + 0.3
        guard let index = lyrics.lastIndex(where: { $0.time <= p }) else {
            return ("", lyrics[0].text)
        }
        let next = index + 1 < lyrics.count ? lyrics[index + 1].text : ""
        return (lyrics[index].text, next)
    }
}

// MARK: - AppleScript

enum ScriptValue: Sendable {
    case text(String)
    case number(Double)
    case data(Data)
    case none

    var string: String {
        switch self {
        case .text(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        default: return ""
        }
    }

    var number: Double {
        switch self {
        case .number(let n): return n
        case .text(let s): return Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0
        default: return 0
        }
    }
}

/// Runs AppleScript off the main thread, one script at a time.
enum AppleScript {
    private static let queue = DispatchQueue(label: "local.notch.applescript")

    static func run(_ source: String) async -> [ScriptValue] {
        await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
                continuation.resume(returning: result.map(values) ?? [])
            }
        }
    }

    /// Asks for the Automation permission if macOS has not asked yet.
    static func automationPermission(for bundleID: String) async -> OSStatus {
        await withCheckedContinuation { continuation in
            queue.async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                let any = code("****")
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, any, any, true)
                continuation.resume(returning: status)
            }
        }
    }

    private static func code(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }

    private static func values(_ d: NSAppleEventDescriptor) -> [ScriptValue] {
        if d.descriptorType == code("list") {
            guard d.numberOfItems > 0 else { return [] }
            return (1...d.numberOfItems).map { i in d.atIndex(i).map { value($0) } ?? .none }
        }
        return [value(d)]
    }

    private static func value(_ d: NSAppleEventDescriptor) -> ScriptValue {
        let type = d.descriptorType
        if [code("utxt"), code("utf8"), code("TEXT"), code("enum")].contains(type) {
            return .text(d.stringValue ?? "")
        }
        if [code("shor"), code("long"), code("comp"), code("magn"), code("sing"), code("doub")].contains(type) {
            return .number(d.doubleValue)
        }
        if type == code("type") || type == code("null") {
            return .none // missing value
        }
        return d.data.isEmpty ? .none : .data(d.data)
    }
}

// MARK: - Network (only LRCLIB and Open-Meteo, plus opt-in Spotify covers)

enum Net {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": "Notch/0.1 (local macOS app)"]
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()
}

// MARK: - Lyrics (LRCLIB, cached on disk)

enum LyricsStore {
    private struct Response: Decodable {
        let syncedLyrics: String?
        let duration: Double?
    }

    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("local.notch.island/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func lyrics(title: String, artist: String, album: String, duration: Double) async -> [LyricLine] {
        let key = SHA256.hash(data: Data("\(artist)\n\(title)\n\(Int(duration.rounded()))".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let file = cacheDir.appendingPathComponent(key + ".lrc")
        if let cached = try? String(contentsOf: file, encoding: .utf8) {
            return parse(cached) // an empty file means "no synced lyrics"
        }
        guard let lrc = await fetch(title: title, artist: artist, album: album, duration: duration) else {
            return [] // network error: do not cache, try again next time
        }
        try? lrc.write(to: file, atomically: true, encoding: .utf8)
        return parse(lrc)
    }

    /// Returns "" when LRCLIB has no synced lyrics, nil on network error.
    private static func fetch(title: String, artist: String, album: String, duration: Double) async -> String? {
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [URLQueryItem(name: "track_name", value: title),
                          URLQueryItem(name: "artist_name", value: artist),
                          URLQueryItem(name: "album_name", value: album),
                          URLQueryItem(name: "duration", value: String(Int(duration.rounded())))]
        guard let got = try? await Net.session.data(from: get.url!),
              let http = got.1 as? HTTPURLResponse else { return nil }
        if http.statusCode == 200, let r = try? JSONDecoder().decode(Response.self, from: got.0),
           let synced = r.syncedLyrics, !synced.isEmpty {
            return synced
        }
        guard http.statusCode == 200 || http.statusCode == 404 else { return nil }

        // Not found with the exact album/duration: search and take the closest duration.
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: title),
                             URLQueryItem(name: "artist_name", value: artist)]
        guard let found = try? await Net.session.data(from: search.url!),
              (found.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        let results = (try? JSONDecoder().decode([Response].self, from: found.0)) ?? []
        let match = results
            .filter { ($0.syncedLyrics ?? "").isEmpty == false && abs(($0.duration ?? 0) - duration) <= 3 }
            .min { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }
        return match?.syncedLyrics ?? ""
    }

    /// Parses "[mm:ss.xx] text" lines (several time tags per line allowed).
    static func parse(_ lrc: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                let parts = tag.split(separator: ":")
                if parts.count == 2, let m = Double(parts[0]), let s = Double(parts[1]) {
                    times.append(m * 60 + s)
                }
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            lines += times.map { LyricLine(time: $0, text: text) }
        }
        return lines.sorted { $0.time < $1.time }
    }
}
