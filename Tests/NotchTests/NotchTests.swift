import XCTest
@testable import Notch

final class LyricsTests: XCTestCase {
    func testParsesTimedLinesInOrder() {
        let lrc = """
        [ar:Nova Lane]
        [00:12.50]Lights on the water, one by one
        [00:17.00][01:02.25]We stay till the morning's done
        [00:05.00]
        """
        let lines = LyricsStore.parse(lrc)
        XCTAssertEqual(lines.map(\.time), [5.0, 12.5, 17.0, 62.25])
        XCTAssertEqual(lines[1].text, "Lights on the water, one by one")
        XCTAssertEqual(lines[2].text, lines[3].text)
        XCTAssertEqual(lines[0].text, "")
    }

    func testIgnoresTextWithoutTimestamps() {
        XCTAssertTrue(LyricsStore.parse("plain text only\n[ti:Low Tide]").isEmpty)
    }
}

final class PlayerBroadcastTests: XCTestCase {
    func testSpotifyBroadcast() throws {
        let info: [AnyHashable: Any] = ["Player State": "Playing", "Name": "Low Tide", "Artist": "Nova Lane",
                                        "Album": "Shore", "Track ID": "spotify:track:abc",
                                        "Duration": NSNumber(value: 215_000), "Playback Position": NSNumber(value: 12.5)]
        let track = try XCTUnwrap(MusicService.track(from: info, player: .spotify, previous: nil))
        XCTAssertTrue(track.isPlaying)
        XCTAssertEqual(track.title, "Low Tide")
        XCTAssertEqual(track.duration, 215, accuracy: 0.001)
        XCTAssertEqual(track.position, 12.5, accuracy: 0.001)
        XCTAssertEqual(track.trackID, "com.spotify.client:spotify:track:abc")
    }

    func testMusicBroadcastKeepsPositionForSameTrack() throws {
        let info: [AnyHashable: Any] = ["Player State": "Paused", "Name": "Song", "Artist": "A",
                                        "PersistentID": NSNumber(value: Int64(-2)), "Total Time": NSNumber(value: 180_000)]
        let first = try XCTUnwrap(MusicService.track(from: info, player: .music, previous: nil))
        XCTAssertFalse(first.isPlaying)
        XCTAssertEqual(first.trackID, "com.apple.Music:fffffffffffffffe")
        var moved = first
        moved.position = 42
        let second = try XCTUnwrap(MusicService.track(from: info, player: .music, previous: moved))
        XCTAssertEqual(second.position, 42, accuracy: 0.001)
    }

    func testStoppedMeansNothingPlaying() {
        XCTAssertNil(MusicService.track(from: ["Player State": "Stopped"], player: .spotify, previous: nil))
    }
}

final class WeatherTests: XCTestCase {
    func testSymbols() {
        func symbol(_ code: Int, day: Bool = true) -> String {
            WeatherNow(city: "", temperature: 0, high: 0, low: 0, code: code, isDay: day).symbol
        }
        XCTAssertEqual(symbol(0), "sun.max.fill")
        XCTAssertEqual(symbol(0, day: false), "moon.stars.fill")
        XCTAssertEqual(symbol(61), "cloud.rain.fill")
        XCTAssertEqual(symbol(65), "cloud.heavyrain.fill")
        XCTAssertEqual(symbol(73), "cloud.snow.fill")
        XCTAssertEqual(symbol(95), "cloud.bolt.rain.fill")
    }
}

final class IslandModelTests: XCTestCase {
    @MainActor
    func testStatesAndSizes() {
        let model = IslandModel(geometry: .fallback)
        let notch = NotchGeometry.fallback.notchSize
        XCTAssertEqual(model.state, .resting)
        XCTAssertEqual(model.size, notch)

        model.compactActive = true
        XCTAssertEqual(model.state, .compact)
        // The pill lives in its own click-through window; the island stays notch-sized.
        XCTAssertEqual(model.size, notch)
        model.compactSide = Layout.musicSide
        XCTAssertEqual(model.pillSize.width, notch.width + 2 * (Layout.musicSide + Layout.pillEar))

        model.showPeek(Peek(symbol: "bolt.fill", title: "Charging"), seconds: 10)
        XCTAssertEqual(model.state, .peek)

        model.expand(pin: true)
        XCTAssertEqual(model.state, .expanded)

        model.collapse()
        XCTAssertEqual(model.state, .peek)
    }

    @MainActor
    func testExpandedSizeMatchesReference() {
        // Reference screenshot: 680 pt wide body, 168 pt below the notch with lyrics.
        let model = IslandModel(geometry: .fallback)
        model.showsLyrics = true
        model.expand(pin: true)
        XCTAssertEqual(model.size.width, 680 + 2 * Layout.maxEar)
        XCTAssertEqual(model.size.height, NotchGeometry.fallback.notchSize.height + 168)
        model.showsLyrics = false
        XCTAssertEqual(model.size.height, NotchGeometry.fallback.notchSize.height + 132)
    }

    @MainActor
    func testHoverZoneReachesTheTopEdge() {
        let model = IslandModel(geometry: .fallback)
        let f = NotchGeometry.fallback.screenFrame
        XCTAssertTrue(model.hotRect.contains(CGPoint(x: f.midX, y: f.maxY)))
        XCTAssertTrue(model.hotRect.contains(CGPoint(x: f.midX, y: f.maxY - 5)))
        XCTAssertFalse(model.hotRect.contains(CGPoint(x: f.midX + 200, y: f.maxY - 5)))
    }
}
