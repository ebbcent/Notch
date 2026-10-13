import AppKit

@main
enum NotchApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // no Dock icon
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var island: IslandController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Notch")
        menu.delegate = self
        statusItem.menu = menu
        island = IslandController(settings: settings)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu()
        for kind in ThemeKind.allCases {
            let item = NSMenuItem(title: kind.title, action: #selector(pickTheme(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.state = settings.theme == kind ? .on : .off
            themeMenu.addItem(item)
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Temporary, to try each state by hand.
        let testItem = NSMenuItem(title: "Test", action: nil, keyEquivalent: "")
        let testMenu = NSMenu()
        addItem(to: testMenu, "Compact pill on/off", #selector(testCompact))
        addItem(to: testMenu, "Show a peek", #selector(testPeek))
        addItem(to: testMenu, "Open the island (pinned)", #selector(testExpand))
        addItem(to: testMenu, "Close the island", #selector(testCollapse))
        testItem.submenu = testMenu
        menu.addItem(testItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func testCompact() { island.model.compactActive.toggle() }
    @objc private func testPeek() {
        island.model.showPeek(Peek(symbol: "bolt.fill", title: "Charging", subtitle: "82%"))
    }
    @objc private func testExpand() { island.model.expand(pin: true) }
    @objc private func testCollapse() { island.model.collapse() }

    @objc private func pickTheme(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let kind = ThemeKind(rawValue: raw) {
            settings.theme = kind
        }
    }
}
