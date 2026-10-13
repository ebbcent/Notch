import AppKit
import EventKit

/// Next event from the local calendars (EventKit). Access is asked the first
/// time the Calendar tile is shown.
@MainActor
final class CalendarService: ObservableObject {
    enum Status: Equatable { case notAsked, denied, empty, event(title: String, start: Date, end: Date, allDay: Bool) }

    @Published private(set) var status: Status = .notAsked

    private let store = EKEventStore()
    private var observer: NSObjectProtocol?
    private var asking = false

    init() {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            startObserving()
            reload()
        } else if EKEventStore.authorizationStatus(for: .event) != .notDetermined {
            status = .denied
        }
    }

    /// Called when the tile becomes visible.
    func activate() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            reload()
        case .notDetermined:
            guard !asking else { return }
            asking = true
            Task {
                let granted = (try? await store.requestFullAccessToEvents()) ?? false
                asking = false
                if granted {
                    startObserving()
                    reload()
                } else {
                    status = .denied
                }
            }
        default:
            status = .denied
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func startObserving() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func reload() {
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(14 * 24 * 3600),
                                                 calendars: nil)
        let events = store.events(matching: predicate)
            .filter { $0.endDate > now && $0.status != .canceled }
            .sorted { a, b in
                // Timed events before all-day ones on the same day.
                if a.startDate != b.startDate { return a.startDate < b.startDate }
                return !a.isAllDay && b.isAllDay
            }
        let next = events.first { !$0.isAllDay } ?? events.first
        if let next {
            status = .event(title: next.title ?? "", start: next.startDate, end: next.endDate, allDay: next.isAllDay)
        } else {
            status = .empty
        }
    }
}

/// A 25-minute focus timer.
@MainActor
final class FocusTimer: ObservableObject {
    static let length: TimeInterval = 25 * 60

    @Published private(set) var remaining: TimeInterval = FocusTimer.length
    @Published private(set) var isRunning = false

    var onFinish: () -> Void = {}

    private var endDate: Date?
    private var ticker: Task<Void, Never>?

    var isAtStart: Bool { !isRunning && remaining == Self.length }

    func toggle() {
        if isRunning {
            remaining = max(0, endDate?.timeIntervalSinceNow ?? remaining)
            isRunning = false
            ticker?.cancel()
        } else {
            if remaining <= 0 { remaining = Self.length }
            endDate = Date().addingTimeInterval(remaining)
            isRunning = true
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    self?.tick()
                }
            }
        }
    }

    func reset() {
        ticker?.cancel()
        isRunning = false
        remaining = Self.length
    }

    private func tick() {
        guard isRunning, let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        if left <= 0 {
            ticker?.cancel()
            isRunning = false
            remaining = 0
            NSSound(named: "Glass")?.play()
            onFinish()
        } else if Int(left.rounded(.up)) != Int(remaining.rounded(.up)) {
            remaining = left
        }
    }

    var label: String {
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
