import AppKit
import ServiceManagement
import SwiftUI

@main
enum NotchApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
        withExtendedLifetime(delegate) { app.run() } // NSApplication holds its delegate weakly
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var island: IslandController!
    private var music: MusicService!
    private var weather: WeatherService!
    private var calendar: CalendarService!
    private var timer: FocusTimer!
    private var peeks: PeekCenter!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy at a time.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != NSRunningApplication.current }
        if !others.isEmpty {
            NSApp.terminate(nil)
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch")
        statusItem.button?.toolTip = "Notch"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        music = MusicService(settings: settings)
        weather = WeatherService(settings: settings)
        calendar = CalendarService()
        timer = FocusTimer()
        island = IslandController(settings: settings, music: music, weather: weather,
                                  calendar: calendar, timer: timer)
        peeks = PeekCenter(model: island.model, settings: settings)
        timer.onFinish = { [weak self] in
            self?.island.model.showPeek(Peek(symbol: "timer", title: "Focus done", subtitle: "25 min"), seconds: 4)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(header("Tiles"))
        let tiles = NSMenuItem()
        let editor = NSHostingView(rootView: TilesEditor(settings: settings))
        editor.frame.size = editor.fittingSize
        tiles.view = editor
        menu.addItem(tiles)

        let cityTitle = settings.city.isEmpty ? "Weather City…" : "Weather City: \(settings.city)…"
        menu.addItem(item(cityTitle, #selector(askCity)))
        menu.addItem(item("Spotify Covers (asks Spotify's servers)", #selector(toggleCovers),
                          on: settings.spotifyCovers))
        menu.addItem(item("Live Activity (music, timer)", #selector(toggleLiveActivity), on: settings.liveActivity))
        menu.addItem(item("Do Not Disturb Bubbles" + (settings.focusPeeks ? "" : FocusAccess.menuNote),
                          #selector(toggleFocusPeeks), on: settings.focusPeeks))

        menu.addItem(.separator())
        menu.addItem(header("Theme"))
        for kind in ThemeKind.allCases {
            let i = item(kind.title, #selector(pickTheme(_:)), on: settings.theme == kind)
            i.representedObject = kind.rawValue
            menu.addItem(i)
        }

        menu.addItem(.separator())
        menu.addItem(item("Launch at Login", #selector(toggleLoginItem),
                          on: SMAppService.mainApp.status == .enabled))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let about = NSMenuItem(title: "Notch \(version)", action: nil, keyEquivalent: "")
        about.isEnabled = false
        menu.addItem(about)
        let quit = NSMenuItem(title: "Quit Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func header(_ title: String) -> NSMenuItem {
        NSMenuItem.sectionHeader(title: title)
    }

    private func item(_ title: String, _ action: Selector, on: Bool? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        if let on { i.state = on ? .on : .off }
        return i
    }

    // MARK: Actions

    @objc private func pickTheme(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let kind = ThemeKind(rawValue: raw) {
            settings.theme = kind
        }
    }

    @objc private func askCity() {
        let alert = NSAlert()
        alert.messageText = "Weather city"
        alert.informativeText = "Only this name and its coordinates are sent to Open-Meteo."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = settings.city
        field.placeholderString = "Lisbon"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn {
            settings.city = field.stringValue.trimmingCharacters(in: .whitespaces)
        }
    }

    @objc private func toggleCovers() {
        settings.spotifyCovers.toggle()
    }

    @objc private func toggleLiveActivity() {
        settings.liveActivity.toggle()
    }

    @objc private func toggleFocusPeeks() {
        peeks.setFocusPeeks(!settings.focusPeeks)
    }

    @objc private func toggleLoginItem() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Launch at login could not be changed"
            alert.informativeText = "\(error.localizedDescription)\n\nMove Notch to /Applications and try again."
            NSApp.activate()
            alert.runModal()
        }
    }
}
