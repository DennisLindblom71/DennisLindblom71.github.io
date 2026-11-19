import SwiftUI
import WebKit

// MARK: Modell

struct SavedListing: Codable, Identifiable, Hashable {
    var id = UUID()
    var site: Site
    var url: URL
    var title: String
    var price: String?
    var imageURL: URL?
    /// Skärmdump som används när sidan saknar bild
    var snapshotFile: String?
    var savedAt = Date()

    var snapshotURL: URL? { snapshotFile.map { ListingFiles.directory.appendingPathComponent($0) } }
}

enum ListingFiles {
    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Listings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func delete(_ listing: SavedListing) {
        if let url = listing.snapshotURL { try? FileManager.default.removeItem(at: url) }
    }
}

extension URL {
    /// Jämförelsenyckel utan #fragment
    var listingKey: String {
        var c = URLComponents(url: self, resolvingAgainstBaseURL: false)
        c?.fragment = nil
        return c?.string ?? absoluteString
    }
}

// MARK: Hämta titel, bild och pris från sidan

private struct PageMeta: Decodable {
    var title: String?
    var image: String?
    var price: String?
    var currency: String?
}

extension WebPage {
    /// Läser Open Graph- och JSON-LD-data från sidan som visas just nu.
    func extractListing() async -> SavedListing? {
        guard let url = webView.url else { return nil }

        var meta = PageMeta()
        if let json = try? await webView.evaluateJavaScript(Self.metaScript) as? String,
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(PageMeta.self, from: data) {
            meta = decoded
        }

        var listing = SavedListing(
            site: site,
            url: url,
            title: Self.cleanTitle(meta.title ?? webView.title ?? "", site: site),
            price: Self.formatPrice(meta.price, currency: meta.currency),
            imageURL: meta.image.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
        )
        if listing.title.isEmpty { listing.title = site.label }

        if listing.imageURL == nil {
            listing.snapshotFile = await saveSnapshot(id: listing.id)
        }
        return listing
    }

    private func saveSnapshot(id: UUID) async -> String? {
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 300
        guard let image = try? await webView.takeSnapshot(configuration: config),
              let data = image.jpegData(compressionQuality: 0.7) else { return nil }
        let name = "\(id.uuidString).jpg"
        do {
            try data.write(to: ListingFiles.directory.appendingPathComponent(name))
            return name
        } catch {
            return nil
        }
    }

    /// Tar bort "| Blocket", "- Tradera" osv. i slutet av titeln
    private static func cleanTitle(_ raw: String, site: Site) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for sep in [" | ", " - ", " – ", " · "] {
            if let range = title.range(of: sep, options: .backwards) {
                let tail = title[range.upperBound...].lowercased()
                if tail.contains(site.shortLabel.lowercased()) || tail.contains(site.rawValue) {
                    title = String(title[..<range.lowerBound])
                }
            }
        }
        return title
    }

    private static func formatPrice(_ raw: String?, currency: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        guard let value = Double(raw.replacingOccurrences(of: ",", with: ".")) else { return raw }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "sv_SE")
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        let number = f.string(from: NSNumber(value: value)) ?? raw
        let cur = (currency ?? "SEK").uppercased()
        return cur == "SEK" ? "\(number) kr" : "\(number) \(cur)"
    }

    private static let metaScript = """
    (() => {
      const m = n => {
        const el = document.querySelector(`meta[property="${n}"],meta[name="${n}"],meta[itemprop="${n}"]`);
        return el ? el.getAttribute('content') : null;
      };
      let title = m('og:title') || m('twitter:title') || document.title;
      let image = m('og:image') || m('og:image:url') || m('twitter:image');
      let price = m('product:price:amount') || m('og:price:amount') || m('price');
      let currency = m('product:price:currency') || m('og:price:currency') || m('priceCurrency');
      const walk = o => {
        if (!o || typeof o !== 'object') return;
        if (Array.isArray(o)) { o.forEach(walk); return; }
        if (o['@graph']) walk(o['@graph']);
        if (o.offers && price == null) {
          const off = Array.isArray(o.offers) ? o.offers[0] : o.offers;
          if (off) {
            price = off.price ?? off.lowPrice ?? null;
            currency = currency || off.priceCurrency || null;
          }
        }
        if (!image && o.image) {
          const img = Array.isArray(o.image) ? o.image[0] : o.image;
          image = typeof img === 'string' ? img : (img && img.url) || null;
        }
        if (!title && o.name) title = o.name;
      };
      document.querySelectorAll('script[type="application/ld+json"]').forEach(s => {
        try { walk(JSON.parse(s.textContent)); } catch (e) {}
      });
      return JSON.stringify({
        title: title || null,
        image: image || null,
        price: price != null ? String(price) : null,
        currency: currency || null
      });
    })()
    """
}

