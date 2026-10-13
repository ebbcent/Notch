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

final class ClaudeTextTests: XCTestCase {
    func testActivities() {
        XCTAssertEqual(ClaudeService.activity(tool: "Read", input: ["file_path": "/a/b/Main.swift"]),
                       ClaudeActivity(symbol: "doc.text", verb: "Reading", detail: "Main.swift"))
        XCTAssertEqual(ClaudeService.activity(tool: "Bash", input: ["command": "make\nmake test"]).detail, "make")
        XCTAssertEqual(ClaudeService.activity(tool: "Grep", input: ["pattern": "TODO"]).verb, "Searching")
        XCTAssertEqual(ClaudeService.activity(tool: "Edit", input: [:]).verb, "Editing")
    }

    func testPermissionBodyIsNeverShortened() {
        let long = String(repeating: "echo x && ", count: 500) + "echo end"
        let body = ClaudeService.permissionBody(tool: "Bash", input: ["command": long])
        XCTAssertTrue(body.hasSuffix("echo end"))
        XCTAssertTrue(body.contains(long))
        let other = ClaudeService.permissionBody(tool: "Write", input: ["file_path": "/tmp/a", "content": long])
        XCTAssertTrue(other.contains("echo end"))
    }

    func testDurations() {
        XCTAssertEqual(ClaudeService.duration(42), "42 s")
        XCTAssertEqual(ClaudeService.duration(134), "2 min 14 s")
        XCTAssertEqual(ClaudeService.duration(3720), "1 h 02 min")
    }

    func testSettingsSnippetIsValidJSON() throws {
        let json = "{" + ClaudeService.settingsSnippet + "}"
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let hooks = try XCTUnwrap(object?["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), ["UserPromptSubmit", "PreToolUse", "PermissionRequest", "Notification", "Stop"])
    }

    func testDecisionOutput() throws {
        let allow = try XCTUnwrap(HookClient.decision(for: "allow"))
        XCTAssertEqual(String(decoding: allow, as: UTF8.self),
                       #"{"hookSpecificOutput":{"decision":{"behavior":"allow"},"hookEventName":"PermissionRequest"}}"#)
        let deny = try XCTUnwrap(HookClient.decision(for: "deny"))
        XCTAssertTrue(String(decoding: deny, as: UTF8.self).contains(#""behavior":"deny""#))
        XCTAssertNil(HookClient.decision(for: ""))
    }
}

final class HookSocketTests: XCTestCase {
    private func tempSocketPath() -> String {
        "/tmp/notch-test-\(UUID().uuidString.prefix(8))/notch.sock"
    }

    func testAddressRejectsTooLongPaths() {
        XCTAssertNotNil(HookSocket.address("/tmp/a.sock"))
        XCTAssertNil(HookSocket.address("/tmp/" + String(repeating: "x", count: 200)))
    }

    func testClientDoesNothingWhenAppIsNotRunning() {
        let input = Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash"}"#.utf8)
        XCTAssertNil(HookClient.forward(input, to: tempSocketPath(), timeout: 1))
    }

    func testPermissionRoundTrip() throws {
        let path = tempSocketPath()
        let received = expectation(description: "request reaches the app")
        let server = HookServer { json, connection in
            XCTAssertEqual(json["tool_name"] as? String, "Bash")
            connection.reply("allow")
            received.fulfill()
        }
        XCTAssertTrue(server.start(path: path))
        defer { server.stop() }

        var info = stat()
        XCTAssertEqual(stat(path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600, "only the user may talk to the app")

        let input = Data(#"{"hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"ls"}}"#.utf8)
        final class Box: @unchecked Sendable { var data: Data? }
        let output = Box()
        let done = expectation(description: "hook returns")
        Thread.detachNewThread {
            output.data = HookClient.forward(input, to: path, timeout: 5)
            done.fulfill()
        }
        wait(for: [received, done], timeout: 10)
        let text = String(decoding: try XCTUnwrap(output.data), as: UTF8.self)
        XCTAssertTrue(text.contains(#""behavior":"allow""#))
    }

    func testFireAndForgetEventsReturnImmediately() {
        let path = tempSocketPath()
        let received = expectation(description: "event reaches the app")
        let server = HookServer { json, connection in
            XCTAssertEqual(json["hook_event_name"] as? String, "Stop")
            connection.close()
            received.fulfill()
        }
        XCTAssertTrue(server.start(path: path))
        defer { server.stop() }
        let input = Data(#"{"hook_event_name":"Stop"}"#.utf8)
        XCTAssertNil(HookClient.forward(input, to: path))
        wait(for: [received], timeout: 5)
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
        XCTAssertGreaterThan(model.size.width, notch.width)

        model.showPeek(Peek(symbol: "bolt.fill", title: "Charging"), seconds: 10)
        XCTAssertEqual(model.state, .peek)

        model.cardHeight = 200
        XCTAssertEqual(model.state, .expanded)
        XCTAssertEqual(model.size.height, notch.height + 200)

        model.cardHeight = nil
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
