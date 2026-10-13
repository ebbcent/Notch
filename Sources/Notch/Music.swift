import AppKit
import Carbon
import CryptoKit
import Combine
import os

enum MusicLog {
    /// Local log only (Console.app, subsystem local.notch.island).
    static let log = Logger(subsystem: "local.notch.island", category: "music")
}

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

    /// Same track and play state, and the position has not jumped (seek): no need to republish.
    func continues(_ other: NowPlaying?) -> Bool {
        guard let other, other.trackID == trackID, other.isPlaying == isPlaying,
              other.title == title, other.artist == artist else { return false }
        return abs(other.position(at: fetchedAt) - position) < 1.5
    }

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

/// Spotify and Music, never launched by Notch.
///
/// - Track and play state come from the notifications both players broadcast on every
///   change (no permission needed, nothing to poll): that is what the live activity uses.
/// - AppleScript, which needs the Automation permission, is used only while the island is
///   open: exact position for the lyrics, controls, and the Music cover.
@MainActor
final class MusicService: ObservableObject {
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var lyrics: [LyricLine] = []
    /// Players the user refused Automation for (the tile says how to allow it).
    @Published private(set) var deniedPlayers: Set<Player> = []
    var deniedPlayer: Player? { deniedPlayers.first }
    /// What macOS last answered for each player, and the last script error (Settings › Music).
    @Published private(set) var permissionStatus: [Player: OSStatus] = [:]
    @Published private(set) var lastError: [Player: String] = [:]

    /// Called when a new track starts playing (for the live activity bubble).
    var onTrackStart: (NowPlaying) -> Void = { _ in }

    private let settings: Settings
    private var states: [Player: NowPlaying] = [:]
    private var pollTask: Task<Void, Never>?
    private var active = false
    private var checkedPermission: Set<Player> = []
    private var artworkTrack: String?
    private var lyricsTrack: String?
    private var observers: [NSObjectProtocol] = []
    private var broadcasts: BroadcastListener?
    private var lyricsFailedTrack: String?
    private var coversObserver: AnyCancellable?

