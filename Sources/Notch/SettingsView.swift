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

    func show() {
        if window == nil {
            let controller = NSHostingController(rootView: makeContent())
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
                Text("Temperatures in \(WeatherService.usesFahrenheit ? "°F" : "°C"), from your region settings.")
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

    var body: some View {
        Form {
            Section("Players") {
                ForEach([Player.spotify, .music], id: \.self) { player in
                    HStack {
                        Text(player.name)
                        Spacer()
                        if music.deniedPlayers.contains(player) {
                            Text("Control not allowed").foregroundStyle(.orange)
                        } else {
                            Text("Detected automatically").foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Open Automation Settings…") { music.openAutomationSettings() }
                Text("Notch never opens a player by itself. Play/pause/next and the lyrics position need the Automation permission, asked the first time you open the island while a player runs.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Show Spotify covers", isOn: $settings.spotifyCovers)
            } footer: {
                Text("Spotify only gives a link to the cover, so showing it means a request to Spotify's image server. Apple Music covers come from the app itself.")
            }
        }
        .formStyle(.grouped)
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