// MARK: Lista med sparade annonser

struct ListingsView: View {
    @Environment(AppStore.self) private var store
    @State private var filter: Site?
    @State private var openPage: ListingPage?

    private var sitesInUse: [Site] {
        Site.allCases.filter { site in store.listings.contains { $0.site == site } }
    }

    private var shown: [SavedListing] {
        store.listings.filter { filter == nil || $0.site == filter }
    }

    var body: some View {
        List {
            ForEach(shown) { listing in
                Button {
                    openPage = ListingPage(listing: listing)
                } label: {
                    ListingRow(listing: listing)
                }
                .tint(.primary)
                .swipeActions {
                    Button(role: .destructive) { store.deleteListing(listing) } label: {
                        Label("Ta bort", systemImage: "trash")
                    }
                }
                .contextMenu {
                    ShareLink(item: listing.url) { Label("Dela", systemImage: "square.and.arrow.up") }
                    Link(destination: listing.url) { Label("Öppna i Safari", systemImage: "safari") }
                    Button("Ta bort", systemImage: "trash", role: .destructive) { store.deleteListing(listing) }
                }
            }
        }
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView(
                    "Inga sparade annonser",
                    systemImage: "heart",
                    description: Text("Tryck på hjärtat när du tittar på en annons för att spara den här.")
                )
            }
        }
        .navigationTitle("Sparade annonser")
        .toolbar {
            if sitesInUse.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sajt", selection: $filter) {
                            Text("Alla sajter").tag(Site?.none)
                            ForEach(sitesInUse) { Text($0.label).tag(Site?.some($0)) }
                        }
                    } label: {
                        Image(systemName: filter == nil
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("Filtrera på sajt")
                }
            }
        }
        .sheet(item: $openPage) { ListingDetailView(item: $0) }
    }
}

struct ListingRow: View {
    let listing: SavedListing

    var body: some View {
        HStack(spacing: 12) {
            ListingThumbnail(listing: listing)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(listing.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    if let price = listing.price {
                        Text(price).fontWeight(.semibold)
                    }
                    Text(listing.site.shortLabel).foregroundStyle(.secondary)
                }
                .font(.caption)
                Text(listing.savedAt, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

struct ListingThumbnail: View {
    let listing: SavedListing

    var body: some View {
        ZStack {
            Color(.secondarySystemBackground)
            if let url = listing.imageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else if let file = listing.snapshotURL, let image = UIImage(contentsOfFile: file.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        Image(systemName: "photo").foregroundStyle(.tertiary)
    }
}

/// En sparad annons som öppnas i en egen webbvy
@MainActor
final class ListingPage: Identifiable {
    let listing: SavedListing
    let page: WebPage
    nonisolated let id: UUID

    init(listing: SavedListing) {
        self.listing = listing
        id = listing.id
        page = WebPage(site: listing.site, url: listing.url)
    }
}

struct ListingDetailView: View {
    let item: ListingPage
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ProgressView(value: item.page.progress)
                    .progressViewStyle(.linear)
                    .frame(height: 2)
                    .opacity(item.page.isLoading ? 1 : 0)
                WebViewContainer(page: item.page)
            }
            .navigationTitle(item.listing.site.shortLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Stäng") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: item.page.currentURL ?? item.listing.url)
                    Button(role: .destructive) {
                        store.deleteListing(item.listing)
                        dismiss()
                    } label: {
                        Image(systemName: "heart.slash")
                    }
                    .accessibilityLabel("Ta bort från sparade")
                }
            }
        }
    }
}
