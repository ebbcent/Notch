import AppKit
import IOKit.ps
import Intents

/// Watches the system and shows short bubbles under the notch.
@MainActor
final class PeekCenter {
    private let model: IslandModel
    private let settings: Settings
    private var observers: [NSObjectProtocol] = []

    // Power
    private var powerSource: CFRunLoopSource?
    private var wasOnAC: Bool?
    private var warned20 = false
    private var warned10 = false

    // Focus
    private var focusTask: Task<Void, Never>?
    private var wasFocused: Bool?

    init(model: IslandModel, settings: Settings) {
        self.model = model
        self.settings = settings
        watchApps()
        watchPower()
        if settings.focusPeeks && FocusAccess.status == .authorized { startFocusPolling() }
    }

    // MARK: Apps

    private func watchApps() {
        let center = NSWorkspace.shared.notificationCenter
        for (name, verb) in [(NSWorkspace.didLaunchApplicationNotification, "opened"),
                             (NSWorkspace.didTerminateApplicationNotification, "quit")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.activationPolicy == .regular,
                      app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
                let name = app.localizedName ?? "App"
                let icon = app.icon
                MainActor.assumeIsolated {
                    self?.model.showPeek(Peek(symbol: "app", icon: icon, title: name, subtitle: verb), seconds: 2.5)
                }
            })
        }
    }

    // MARK: Power (IOKit, no permission needed)

    private func watchPower() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let center = Unmanaged<PeekCenter>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { center.powerChanged() }
        }, context)?.takeRetainedValue() else { return }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerChanged(initial: true)
    }

    private func powerChanged(initial: Bool = false) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onAC = providing == kIOPMACPowerKey
        let level = Self.batteryLevel(info)

        if !initial, let wasOnAC, !wasOnAC, onAC {
            model.showPeek(Peek(symbol: "bolt.fill", title: "Charging", subtitle: level.map { "\($0)%" }), seconds: 3)
        }
        wasOnAC = onAC

        guard let level else { return } // no battery (desktop Mac)
        if onAC || level > 20 { warned20 = false }
        if onAC || level > 10 { warned10 = false }
        guard !onAC else { return }
        if level <= 10, !warned10 {
            warned10 = true
            warned20 = true
            model.showPeek(Peek(symbol: "battery.0percent", title: "Battery low", subtitle: "\(level)%"), seconds: 4)
        } else if level <= 20, !warned20 {
            warned20 = true
            model.showPeek(Peek(symbol: "battery.25percent", title: "Battery low", subtitle: "\(level)%"), seconds: 4)
        }
    }

    private static func batteryLevel(_ info: CFTypeRef) -> Int? {
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return Int((Double(current) / Double(max) * 100).rounded())
        }
        return nil
    }

    // MARK: Focus / Do Not Disturb

    /// macOS has no public Do Not Disturb API. INFocusStatusCenter only says whether
    /// *a* Focus (Do Not Disturb or any other) is on, and only with the Focus permission.
    func setFocusPeeks(_ on: Bool) {
        if on {
            FocusAccess.request { [weak self] status in
                guard let self else { return }
                if status == .authorized {
                    self.settings.focusPeeks = true
                    self.startFocusPolling()
                } else {
                    self.settings.focusPeeks = false
                    FocusAccess.explainRefusal(status)
                }
            }
        } else {
            settings.focusPeeks = false
            focusTask?.cancel()
            focusTask = nil
            wasFocused = nil
        }
    }

    /// The focus status has no change notification on macOS: read it every 2 s (a local call).
    private func startFocusPolling() {
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.checkFocus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func checkFocus() {
        guard let focused = INFocusStatusCenter.default.focusStatus.isFocused else { return }
        defer { wasFocused = focused }
        guard let wasFocused, wasFocused != focused else { return }
        model.showPeek(Peek(symbol: focused ? "moon.fill" : "moon",
                            title: focused ? "Focus on" : "Focus off",
                            subtitle: focused ? "Do Not Disturb" : nil), seconds: 2.5)
    }
}

enum FocusAccess {
    static var status: INFocusStatusAuthorizationStatus {
        INFocusStatusCenter.default.authorizationStatus
    }

    static func request(_ done: @escaping @MainActor (INFocusStatusAuthorizationStatus) -> Void) {
        if status == .authorized {
            MainActor.assumeIsolated { done(.authorized) }
            return
        }
        INFocusStatusCenter.default.requestAuthorization { status in
            Task { @MainActor in done(status) }
        }
    }

    @MainActor
    static func explainRefusal(_ status: INFocusStatusAuthorizationStatus) {
        let alert = NSAlert()
        alert.messageText = "Do Not Disturb bubbles are off"
        switch status {
        case .denied:
            alert.informativeText = "Notch is not allowed to read your Focus status. You can allow it in System Settings › Privacy & Security › Focus, then turn the bubbles on again."
        default:
            alert.informativeText = "macOS did not let Notch read the Focus status (it may require an app signed by a registered developer). macOS has no other public way to read Do Not Disturb, so these bubbles cannot be shown."
        }
        NSApp.activate()
        alert.runModal()
    }
}
