import Foundation

enum SiteFeature: String {
    case location = "Plats"
    case price = "Pris"
    case newest = "Nyast"
}

enum SearchLocation: String, Codable, CaseIterable, Identifiable {
    case sweden = ""
    case stockholm

    var id: String { rawValue }
    var label: String {
        switch self {
        case .sweden: "Hela Sverige"
        case .stockholm: "Stockholm"
        }
    }
}

enum Site: String, CaseIterable, Codable, Identifiable {
    case blocket, tradera, facebook, vinted, sellpy
    case budi, psauction, auctionet, pantbanken, bukowskis

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blocket: "Blocket"
        case .tradera: "Tradera"
        case .facebook: "Facebook Marketplace"
        case .vinted: "Vinted"
        case .sellpy: "Sellpy"
        case .budi: "Budi"
        case .psauction: "PS Auction"
        case .auctionet: "Auctionet"
        case .pantbanken: "Pantbanken"
        case .bukowskis: "Bukowskis"
        }
    }

    /// Kort namn för knappar med lite plats
    var shortLabel: String { self == .facebook ? "Facebook" : label }

    /// Marknadsplatser som är förvalda. Övriga är auktionssajter.
    var isMarketplace: Bool {
        [.blocket, .tradera, .facebook, .vinted, .sellpy].contains(self)
    }

    var features: [SiteFeature] {
        switch self {
        case .blocket, .tradera, .facebook: [.location, .price, .newest]
        case .vinted, .sellpy, .pantbanken: [.price, .newest]
        case .budi: [.location, .newest]
        case .psauction, .auctionet: [.newest]
        case .bukowskis: []
        }
    }

    func url(for q: SearchQuery) -> URL? {
        let t = q.term.trimmingCharacters(in: .whitespaces).uriComponentEncoded
        let sthlm = q.location == .stockholm
        let minP = q.minPrice.map(String.init)
        let maxP = q.maxPrice.map(String.init)
        var s: String

        switch self {
        case .blocket:
            s = "https://www.blocket.se"
                + (sthlm ? "/annonser/stockholm/hela_stockholm" : "/annonser/hela_sverige")
                + "?q=\(t)"
            if q.sortRecent { s += "&sort=date" }
            if let m = minP { s += "&price_start=\(m)" }
            if let m = maxP { s += "&price_end=\(m)" }
            if sthlm { s += "&r=11" }

        case .tradera:
            s = "https://www.tradera.com/search?q=\(t)"
            if q.sortRecent { s += "&sortBy=AddedOn" }
            if sthlm { s += "&location=Stockholm" }
            if let m = minP { s += "&fromPrice=\(m)" }
            if let m = maxP { s += "&toPrice=\(m)" }

        case .facebook:
            s = sthlm
                ? "https://www.facebook.com/marketplace/stockholm/search?query=\(t)&exact=false"
                : "https://www.facebook.com/marketplace/search?query=\(t)&exact=false"
            if q.sortRecent { s += "&daysSinceListed=7" }
            if let m = minP { s += "&minPrice=\(m)" }
            if let m = maxP { s += "&maxPrice=\(m)" }

        case .vinted:
            s = "https://www.vinted.se/catalog?search_text=\(t)"
            if q.sortRecent { s += "&order=newest_first" }
            if let m = minP { s += "&price_from=\(m)" }
            if let m = maxP { s += "&price_to=\(m)" }

        case .sellpy:
            s = "https://www.sellpy.se/search?query=\(t)"
            if q.sortRecent { s += "&sortBy=published" }
            if let m = minP { s += "&minPrice=\(m)" }
            if let m = maxP { s += "&maxPrice=\(m)" }

        case .budi:
            s = "https://www.budi.se/objekt?q=\(t)"
            if q.sortRecent { s += "&s=new" }
            if sthlm { s += "&l=stockholm" }

        case .psauction:
            s = "https://psauction.se/search/sok=\(t)"
            if q.sortRecent { s += "&sortering=nyast" }

        case .auctionet:
            s = "https://auctionet.com/sv/search?q=\(t)"
            if q.sortRecent { s += "&order=recent" }

        case .pantbanken:
            s = "https://www.pantbanken.se/auktioner/?fran_form=1&fritext=\(t)&length=100"
            if let m = minP { s += "&pris_min=\(m)" }
            if let m = maxP { s += "&pris_max=\(m)" }
            if q.sortRecent { s += "&sortering=f_id%20desc" }

        case .bukowskis:
            s = "https://www.bukowskis.com/sv/lots/search/\(t)"
        }
        return URL(string: s)
    }
}

struct SearchQuery: Codable, Hashable {
    var term: String = ""
    var sites: [Site] = Site.allCases.filter(\.isMarketplace)
    var location: SearchLocation = .sweden
    var minPrice: Int?
    var maxPrice: Int?
    var sortRecent = false

    var trimmedTerm: String { term.trimmingCharacters(in: .whitespaces) }

    var priceIsInvalid: Bool {
        if let lo = minPrice, let hi = maxPrice { return lo > hi }
        return false
    }

    var canSearch: Bool { !trimmedTerm.isEmpty && !sites.isEmpty && !priceIsInvalid }

    /// Sajter i samma ordning som i listan, oavsett i vilken ordning de valdes.
    var orderedSites: [Site] { Site.allCases.filter(sites.contains) }

    var summary: String {
        var parts = ["\(sites.count) sajter"]
        if minPrice != nil || maxPrice != nil {
            parts.append("\(minPrice ?? 0)–\(maxPrice.map(String.init) ?? "∞") kr")
        }
        if location == .stockholm { parts.append("Stockholm") }
        if sortRecent { parts.append("nyast") }
        return parts.joined(separator: " · ")
    }

    func sameTerm(as other: SearchQuery) -> Bool {
        trimmedTerm.lowercased() == other.trimmedTerm.lowercased()
    }
}

struct SavedSearch: Codable, Identifiable, Hashable {
    var id = UUID()
    var query: SearchQuery
    /// Engångspåminnelse
    var reminderAt: Date?
    /// Daglig påminnelse vid denna timme
    var dailyHour: Int?
    /// Bevakning: kolla efter nya annonser
    var watching = false
    /// Antal nya annonser per sajt (Site.rawValue) sedan du senast öppnade sökningen
    var newBySite: [String: Int] = [:]
    var lastChecked: Date?

    var hasReminder: Bool { dailyHour != nil || (reminderAt.map { $0 > .now } ?? false) }
    var newCount: Int { newBySite.values.reduce(0, +) }

    /// Sajter i sökningen som går att bevaka
    var watchableSites: [Site] { query.orderedSites.filter(ListingScanner.isSupported) }

    init(query: SearchQuery) {
        self.query = query
    }

    // Egen avkodning så att sökningar sparade av äldre versioner fortfarande läses in
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        query = try c.decode(SearchQuery.self, forKey: .query)
        reminderAt = try c.decodeIfPresent(Date.self, forKey: .reminderAt)
        dailyHour = try c.decodeIfPresent(Int.self, forKey: .dailyHour)
        watching = try c.decodeIfPresent(Bool.self, forKey: .watching) ?? false
        newBySite = try c.decodeIfPresent([String: Int].self, forKey: .newBySite) ?? [:]
        lastChecked = try c.decodeIfPresent(Date.self, forKey: .lastChecked)
    }
}

extension String {
    /// Samma som JavaScripts encodeURIComponent
    var uriComponentEncoded: String {
        let allowed = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.!~*'()")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
