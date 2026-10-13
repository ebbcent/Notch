import AppKit
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
    private lazy var settingsWindow = SettingsWindow { [unowned self] in
        AnyView(SettingsView(settings: self.settings, music: self.music, weather: self.weather,
                             setFocusPeeks: { [unowned self] on in self.peeks.setFocusPeeks(on) }))
    }

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
        // First launch: show the settings once (city, tiles, launch at login).
        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            settingsWindow.show()
        }
        timer.onFinish = { [weak self] in
            self?.island.model.showPeek(Peek(symbol: "timer", title: "Focus done", subtitle: "25 min"), seconds: 4)
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = item("Open Island", #selector(openIsland))
        menu.addItem(open)
        menu.addItem(.separator())

        menu.addItem(item("Live Activity", #selector(toggleLiveActivity), on: settings.liveActivity))
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for kind in ThemeKind.allCases {
            let i = item(kind.title, #selector(pickTheme(_:)), on: settings.theme == kind)
            i.representedObject = kind.rawValue
            themeMenu.addItem(i)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        menu.addItem(.separator())
        let settingsItem = item("Settings…", #selector(showSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
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

    @objc private func openIsland() {
        island.model.expand(pin: true)
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func toggleLiveActivity() {
        settings.liveActivity.toggle()
    }

}
