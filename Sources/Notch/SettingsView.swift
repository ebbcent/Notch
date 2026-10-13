import AppKit
import ServiceManagement
import SwiftUI

/// The Settings window (⌘, from the menu bar item).
@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let makeContent: () -> AnyView

    init(content: @escaping () -> AnyView) {
        makeContent = content
    }

    private var controller: NSHostingController<AnyView>?

    func show() {
        if let controller {
            // Fresh state each time (login item status, cache size may have changed).
            controller.rootView = AnyView(makeContent().id(UUID()))
        } else {
            let controller = NSHostingController(rootView: AnyView(makeContent().id(UUID())))
            self.controller = controller
            let window = NSWindow(contentViewController: controller)
            window.title = "Notch Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 480, height: 460))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless() // also when Notch was launched in the background
    }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @ObservedObject var music: MusicService
    @ObservedObject var weather: WeatherService
    /// Turns the Focus bubbles on (asks for the permission) or off.
    let setFocusPeeks: (Bool) -> Void

    var body: some View {
        TabView {
            GeneralPane(settings: settings, setFocusPeeks: setFocusPeeks)
                .tabItem { Label("General", systemImage: "gearshape") }
            TilesPane(settings: settings, weather: weather)
                .tabItem { Label("Tiles", systemImage: "square.grid.2x2") }
            MusicPane(settings: settings, music: music)
                .tabItem { Label("Music", systemImage: "music.note") }
            PrivacyPane()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 480, height: 460)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings: Settings
    let setFocusPeeks: (Bool) -> Void
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { loginStatus == .enabled }, set: setLogin))
                if loginStatus == .requiresApproval {
                    note("Allow Notch in System Settings › General › Login Items.") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
                if let loginError { Text(loginError).foregroundStyle(.red).font(.callout) }
            }
            Section("Appearance") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(ThemeKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle("Live activity", isOn: $settings.liveActivity)
                Text("While music plays, the pill beside the notch shows the cover and title, and a bubble shows each new track. The focus timer takes the pill while it runs.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Do Not Disturb bubbles", isOn: Binding(get: { settings.focusPeeks }, set: setFocusPeeks))
                Text("Needs the Focus permission. macOS only says whether a Focus is on, not which one.")
                    .font(.callout).foregroundStyle(.secondary)
            } header: {
                Text("Bubbles and live activity")
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private func setLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        do {
            if on { try service.register() } else { try service.unregister() }
            loginError = nil
        } catch {
            loginError = "\(error.localizedDescription) Move Notch to /Applications and try again."
        }
        loginStatus = service.status
    }
}

// MARK: - Tiles

private struct TilesPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var weather: WeatherService
    @State private var city = ""

    var body: some View {
        Form {
            Section {
                TilesEditor(settings: settings)
                    .padding(.leading, -20)
            } header: {
                Text("Tiles")
            } footer: {
                Text("Tick to show, arrows to reorder. Click a tile in the island to open its app.")
            }
            Section("Weather") {
                HStack {
                    TextField("City", text: $city, prompt: Text("Lisbon"))
                        .onSubmit { settings.city = city.trimmingCharacters(in: .whitespaces) }
                    Button("Save") { settings.city = city.trimmingCharacters(in: .whitespaces) }
                        .disabled(city.trimmingCharacters(in: .whitespaces) == settings.city)
                }
                weatherStatus
                Text("Temperatures in \(WeatherService.usesFahrenheit ? "°F" : "°C"), as set in System Settings › General › Language & Region.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { city = settings.city }
    }

    @ViewBuilder private var weatherStatus: some View {
        switch weather.status {
        case .ready(let now):
            Label("Found \(now.city): \(Int(now.temperature.rounded()))°", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .cityNotFound:
            Label("City not found", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .offline:
            Label("Weather unavailable (offline?)", systemImage: "wifi.slash").foregroundStyle(.secondary)
        case .loading:
            ProgressView().controlSize(.small)
        case .noCity:
            EmptyView()
        }
    }
}

// MARK: - Music

private struct MusicPane: View {
    @ObservedObject var settings: Settings
    @ObservedObject var music: MusicService
    @State private var working = false

    private func statusText(_ player: Player) -> String {
        guard let status = music.permissionStatus[player] else { return "–" }
        switch Int(status) {
        case 0: return "Allowed"
        case -1743: return "Refused"
        case -1744: return "Not asked yet"
        case -600: return "Not running"
        default: return "Error \(status)"
        }
    }

    private func statusColor(_ player: Player) -> Color {
        switch music.permissionStatus[player].map(Int.init) {
        case 0: return .green
        case -1743: return .orange
        default: return .secondary
        }
    }

    var body: some View {
        Form {
            Section {
                ForEach([Player.spotify, .music], id: \.self) { player in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(player.name)
                            Spacer()
                            Text(statusText(player)).foregroundStyle(statusColor(player))
                        }
                        if let error = music.lastError[player] {
                            Text("Last error: \(error)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                HStack {
                    Button(working ? "Asking…" : "Reset and Ask Again") {
                        working = true
                        Task {
                            await music.resetAutomationPermission()
                            await music.checkPermissions()
                            working = false
                        }
                    }
                    .disabled(working)
                    Spacer()
                    Button("Open Automation Settings…") { music.openAutomationSettings() }
                }
            } header: {
                Text("Control of the players")
            } footer: {
                Text("Detecting what plays needs no permission. Play/pause/next, the lyrics position and Music covers need macOS to let Notch control the player. If they do nothing, start the player, click Reset and Ask Again, and accept the dialog. Notch never opens a player by itself.")
            }
            Section {
                Toggle("Show Spotify covers", isOn: $settings.spotifyCovers)
            } footer: {
                Text("Spotify only gives a link to the cover, so showing it means a request to Spotify's image server. Apple Music covers come from the app itself.")
            }
        }
        .formStyle(.grouped)
        .task { await music.checkPermissions() }
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @State private var cached = LyricsStore.cachedCount()

    var body: some View {
        Form {
            Section("What leaves this Mac") {
                row("lrclib.net", "title, artist, album and length of a new track, for its lyrics")
                row("open-meteo.com", "the weather city name, then its coordinates")
                row("Spotify's image server", "only if Show Spotify covers is on")
                Text("Nothing else. No analytics, no accounts.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Stored on this Mac") {
                HStack {
                    Text("Lyrics cache: \(cached) song\(cached == 1 ? "" : "s")")
                    Spacer()
                    Button("Clear") {
                        LyricsStore.clearCache()
                        cached = LyricsStore.cachedCount()
                    }
                    .disabled(cached == 0)
                }
                Text("Settings are kept in the app's preferences; nothing else is saved.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
                LabeledContent("Notch", value: "Version \(version)")
            }
        }
        .formStyle(.grouped)
        .onAppear { cached = LyricsStore.cachedCount() }
    }

    private func row(_ host: String, _ what: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(host).font(.body.monospaced())
            Text(what).font(.callout).foregroundStyle(.secondary)
        }
    }
}

private func note(_ text: String, action: @escaping () -> Void) -> some View {
    HStack {
        Text(text).font(.callout).foregroundStyle(.secondary)
        Spacer()
        Button("Open…", action: action)
    }
}
