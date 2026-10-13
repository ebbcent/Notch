import AppKit
import ServiceManagement
import SwiftUI

@main
enum NotchApp {
    @MainActor
    static func main() {
        // Launched by a Claude Code hook: forward the event and exit, no UI.
        if CommandLine.arguments.contains("--hook") {
            exit(HookClient.run())
        }
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
    private var claude: ClaudeService!
    private var peeks: PeekCenter!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One copy at a time (the hook socket belongs to one app).
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
        claude = ClaudeService()
        island = IslandController(settings: settings, music: music, weather: weather,
                                  calendar: calendar, timer: timer, claude: claude)
        peeks = PeekCenter(model: island.model, settings: settings)
        claude.start()
        timer.onFinish = { [weak self] in
            self?.island.model.showPeek(Peek(symbol: "timer", title: "Focus done", subtitle: "25 min"), seconds: 4)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        claude?.stop() // hands any waiting request back to Claude Code
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
        let claudeItem = NSMenuItem(title: "Claude Code", action: nil, keyEquivalent: "")
        let claudeMenu = NSMenu()
        claudeMenu.autoenablesItems = false
        let status = NSMenuItem(title: claude.listening ? "Listening for hooks" : "Not listening (socket error)",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        claudeMenu.addItem(status)
        let keys = NSMenuItem(title: claude.shortcutsAvailable
                              ? "Allow \(HotKeys.allow.label) · Deny \(HotKeys.deny.label)"
                              : "Shortcuts taken by another app", action: nil, keyEquivalent: "")
        keys.isEnabled = false
        claudeMenu.addItem(keys)
        claudeMenu.addItem(.separator())
        claudeMenu.addItem(item("Copy Hook Settings", #selector(copyHookSettings)))
        claudeMenu.addItem(item("Setup Instructions…", #selector(showHookHelp)))
        claudeItem.submenu = claudeMenu
        menu.addItem(claudeItem)

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

    @objc private func toggleFocusPeeks() {
        peeks.setFocusPeeks(!settings.focusPeeks)
    }

    @objc private func copyHookSettings() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ClaudeService.settingsSnippet, forType: .string)
    }

    @objc private func showHookHelp() {
        let alert = NSAlert()
        alert.messageText = "Show Claude Code in the notch"
        alert.informativeText = """
        Add this "hooks" block to ~/.claude/settings.json (inside the top-level { }, \
        merged with any hooks you already have). "Copy Hook Settings" puts it on the clipboard.

        When Claude asks for a permission, the island opens with the whole request. \
        Allow works once you have seen all of it. If you do not answer within \
        \(Int(HookSocket.answerTimeout)) s, or choose "Ask in Terminal", Claude Code asks in its own window.
        """
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 260))
        text.string = ClaudeService.settingsSnippet
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.isEditable = false
        let scroll = NSScrollView(frame: text.frame)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Copy and Close")
        alert.addButton(withTitle: "Close")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { copyHookSettings() }
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
