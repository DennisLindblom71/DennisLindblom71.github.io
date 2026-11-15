import SwiftUI

struct ResultsView: View {
    let run: SearchRun
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                siteTabs
                progressBar
                pagesStack
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
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

            barButton("arrow.clockwise", "Ladda om sökningen", enabled: page != nil) {
                page?.goHome()
            }
            if let url = page?.currentURL {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("Dela eller öppna i Safari")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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
