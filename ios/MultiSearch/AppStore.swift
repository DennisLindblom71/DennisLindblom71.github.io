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
    private(set) var listings: [SavedListing]
    var activeRun: SearchRun?
    private(set) var isCheckingWatches = false
    /// Annons-id:n som redan setts, per sparad sökning och sajt
    private var seen: [String: [String: [String]]]

    private let defaults = UserDefaults.standard

    private init() {
        var last = Self.load(SearchQuery.self, key: "lastSearch") ?? SearchQuery()
        last.term = ""
        query = last
        history = Self.load([SearchQuery].self, key: "history") ?? []
        saved = Self.load([SavedSearch].self, key: "saved") ?? []
        listings = Self.load([SavedListing].self, key: "listings") ?? []
        seen = Self.load([String: [String: [String]]].self, key: "seen") ?? [:]
        pruneReminders()
    }

    // MARK: Sökning

    func search(_ q: SearchQuery? = nil, newBySite: [String: Int] = [:]) {
        var q = q ?? query
        q.term = q.trimmedTerm
        guard q.canSearch else { return }
        query = q
        history.removeAll { $0.sameTerm(as: q) }
        history.insert(q, at: 0)
        history = Array(history.prefix(15))
        persist()
        activeRun = SearchRun(query: q, newBySite: newBySite)
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
        seen[item.id.uuidString] = nil
        persist()
    }

    /// Öppnar en sparad sökning och visar vilka sajter som har nya annonser
    func openSaved(_ item: SavedSearch) {
        guard let i = saved.firstIndex(where: { $0.id == item.id }) else { return }
        let news = saved[i].newBySite
        saved[i].newBySite = [:]
        if saved[i].dailyHour == nil, (saved[i].reminderAt.map { $0 <= .now } ?? false) {
            saved[i].reminderAt = nil
        }
        persist()
        activeRun = nil
        search(saved[i].query, newBySite: news)
    }

    func openSaved(id: UUID) {
        guard let item = saved.first(where: { $0.id == id }) else { return }
        openSaved(item)
    }

    // MARK: Bevakning

    func setWatching(_ item: SavedSearch, _ on: Bool) {
        update(item.id) {
            $0.watching = on
            if !on { $0.newBySite = [:]; $0.lastChecked = nil }
        }
        if on {
            Task {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])
                await checkWatches(includeBrowserSites: true, only: item.id)
            }
        } else {
            seen[item.id.uuidString] = nil
            persist()
        }
    }

    /// Kollar alla bevakade sökningar. Första gången sparas bara vilka annonser som finns;
    /// därefter räknas och notifieras de som är nya.
    func checkWatches(includeBrowserSites: Bool, only: UUID? = nil) async {
        guard !isCheckingWatches else { return }
        isCheckingWatches = true
        defer { isCheckingWatches = false }

        for item in saved where item.watching && (only == nil || item.id == only) {
            if Task.isCancelled { break }
            // Sortera alltid på nyast så att nya annonser hamnar på första sidan
            var q = item.query
            q.sortRecent = true
            var known = seen[item.id.uuidString] ?? [:]
            var fresh: [Site: Int] = [:]

            for site in item.watchableSites {
                if ListingScanner.needsBrowser(site) && !includeBrowserSites { continue }
                guard let url = site.url(for: q),
                      let ids = await ListingScanner.ids(for: site, url: url) else { continue }
                let old = known[site.rawValue] ?? []
                if !old.isEmpty {
                    let oldSet = Set(old)
                    let newIDs = ids.filter { !oldSet.contains($0) }
                    if !newIDs.isEmpty { fresh[site] = newIDs.count }
                }
                // Behåll gamla id:n också, så att annonser som glider in och ut inte räknas två gånger
                var merged = ids
                var mergedSet = Set(ids)
                for id in old where mergedSet.insert(id).inserted { merged.append(id) }
                known[site.rawValue] = Array(merged.prefix(800))
            }

            seen[item.id.uuidString] = known
            update(item.id) { s in
                s.lastChecked = .now
                for (site, n) in fresh { s.newBySite[site.rawValue, default: 0] += n }
            }
            if !fresh.isEmpty {
                await Watcher.notify(item, counts: fresh)
            }
        }
        persist()
    }

    /// Kolla när appen öppnas, men inte oftare än var 10:e minut
    func checkWatchesIfStale() {
        let stale = saved.contains { $0.watching && ($0.lastChecked.map { -$0.timeIntervalSinceNow > 600 } ?? true) }
        guard stale else { return }
        Task { await checkWatches(includeBrowserSites: true) }
    }

    // MARK: Sparade annonser

    func isListingSaved(_ url: URL?) -> Bool {
        guard let key = url?.listingKey else { return false }
        return listings.contains { $0.url.listingKey == key }
    }

    func saveListing(_ listing: SavedListing) {
        if let old = listings.first(where: { $0.url.listingKey == listing.url.listingKey }) {
            ListingFiles.delete(old)
            listings.removeAll { $0.id == old.id }
        }
        listings.insert(listing, at: 0)
        persist()
    }

    func deleteListing(_ listing: SavedListing) {
        ListingFiles.delete(listing)
        listings.removeAll { $0.id == listing.id }
        persist()
    }

    /// Hämtar bilder till annonser som sparades innan bildhämtningen fixades
    func repairListingImages() async {
        for listing in listings {
            let hasFile = listing.snapshotURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            guard !hasFile, let url = listing.imageURL else { continue }
            for candidate in ListingImages.candidates([url.absoluteString], base: listing.url) {
                if let file = await ListingImages.downloadThumbnail(candidate, id: listing.id),
                   let i = listings.firstIndex(where: { $0.id == listing.id }) {
                    listings[i].snapshotFile = file
                    listings[i].imageURL = candidate
                    persist()
                    break
                }
            }
        }
    }

    func deleteListing(url: URL) {
        let key = url.listingKey
        listings.filter { $0.url.listingKey == key }.forEach(deleteListing)
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
        Self.store(listings, key: "listings")
        Self.store(seen, key: "seen")
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
