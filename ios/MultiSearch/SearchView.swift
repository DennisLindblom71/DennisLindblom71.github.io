import SwiftUI

struct SearchView: View {
    @Environment(AppStore.self) private var store
    @FocusState private var focus: Field?

    private enum Field { case term, minPrice, maxPrice }

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            Form {
                searchSection
                sitesSection

                Section {
                    Button {
                        focus = nil
                        store.search()
                    } label: {
                        Label("Sök", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .disabled(!store.query.canSearch)
                }

                if !store.saved.isEmpty { savedSection }
                if !store.history.isEmpty { historySection }
            }
            .navigationTitle("Multi Search")
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Klar") { focus = nil }
                }
            }
            .fullScreenCover(item: $store.activeRun) { run in
                ResultsView(run: run)
            }
        }
    }

    // MARK: Sökfält och filter

    private var searchSection: some View {
        @Bindable var store = store
        return Section {
            TextField("Vad letar du efter?", text: $store.query.term)
                .focused($focus, equals: .term)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { store.search() }

            Picker("Plats", selection: $store.query.location) {
                ForEach(SearchLocation.allCases) { Text($0.label).tag($0) }
            }

            HStack {
                Text("Pris")
                Spacer()
                TextField("Min", text: priceBinding(\.minPrice))
                    .focused($focus, equals: .minPrice)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                Text("–").foregroundStyle(.secondary)
                TextField("Max", text: priceBinding(\.maxPrice))
                    .focused($focus, equals: .maxPrice)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 90)
                Text("kr").foregroundStyle(.secondary)
            }

            Toggle("Sortera efter senaste", isOn: $store.query.sortRecent)
        } footer: {
            if store.query.priceIsInvalid {
                Text("Minpris kan inte vara högre än maxpris.").foregroundStyle(.red)
            }
        }
    }

    private func priceBinding(_ keyPath: WritableKeyPath<SearchQuery, Int?>) -> Binding<String> {
        Binding(
            get: { store.query[keyPath: keyPath].map(String.init) ?? "" },
            set: { text in
                let digits = text.filter(\.isNumber)
                store.query[keyPath: keyPath] = digits.isEmpty ? nil : Int(digits)
            }
        )
    }

    // MARK: Sajter

    private var sitesSection: some View {
        let allOn = store.query.sites.count == Site.allCases.count
        return Group {
            Section {
                ForEach(Site.allCases.filter(\.isMarketplace)) { siteToggle($0) }
            } header: {
                HStack {
                    Text("Marknadsplatser")
                    Spacer()
                    Button(allOn ? "Avmarkera alla" : "Välj alla") {
                        store.query.sites = allOn ? [] : Site.allCases
                    }
                    .font(.caption)
                    .textCase(nil)
                }
            }
            Section("Auktioner") {
                ForEach(Site.allCases.filter { !$0.isMarketplace }) { siteToggle($0) }
            }
        }
    }

    private func siteToggle(_ site: Site) -> some View {
        Toggle(isOn: Binding(
            get: { store.query.sites.contains(site) },
            set: { on in
                if on {
                    if !store.query.sites.contains(site) { store.query.sites.append(site) }
                } else {
                    store.query.sites.removeAll { $0 == site }
                }
            }
        )) {
            HStack(spacing: 6) {
                Text(site.label)
                ForEach(site.features, id: \.self) { FeatureBadge(feature: $0) }
            }
        }
    }

    // MARK: Sparade sökningar

    private var savedSection: some View {
        Section("Sparade sökningar") {
            ForEach(store.saved) { item in
                HStack {
                    Button { store.search(item.query) } label: {
                        QueryRow(query: item.query, saved: item)
                    }
                    .buttonStyle(.borderless)
                    .tint(.primary)

                    Spacer()
                    reminderMenu(for: item)
                }
                .swipeActions {
                    Button(role: .destructive) { store.deleteSaved(item) } label: {
                        Label("Ta bort", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func reminderMenu(for item: SavedSearch) -> some View {
        Menu {
            if item.hasReminder {
                Button("Ta bort påminnelse", systemImage: "bell.slash", role: .destructive) {
                    store.cancelReminder(item)
                }
            }
            Button("Om 1 timme") { store.setReminder(item, minutes: 60) }
            Button("Om 4 timmar") { store.setReminder(item, minutes: 240) }
            Button("I morgon") { store.setReminder(item, minutes: 24 * 60) }
            Button("Varje dag kl 08") { store.setDailyReminder(item, hour: 8) }
            Button("Varje dag kl 18") { store.setDailyReminder(item, hour: 18) }
        } label: {
            Image(systemName: item.hasReminder ? "bell.fill" : "bell")
                .foregroundStyle(item.hasReminder ? .orange : .secondary)
                .padding(6)
        }
        .accessibilityLabel(item.hasReminder ? "Ändra påminnelse" : "Sätt påminnelse")
    }

    // MARK: Historik

    private var historySection: some View {
        Section {
            ForEach(store.history, id: \.self) { q in
                Button { store.search(q) } label: {
                    QueryRow(query: q, saved: nil)
                }
                .tint(.primary)
                .swipeActions(edge: .leading) {
                    Button { store.save(q) } label: {
                        Label("Spara", systemImage: "star")
                    }
                    .tint(.yellow)
                }
            }
            .onDelete { store.removeHistory(at: $0) }
        } header: {
            HStack {
                Text("Historik")
                Spacer()
                Button("Rensa", role: .destructive) { store.clearHistory() }
                    .font(.caption)
                    .textCase(nil)
            }
        } footer: {
            Text("Svep höger för att spara, vänster för att ta bort.")
        }
    }
}

struct QueryRow: View {
    let query: SearchQuery
    let saved: SavedSearch?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(query.trimmedTerm)
            Text(query.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let saved {
                if let hour = saved.dailyHour {
                    Label("Varje dag kl \(String(format: "%02d", hour))", systemImage: "bell.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let date = saved.reminderAt, date > .now {
                    Label {
                        Text(date, style: .relative)
                    } icon: {
                        Image(systemName: "bell.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

struct FeatureBadge: View {
    let feature: SiteFeature

    var body: some View {
        Text(feature.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch feature {
        case .location: .gray
        case .price: .teal
        case .newest: .orange
        }
    }
}
