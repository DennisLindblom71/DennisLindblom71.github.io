import BackgroundTasks
import UIKit
import UserNotifications
import WebKit

/// Hämtar annons-id:n från en söksida så att nya annonser kan upptäckas.
enum ListingScanner {
    static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// Mönster för annonslänkar. Första gruppen är annonsens id.
    static func pattern(for site: Site) -> String? {
        switch site {
        case .blocket: #"/recommerce/forsale/item/(\d+)"#
        case .tradera: #"/item/\d+/(\d+)/"#
        case .vinted: #"/items/(\d+)"#
        case .auctionet: #"/sv/(\d{5,})-"#
        case .sellpy: #"/item/([A-Za-z0-9]{8,14})(?![A-Za-z0-9])"#
        case .facebook: #"/marketplace/item/(\d+)"#
        case .budi, .psauction, .pantbanken, .bukowskis: nil
        }
    }

    static func isSupported(_ site: Site) -> Bool { pattern(for: site) != nil }

    /// Sajter som bygger sidan med JavaScript (eller kräver inloggning) måste läsas
    /// med en riktig webbvy, och det fungerar bara när appen är öppen.
    static func needsBrowser(_ site: Site) -> Bool { site == .sellpy || site == .facebook }

    static func ids(for site: Site, url: URL) async -> [String]? {
        guard let pattern = pattern(for: site) else { return nil }
        let text: String?
        if needsBrowser(site) {
            text = await RenderedPage.links(url: url, pattern: pattern)
        } else {
            text = await html(url: url)
        }
        guard let text else { return nil }
        let found = matches(in: text, pattern: pattern)
        return found.isEmpty ? nil : found
    }

    private static func html(url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("sv-SE,sv;q=0.9", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Unika id:n i den ordning de förekommer
    static func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var seen = Set<String>()
        var result: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        regex.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: text) else { return }
            let id = String(text[r])
            if seen.insert(id).inserted { result.append(id) }
        }
        return result
    }
}

/// Laddar en sida i en osynlig webbvy och returnerar alla länkar när
/// annonserna har hunnit visas.
@MainActor
final class RenderedPage: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Never>?

    static func links(url: URL, pattern: String) async -> String? {
        await RenderedPage().load(url: url, pattern: pattern)
    }

    private func load(url: URL, pattern: String) async -> String? {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // samma inloggningar som i appen
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"
        let wv = WKWebView(frame: CGRect(x: -2000, y: 0, width: 390, height: 844), configuration: config)
        wv.navigationDelegate = self
        wv.alpha = 0.01
        // Webbvyer utanför ett fönster kan strypas, så lägg den osynligt i fönstret
        let window = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        window?.addSubview(wv)
        webView = wv
        defer {
            wv.removeFromSuperview()
            webView = nil
        }

        wv.load(URLRequest(url: url))
        await withCheckedContinuation { c in
            loaded = c
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                self?.finishLoading()
            }
        }

        // Vänta tills antalet annonslänkar slutar växa (max ~8 s)
        let script = "JSON.stringify([...document.querySelectorAll('a[href]')].map(a => a.href))"
        var last = -1
        var text: String?
        for _ in 0..<8 {
            try? await Task.sleep(for: .seconds(1))
            text = try? await wv.evaluateJavaScript(script) as? String
            let count = text.map { ListingScanner.matches(in: $0, pattern: pattern).count } ?? 0
            if count > 0 && count == last { break }
            last = count
        }
        return text
    }

    private func finishLoading() {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) { finishLoading() }
}

/// Bakgrundskoll av bevakningar
enum Watcher {
    static let taskID = "se.dennislindblom.multisearch.watch"

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()
            let work = Task { @MainActor in
                await AppStore.shared.checkWatches(includeBrowserSites: false)
                task.setTaskCompleted(success: true)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// iOS bestämmer själv exakt när, men tidigast om 30 minuter
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func notify(_ item: SavedSearch, counts: [Site: Int]) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let total = counts.values.reduce(0, +)
        let c = UNMutableNotificationContent()
        c.title = total == 1
            ? "1 ny annons för \"\(item.query.trimmedTerm)\""
            : "\(total) nya annonser för \"\(item.query.trimmedTerm)\""
        c.body = Site.allCases.compactMap { site in
            counts[site].map { "\(site.shortLabel) \($0)" }
        }.joined(separator: " · ")
        c.sound = .default
        c.userInfo = ["savedID": item.id.uuidString]
        let request = UNNotificationRequest(identifier: "watch-\(item.id.uuidString)", content: c, trigger: nil)
        try? await center.add(request)
    }
}
