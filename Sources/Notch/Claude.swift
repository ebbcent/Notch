import AppKit

/// What Claude Code is doing, from its hooks.
struct ClaudeActivity: Equatable {
    var symbol: String
    var verb: String
    var detail: String
}

struct PermissionRequest: Identifiable {
    let id = UUID()
    let tool: String
    let title: String
    /// Everything that will run or change, untruncated.
    let body: String
    let project: String
    let connection: HookConnection
}

@MainActor
final class ClaudeService: ObservableObject {
    @Published private(set) var isWorking = false
    @Published private(set) var activity: ClaudeActivity?
    @Published private(set) var requests: [PermissionRequest] = []
    @Published private(set) var listening = false
    @Published private(set) var shortcutsAvailable = true

    var current: PermissionRequest? { requests.first }

    /// Shows a bubble (wired to the island).
    var onPeek: (Peek) -> Void = { _ in }

    private var server: HookServer?
    private let hotKeys = HotKeys()
    private var startedAt: Date?
    private var lastEvent = Date()
    private var watchdog: Task<Void, Never>?

    func start() {
        let server = HookServer { [weak self] json, connection in
            MainActor.assumeIsolated { self?.handle(json, connection) }
        }
        listening = server.start()
        self.server = server
    }

    func stop() {
        requests.forEach { $0.connection.close() }
        requests.removeAll()
        server?.stop()
    }

    // MARK: Events

    private func handle(_ json: [String: Any], _ connection: HookConnection) {
        let event = json["hook_event_name"] as? String ?? ""
        lastEvent = Date()
        switch event {
        case "UserPromptSubmit":
            connection.close()
            startedAt = Date()
            setWorking(ClaudeActivity(symbol: "sparkle", verb: "Thinking", detail: ""))
        case "PreToolUse":
            connection.close()
            if startedAt == nil { startedAt = Date() }
            setWorking(Self.activity(tool: json["tool_name"] as? String ?? "",
                                     input: json["tool_input"] as? [String: Any] ?? [:]))
        case "PermissionRequest":
            enqueue(json, connection)
        case "Notification":
            connection.close()
            let type = json["notification_type"] as? String ?? ""
            // Permission prompts are already shown by PermissionRequest.
            if type != "permission_prompt" {
                let message = json["message"] as? String ?? "Claude Code needs you"
                onPeek(Peek(symbol: "bell.fill", title: "Claude Code", subtitle: message))
            }
        case "Stop":
            connection.close()
            finish()
        default:
            connection.close()
        }
    }

    private func setWorking(_ activity: ClaudeActivity) {
        self.activity = activity
        if !isWorking { isWorking = true }
        armWatchdog()
    }

    private func finish() {
        let elapsed = startedAt.map { Date().timeIntervalSince($0) }
        startedAt = nil
        isWorking = false
        activity = nil
        watchdog?.cancel()
        onPeek(Peek(symbol: "checkmark.circle.fill", title: "Done",
                    subtitle: elapsed.map(Self.duration)))
    }

