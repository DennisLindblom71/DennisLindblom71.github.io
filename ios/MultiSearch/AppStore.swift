import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    var query: SearchQuery
    private(set) var history: [SearchQuery]
    private(set) var saved: [SavedSearch]
    var activeRun: SearchRun?

    private let defaults = UserDefaults.standard

    private init() {
        var last = Self.load(SearchQuery.self, key: "lastSearch") ?? SearchQuery()
        last.term = ""
        query = last
        history = Self.load([SearchQuery].self, key: "history") ?? []
        saved = Self.load([SavedSearch].self, key: "saved") ?? []
        pruneReminders()
    }

    // MARK: Sökning

    func search(_ q: SearchQuery? = nil) {
        var q = q ?? query
        q.term = q.trimmedTerm
        guard q.canSearch else { return }
        query = q
        history.removeAll { $0.sameTerm(as: q) }
        history.insert(q, at: 0)
        history = Array(history.prefix(15))
        persist()
        activeRun = SearchRun(query: q)
    }

    func removeHistory(at offsets: IndexSet) {
        history.remove(atOffsets: offsets)
        persist()
    }

    func clearHistory() {
        history = []
        persist()
    }

    // MARK: Sparade sökningar

    func isSaved(_ q: SearchQuery) -> Bool {
        saved.contains { $0.query.sameTerm(as: q) }
    }

    func save(_ q: SearchQuery) {
        if let i = saved.firstIndex(where: { $0.query.sameTerm(as: q) }) {
            saved[i].query = q
        } else {
            saved.insert(SavedSearch(query: q), at: 0)
        }
        persist()
    }

    func deleteSaved(_ item: SavedSearch) {
        Reminders.cancel(item.id)
        saved.removeAll { $0.id == item.id }
        persist()
    }

    func openSaved(id: UUID) {
        guard let i = saved.firstIndex(where: { $0.id == id }) else { return }
        if saved[i].dailyHour == nil { saved[i].reminderAt = nil }
        persist()
        activeRun = nil
        search(saved[i].query)
    }

    // MARK: Påminnelser

    func setReminder(_ item: SavedSearch, minutes: Int) {
        Task {
            let date = Date.now.addingTimeInterval(TimeInterval(minutes * 60))
            guard await Reminders.schedule(item, at: date) else { return }
            update(item.id) { $0.reminderAt = date; $0.dailyHour = nil }
        }
    }

    func setDailyReminder(_ item: SavedSearch, hour: Int) {
        Task {
            guard await Reminders.scheduleDaily(item, hour: hour) else { return }
            update(item.id) { $0.dailyHour = hour; $0.reminderAt = nil }
        }
    }

    func cancelReminder(_ item: SavedSearch) {
        Reminders.cancel(item.id)
        update(item.id) { $0.reminderAt = nil; $0.dailyHour = nil }
    }

    func pruneReminders() {
        for i in saved.indices where (saved[i].reminderAt.map { $0 <= .now } ?? false) {
            saved[i].reminderAt = nil
        }
        persist()
    }

    private func update(_ id: UUID, _ change: (inout SavedSearch) -> Void) {
        guard let i = saved.firstIndex(where: { $0.id == id }) else { return }
        change(&saved[i])
        persist()
    }

    // MARK: Lagring

    private func persist() {
        Self.store(query, key: "lastSearch")
        Self.store(history, key: "history")
        Self.store(saved, key: "saved")
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func store<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum Reminders {
    private static func authorize() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    private static func content(for item: SavedSearch) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = "Multi Search"
        c.body = "Dags att kolla \"\(item.query.trimmedTerm)\" igen!"
        c.sound = .default
        c.userInfo = ["savedID": item.id.uuidString]
        return c
    }

    static func schedule(_ item: SavedSearch, at date: Date) async -> Bool {
        guard await authorize() else { return false }
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        return await add(item, trigger: trigger)
    }

    static func scheduleDaily(_ item: SavedSearch, hour: Int) async -> Bool {
        guard await authorize() else { return false }
        var comps = DateComponents()
        comps.hour = hour
        comps.minute = 0
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        return await add(item, trigger: trigger)
    }

    private static func add(_ item: SavedSearch, trigger: UNNotificationTrigger) async -> Bool {
        let request = UNNotificationRequest(
            identifier: item.id.uuidString, content: content(for: item), trigger: trigger)
        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            return false
        }
    }

    static func cancel(_ id: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [id.uuidString])
    }
}
