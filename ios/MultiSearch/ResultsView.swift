import SwiftUI

struct ResultsView: View {
    let run: SearchRun
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var toast: String?
    @State private var isSavingListing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                siteTabs
                progressBar
                pagesStack
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .overlay(alignment: .bottom) { toastView }
            .sensoryFeedback(.success, trigger: toast) { _, new in new != nil }
            .navigationTitle(run.query.trimmedTerm)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Stäng") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        store.save(run.query)
                    } label: {
                        Image(systemName: store.isSaved(run.query) ? "star.fill" : "star")
                    }
                    .tint(.yellow)
                    .accessibilityLabel("Spara sökning")
                }
            }
        }
    }

    // MARK: Flikar

    private var siteTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(run.pages) { page in
                        SiteChip(page: page, isSelected: page.site == run.selected) {
                            run.select(page.site)
                        }
                        .id(page.site)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: run.selected) { _, new in
                withAnimation { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .background(.bar)
    }

    private var progressBar: some View {
        let page = run.selectedPage
        return ProgressView(value: page?.progress ?? 0)
            .progressViewStyle(.linear)
            .frame(height: 2)
            .opacity(page?.isLoading == true ? 1 : 0)
            .animation(.easeOut, value: page?.isLoading)
    }

    // Alla webbvyer ligger kvar så att sidorna inte laddas om när man byter flik
    private var pagesStack: some View {
        ZStack {
            ForEach(run.pages) { page in
                let visible = page.site == run.selected
                WebViewContainer(page: page)
                    .opacity(visible ? 1 : 0)
                    .allowsHitTesting(visible)
                    .accessibilityHidden(!visible)
            }
        }
    }

    // MARK: Verktygsfält

    private var bottomBar: some View {
        let page = run.selectedPage

        return HStack(spacing: 4) {
            barButton("chevron.backward", "Bakåt", enabled: page?.canGoBack == true) {
                page?.webView.goBack()
            }
            barButton("chevron.forward", "Framåt", enabled: page?.canGoForward == true) {
                page?.webView.goForward()
            }

            Spacer(minLength: 8)

            if let next = run.nextUnviewed {
                Button {
                    run.select(next.site)
                } label: {
                    HStack(spacing: 6) {
                        Text("Nästa: \(next.site.shortLabel)")
                            .lineLimit(1)
                        Image(systemName: "arrow.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.accentColor))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            } else {
                Label("Alla \(run.pages.count) kollade", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.green)
            }

            Spacer(minLength: 8)

            let saved = store.isListingSaved(page?.currentURL)
            Button {
                toggleListing(page)
            } label: {
                Image(systemName: saved ? "heart.fill" : "heart")
                    .font(.body.weight(.medium))
                    .foregroundStyle(saved ? .red : .accentColor)
                    .frame(width: 40, height: 40)
                    .symbolEffect(.bounce, value: saved)
            }
            .disabled(page?.currentURL == nil || isSavingListing)
            .accessibilityLabel(saved ? "Ta bort sparad annons" : "Spara annons")

            Menu {
                Button("Ladda om sökningen", systemImage: "arrow.clockwise") { page?.goHome() }
                if let url = page?.currentURL {
                    ShareLink(item: url) { Label("Dela", systemImage: "square.and.arrow.up") }
                    Link(destination: url) { Label("Öppna i Safari", systemImage: "safari") }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body.weight(.medium))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("Fler val")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func toggleListing(_ page: WebPage?) {
        guard let page, let url = page.currentURL else { return }
        if store.isListingSaved(url) {
            store.deleteListing(url: url)
            showToast("Borttagen från sparade")
            return
        }
        isSavingListing = true
        Task {
            if let listing = await page.extractListing() {
                store.saveListing(listing)
                showToast("Annons sparad")
            }
            isSavingListing = false
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(duration: 0.3)) { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            withAnimation(.easeOut) { if toast == text { toast = nil } }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: toast == "Annons sparad" ? "heart.fill" : "heart.slash")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 6, y: 2)
                .padding(.bottom, 70)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func barButton(_ icon: String, _ label: String, enabled: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.medium))
                .frame(width: 40, height: 40)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

struct SiteChip: View {
    let page: WebPage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if page.isLoading {
                    ProgressView().controlSize(.mini)
                        .tint(isSelected ? .white : nil)
                } else if page.viewed {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(isSelected ? .white : .green)
                }
                Text(page.site.label)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