    /// If Claude Code is closed mid-task no Stop arrives: go back to rest after 10 quiet minutes.
    private func armWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(600))
            guard let self, !Task.isCancelled, self.requests.isEmpty else { return }
            self.isWorking = false
            self.activity = nil
            self.startedAt = nil
        }
    }

    // MARK: Permission requests

    private func enqueue(_ json: [String: Any], _ connection: HookConnection) {
        let tool = json["tool_name"] as? String ?? "Tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]
        let project = (json["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        let request = PermissionRequest(tool: tool, title: Self.permissionTitle(tool),
                                        body: Self.permissionBody(tool: tool, input: input),
                                        project: project, connection: connection)
        requests.append(request)
        if requests.count == 1 { showCurrent() }

        // The hook gives up after `answerTimeout`; drop the request then too.
        let id = request.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(HookSocket.answerTimeout))
            self?.answer(id, with: nil)
        }
    }

    /// `true` allow, `false` deny, `nil` hand back to Claude Code's own prompt.
    func answer(_ id: UUID? = nil, with allow: Bool?) {
        guard let index = requests.firstIndex(where: { $0.id == (id ?? requests.first?.id) }) else { return }
        let request = requests.remove(at: index)
        switch allow {
        case true?: request.connection.reply("allow")
        case false?: request.connection.reply("deny")
        case nil: request.connection.close()
        }
        if index == 0 { showCurrent() }
    }

    private func showCurrent() {
        currentFullySeen = false
        hotKeys.unregisterAll()
        guard current != nil else { return }
        let a = hotKeys.register(HotKeys.allow) { [weak self] in self?.allowFromShortcut() }
        let d = hotKeys.register(HotKeys.deny) { [weak self] in self?.answer(with: false) }
        shortcutsAvailable = a && d
    }

    /// Set by the card once the whole request has been on screen.
    @Published var currentFullySeen = false

    private func allowFromShortcut() {
        guard currentFullySeen else {
            NSSound.beep() // scroll through the whole command first
            return
        }
        answer(with: true)
    }

    // MARK: Text

    nonisolated static func activity(tool: String, input: [String: Any]) -> ClaudeActivity {
        let file = (input["file_path"] as? String ?? input["notebook_path"] as? String)
            .map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        switch tool {
        case "Read", "NotebookRead":
            return ClaudeActivity(symbol: "doc.text", verb: "Reading", detail: file)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            return ClaudeActivity(symbol: "pencil", verb: "Editing", detail: file)
        case "Bash", "BashOutput", "KillShell":
            let command = (input["command"] as? String ?? "").split(separator: "\n").first.map(String.init) ?? ""
            return ClaudeActivity(symbol: "terminal", verb: "Running", detail: command)
        case "Grep", "Glob", "LS", "WebSearch", "ToolSearch":
            let pattern = input["pattern"] as? String ?? input["query"] as? String ?? ""
            return ClaudeActivity(symbol: "magnifyingglass", verb: "Searching", detail: pattern)
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host } ?? ""
            return ClaudeActivity(symbol: "globe", verb: "Fetching", detail: host)
        case "Task", "Agent":
            return ClaudeActivity(symbol: "person.2", verb: "Delegating", detail: input["description"] as? String ?? "")
        case "TodoWrite":
            return ClaudeActivity(symbol: "checklist", verb: "Planning", detail: "")
        default:
            return ClaudeActivity(symbol: "sparkle", verb: "Working", detail: tool)
        }
    }

    nonisolated static func permissionTitle(_ tool: String) -> String {
        switch tool {
        case "Bash": return "Claude Code wants to run a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Claude Code wants to change a file"
        case "WebFetch": return "Claude Code wants to fetch a web page"
        default: return "Claude Code wants to use \(tool)"
        }
    }

    /// The full request, never shortened: the command for Bash, otherwise every input field.
    nonisolated static func permissionBody(tool: String, input: [String: Any]) -> String {
        if tool == "Bash", let command = input["command"] as? String {
            if let description = input["description"] as? String, !description.isEmpty {
                return "# " + description + "\n" + command
            }
            return command
        }
        guard let data = try? JSONSerialization.data(withJSONObject: input,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return String(describing: input) }
        return text
    }

    nonisolated static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(String(format: "%02d", s % 60)) s" }
        return "\(s / 3600) h \(String(format: "%02d", (s % 3600) / 60)) min"
    }

    // MARK: Setup text for the user

    nonisolated static var hookScriptPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/notch-hook.sh").path
    }

    nonisolated static var settingsSnippet: String {
        let command = hookScriptPath
        func entry(_ timeout: Int, matcher: Bool) -> String {
            let m = matcher ? "\"matcher\": \"*\", " : ""
            return "[{ \(m)\"hooks\": [{ \"type\": \"command\", \"command\": \"\(command)\", \"timeout\": \(timeout) }] }]"
        }
        return """
        "hooks": {
          "UserPromptSubmit": \(entry(5, matcher: false)),
          "PreToolUse": \(entry(5, matcher: true)),
          "PermissionRequest": \(entry(Int(HookSocket.answerTimeout) + 10, matcher: true)),
          "Notification": \(entry(5, matcher: false)),
          "Stop": \(entry(5, matcher: false))
        }
        """
    }
}