    init(settings: Settings) {
        self.settings = settings
        // Delivered at once even though Notch is never the active app (the default would
        // hold them until it becomes active).
        broadcasts = BroadcastListener { [weak self] name, info in
            let player: Player = name == BroadcastListener.spotify ? .spotify : .music
            self?.received(info, from: player)
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let id, let player = Player(rawValue: id) else { return }
                self?.states[player] = nil
                self?.publish()
            }
        })
        // The Spotify covers setting applies to the current track at once.
        coversObserver = settings.$spotifyCovers.dropFirst().removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.artworkTrack = nil
                self?.publish()
            }
        // Music already playing when Notch starts: read it, without asking for anything.
        Task { [weak self] in await self?.refresh(prompt: false) }
    }

    /// While the island is open: poll the players every second (position for the lyrics).
    /// The first poll is also when macOS asks for the Automation permission.
    func setActive(_ on: Bool) {
        active = on
        pollTask?.cancel()
        pollTask = nil
        guard on else { return }
        // A refusal may have been changed in System Settings since: ask macOS again (no dialog).
        checkedPermission.subtract(deniedPlayers)
        if let current = nowPlaying, lyricsTrack != current.trackID || lyricsFailedTrack == current.trackID {
            loadLyrics(for: current)
        }
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
            guard runningPlayers().contains(player), await ensurePermission(player) else { return }
            let result = await AppleScript.run(AppleScript.ifRunning(player.rawValue,
                "tell application id \"\(player.rawValue)\" to \(command)"))
            lastError[player] = result.error
            if let error = result.error {
                MusicLog.log.error("\(player.name, privacy: .public) \(command, privacy: .public) failed: \(error, privacy: .public)")
                if error.hasPrefix("-1743") { deniedPlayers.insert(player) }
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
        }
    }

    /// Asks macOS once per player (the system dialog), then remembers the answer.
    /// With `prompt: false` it only reports an answer already given, and never shows a dialog.
    private func ensurePermission(_ player: Player, prompt: Bool = true) async -> Bool {
        guard prompt else {
            return await AppleScript.automationPermission(for: player.rawValue, ask: false) == noErr
        }
        if !checkedPermission.contains(player) {
            checkedPermission.insert(player)
            let status = await AppleScript.automationPermission(for: player.rawValue, ask: true)
            permissionStatus[player] = status
            MusicLog.log.notice("Automation for \(player.name, privacy: .public): \(status)")
            if status == noErr {
                deniedPlayers.remove(player)
            } else if status == -600 { // the player quit meanwhile: ask next time
                checkedPermission.remove(player)
            } else {
                deniedPlayers.insert(player) // -1743 refused, -1744 could not ask
            }
        }
        return !deniedPlayers.contains(player)
    }

    /// Clears what macOS remembers about Notch controlling the players (it can hold an
    /// answer given to an older build and refuse silently), then asks again.
    func resetAutomationPermission() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "AppleEvents", Bundle.main.bundleIdentifier ?? "local.notch.island"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            MusicLog.log.error("tccutil failed: \(error.localizedDescription, privacy: .public)")
        }
        checkedPermission.removeAll()
        deniedPlayers.removeAll()
        permissionStatus.removeAll()
        lastError.removeAll()
        for player in runningPlayers() { _ = await ensurePermission(player) }
        await refresh()
        artworkTrack = nil
        publish()
    }

    /// Reads the current answer without asking (Settings › Music).
    func checkPermissions() async {
        for player in [Player.spotify, .music] {
            guard runningPlayers().contains(player) else {
                permissionStatus[player] = -600
                continue
            }
            permissionStatus[player] = await AppleScript.automationPermission(for: player.rawValue, ask: false)
        }
    }

    func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Broadcasts (no permission)

    private func received(_ info: [AnyHashable: Any], from player: Player) {
        guard let track = Self.track(from: info, player: player, previous: states[player]) else {
            states[player] = nil // stopped
            publish()
            return
        }
        states[player] = track
        publish(announce: true)
    }

    /// Builds the state from a player's broadcast. nil when the player stopped.
    nonisolated static func track(from info: [AnyHashable: Any], player: Player, previous: NowPlaying?) -> NowPlaying? {
        let state = (info["Player State"] as? String ?? "").lowercased()
        guard state == "playing" || state == "paused" else { return nil }
        let title = info["Name"] as? String ?? ""
        let artist = info["Artist"] as? String ?? ""
        let album = info["Album"] as? String ?? ""
        let id: String
        let durationMS: Double
        switch player {
        case .spotify:
            id = info["Track ID"] as? String ?? "\(artist)|\(title)"
            durationMS = (info["Duration"] as? NSNumber)?.doubleValue ?? 0
        case .music:
            id = (info["PersistentID"] as? NSNumber).map { String(UInt64(bitPattern: $0.int64Value), radix: 16) }
                ?? (info["PersistentID"] as? String) ?? "\(artist)|\(title)"
            durationMS = (info["Total Time"] as? NSNumber)?.doubleValue ?? 0
        }
        let trackID = player.rawValue + ":" + id
        let now = Date()
        // Spotify sends the position; Music does not, so carry it on for the same track.
        let position = (info["Playback Position"] as? NSNumber)?.doubleValue
            ?? (previous?.trackID == trackID ? previous!.position(at: now) : 0)
        return NowPlaying(player: player, title: title, artist: artist, album: album,
                          duration: durationMS / 1000, position: position,
                          isPlaying: state == "playing", fetchedAt: now, trackID: trackID)
    }

    // MARK: AppleScript (island open)

    private func runningPlayers() -> [Player] {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return [Player.spotify, .music].filter { running.contains($0.rawValue) }
    }

    func refresh(prompt: Bool = true) async {
        let running = runningPlayers()
        for player in [Player.spotify, .music] where !running.contains(player) { states[player] = nil }
        for player in running {
            guard await ensurePermission(player, prompt: prompt) else { continue }
            switch await Self.read(player) {
            case .playing(let track):
                states[player] = track
                lastError[player] = nil
            case .stopped:
                states[player] = nil
                lastError[player] = nil
            case .denied(let error):
                deniedPlayers.insert(player)
                lastError[player] = error
            case .failed(let error):
                lastError[player] = error // keep what the broadcasts said
            }
        }
        publish()
    }

    /// One place decides what is "now playing", from whichever source spoke last.
    /// `announce`: the change came from the player itself (a real track change), so the
    /// live activity may show a bubble. Polls and launch reads never announce.
    private func publish(announce: Bool = false) {
        let candidates = [Player.spotify, .music].compactMap { states[$0] }
        let current = candidates.first(where: \.isPlaying)
            ?? candidates.first(where: { $0.player == nowPlaying?.player })
            ?? candidates.first
        let startedNewTrack = announce && (current.map { $0.isPlaying && $0.trackID != nowPlaying?.trackID } ?? false)
        if let current {
            if !current.continues(nowPlaying) { nowPlaying = current }
        } else if nowPlaying != nil {
            nowPlaying = nil
        }
        guard let current else {
            artwork = nil
            lyrics = []
            artworkTrack = nil
            lyricsTrack = nil
            return
        }
        if artworkTrack != current.trackID { loadArtwork(for: current) }
        // Lyrics are only fetched when they can be shown (island open).
        if active, lyricsTrack != current.trackID { loadLyrics(for: current) }
        if startedNewTrack { onTrackStart(current) }
    }

    private enum ReadResult { case playing(NowPlaying), stopped, denied(String), failed(String) }

    private static func read(_ player: Player) async -> ReadResult {
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
        let result = await AppleScript.run(AppleScript.ifRunning(player.rawValue, source))
        if let error = result.error {
            MusicLog.log.error("\(player.name, privacy: .public) script failed: \(error, privacy: .public)")
            return error.hasPrefix("-1743") ? .denied(error) : .failed(error)
        }
        let values = result.values
        guard case .text(let rawState)? = values.first else { return .failed("unexpected answer") }
        // Spotify can report its state as a raw constant (kPSP = playing, kPSp = paused).
        let state = rawState.lowercased()
        let playing = state == "playing" || rawState.contains("kPSP")
        if state == "stopped" || rawState.contains("kPSS") { return .stopped }
        guard values.count >= 7 else { return .failed("unexpected answer (\(values.count) values)") }
        let id = values[6].string
        let normalizedID: String
        switch player {
        case .spotify: normalizedID = id
        case .music: normalizedID = UInt64(id, radix: 16).map { String($0, radix: 16) } ?? id.lowercased()
        }
        return .playing(NowPlaying(player: player,
                                   title: values[1].string, artist: values[2].string, album: values[3].string,
                                   duration: values[4].number, position: values[5].number,
                                   isPlaying: playing, fetchedAt: Date(),
                                   trackID: player.rawValue + ":" + normalizedID))
    }

    // MARK: Artwork

    private func loadArtwork(for track: NowPlaying) {
        artworkTrack = track.trackID
        artwork = nil
        Task {
            // Never prompt from here: the prompt belongs to the first time the island opens.
            guard await AppleScript.automationPermission(for: track.player.rawValue, ask: false) == noErr else {
                if artworkTrack == track.trackID { artworkTrack = nil } // try again once allowed
                return
            }
            var image: NSImage?
            switch track.player {
            case .music:
                let values = await AppleScript.run(AppleScript.ifRunning(Player.music.rawValue, """
                tell application id "com.apple.Music"
                    try
                        return {raw data of artwork 1 of current track}
                    end try
                end tell
                """))
                if case .data(let data)? = values.values.first { image = NSImage(data: data) }
            case .spotify:
                // Off by default: fetching the cover is a request to Spotify's servers.
                guard settings.spotifyCovers else { break }
                let values = await AppleScript.run(AppleScript.ifRunning(Player.spotify.rawValue,
                    "tell application id \"com.spotify.client\" to return {artwork url of current track}"))
                // Only Spotify's own image server, over HTTPS.
                if let url = URL(string: values.values.first?.string ?? ""), url.scheme == "https",
                   let host = url.host, host == "scdn.co" || host.hasSuffix(".scdn.co"),
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
        lyricsFailedTrack = nil
        lyrics = []
        Task {
            let lines = await LyricsStore.lyrics(title: track.title, artist: track.artist,
                                                 album: track.album, duration: track.duration)
            guard lyricsTrack == track.trackID else { return }
            if let lines {
                lyrics = lines
            } else {
                lyricsFailedTrack = track.trackID // offline: retried next time the island opens
            }
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

    /// Wraps a script so it does nothing if the player is not running:
    /// AppleScript would otherwise launch it.
    static func ifRunning(_ bundleID: String, _ body: String) -> String {
        """
        if application id "\(bundleID)" is running then
        \(body)
        end if
        """
    }

    struct ScriptResult: Sendable {
        var values: [ScriptValue]
        var error: String?
    }

    static func run(_ source: String) async -> ScriptResult {
        await withCheckedContinuation { continuation in
            queue.async {
                var errorInfo: NSDictionary?
                guard let script = NSAppleScript(source: source) else {
                    continuation.resume(returning: ScriptResult(values: [], error: "could not create script"))
                    return
                }
                let output = script.executeAndReturnError(&errorInfo)
                if let errorInfo {
                    let number = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                    let message = errorInfo[NSAppleScript.errorMessage] as? String ?? ""
                    continuation.resume(returning: ScriptResult(values: [], error: "\(number) \(message)"))
                } else {
                    continuation.resume(returning: ScriptResult(values: values(output), error: nil))
                }
            }
        }
    }

    /// Asks for the Automation permission if macOS has not asked yet (`ask`),
    /// or only reports the current answer.
    static func automationPermission(for bundleID: String, ask: Bool) async -> OSStatus {
        await withCheckedContinuation { continuation in
            queue.async {
                let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                // A concrete event ("get data"): with wildcards macOS never shows the dialog
                // and answers -1744, which looked like "allowed" while every command failed.
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, code("core"), code("getd"), ask)
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

    /// Deletes every cached lyric file. Returns how many were removed.
    @discardableResult
    static func clearCache() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
        return files.count
    }

    static func cachedCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path))?.count ?? 0
    }

    private static var cacheDir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("local.notch.island/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// nil on network error (not cached, so it can be retried).
    static func lyrics(title: String, artist: String, album: String, duration: Double) async -> [LyricLine]? {
        let key = SHA256.hash(data: Data("\(artist)\n\(title)\n\(Int(duration.rounded()))".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let file = cacheDir.appendingPathComponent(key + ".lrc")
        if let cached = try? String(contentsOf: file, encoding: .utf8) {
            return parse(cached) // an empty file means "no synced lyrics"
        }
        guard let lrc = await fetch(title: title, artist: artist, album: album, duration: duration) else {
            return nil // network error: do not cache, try again next time
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

/// Carries a value the compiler cannot prove Sendable (a notification's userInfo,
/// read once on the main queue) into a main-actor closure.
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Listens to the players' broadcasts with immediate delivery (an accessory app is
/// rarely active, and by default distributed notifications wait for activation).
final class BroadcastListener: NSObject {
    static let spotify = "com.spotify.client.PlaybackStateChanged"
    static let music = "com.apple.Music.playerInfo"

    private let handler: @MainActor (String, [AnyHashable: Any]) -> Void

    init(handler: @escaping @MainActor (String, [AnyHashable: Any]) -> Void) {
        self.handler = handler
        super.init()
        let center = DistributedNotificationCenter.default()
        for name in [Self.spotify, Self.music] {
            center.addObserver(self, selector: #selector(received(_:)), name: Notification.Name(name),
                               object: nil, suspensionBehavior: .deliverImmediately)
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func received(_ note: Notification) {
        let name = note.name.rawValue
        let info = UncheckedBox(note.userInfo ?? [:])
        let handler = handler
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler(name, info.value) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(name, info.value) } }
        }
    }
}
