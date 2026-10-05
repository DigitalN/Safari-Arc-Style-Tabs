import SwiftUI

/// Pinned to the top of the sidebar: the current site and a reload button. Clicking the
/// site opens Safari's own address bar (like ⌘L), which has Safari's full autocomplete;
/// extensions can't read Safari's history or suggestions to recreate it.
struct AddressBar: View {
    @Environment(TabStore.self) private var store
    @State private var hovering = false

    var body: some View {
        let active = store.activeTab
        let url = active?.tab.url.flatMap(URL.init(string:))
        let shown = displayText(for: url)

        HStack(spacing: 6) {
            HStack(spacing: 5) {
                if url?.scheme == "https" {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                Text(shown ?? "Search or enter website")
                    .foregroundStyle(shown == nil ? .tertiary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.075 : 0.05))
            )
            .background(MouseTracking(onHover: { hovering = $0 }))
            .contentShape(Rectangle())
            .onTapGesture { store.openAddressBar() }
            .help(active?.tab.url ?? "Search or enter website")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens Safari's address bar")

            SidebarIconButton(systemImage: "arrow.clockwise", help: "Reload Page", size: 12) {
                store.reloadActiveTab()
            }
            .disabled(active == nil)
        }
    }

    /// The site, like Safari shows it: host without "www.".
    private func displayText(for url: URL?) -> String? {
        guard let url else { return nil }
        if url.isFileURL {
            return url.lastPathComponent
        }
        guard let host = url.host(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
