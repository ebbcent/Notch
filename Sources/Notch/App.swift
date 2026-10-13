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

        installMainMenu()
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

    /// Never visible for a menu bar app, but it is what makes ⌘C/⌘V/⌘A/⌘Z and ⌘W work
    /// in the Settings window.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
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
