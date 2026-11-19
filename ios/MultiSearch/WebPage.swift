import Observation
import SwiftUI
import WebKit

/// En sökning som pågår: en webbflik per vald sajt.
@MainActor
@Observable
final class SearchRun: Identifiable {
    let id = UUID()
    let query: SearchQuery
    let pages: [WebPage]
    private(set) var selected: Site
    /// Nya annonser per sajt från bevakningen (Site.rawValue)
    let newBySite: [String: Int]

    init(query: SearchQuery, newBySite: [String: Int] = [:]) {
        self.query = query
        self.newBySite = newBySite
        pages = query.orderedSites.compactMap { site in
            site.url(for: query).map { WebPage(site: site, url: $0) }
        }
        // Börja på den första sajten som har nya annonser
        let start = pages.first { (newBySite[$0.site.rawValue] ?? 0) > 0 } ?? pages.first
        selected = start?.site ?? .blocket
        start?.viewed = true
    }

    var selectedPage: WebPage? { pages.first { $0.site == selected } }

    var nextUnviewed: WebPage? {
        guard let start = pages.firstIndex(where: { $0.site == selected }) else { return nil }
        let ordered = pages[(start + 1)...] + pages[..<start]
        return ordered.first { !$0.viewed }
    }

    var viewedCount: Int { pages.filter(\.viewed).count }

    func select(_ site: Site) {
        selected = site
        pages.first { $0.site == site }?.viewed = true
    }
}

/// En WKWebView med tillstånd som SwiftUI kan följa.
@MainActor
@Observable
final class WebPage: NSObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let site: Site
    let startURL: URL
    @ObservationIgnored let webView: WKWebView

    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var currentURL: URL?
    var viewed = false

    @ObservationIgnored private var observers: [NSKeyValueObservation] = []

    nonisolated var id: Site { site }

    init(site: Site, url: URL) {
        self.site = site
        self.startURL = url

        let config = WKWebViewConfiguration()
        // Delad lagring så att inloggningar (t.ex. Facebook) sparas mellan sökningar
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        // Utan "Safari" i user agent visar en del sajter en sämre mobilversion
        config.applicationNameForUserAgent = "Version/18.0 Mobile/15E148 Safari/604.1"

        webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self

        observers = [
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.isLoading = wv.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.url, options: [.initial, .new]) { [weak self] wv, _ in
                MainActor.assumeIsolated { self?.currentURL = wv.url }
            },
        ]

        webView.load(URLRequest(url: url))
    }

    func goHome() {
        webView.load(URLRequest(url: startURL))
    }

    // Länkar med target="_blank" öppnas i samma flik
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // Stanna i appen: blockera hopp till andra appar (fb://, itms-apps:// osv.)
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        let allowed = ["http", "https", "about", "blob", "data", "javascript"]
        decisionHandler(allowed.contains(scheme) ? .allow : .cancel)
    }
}

struct WebViewContainer: UIViewRepresentable {
    let page: WebPage

    func makeUIView(context: Context) -> WKWebView { page.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
