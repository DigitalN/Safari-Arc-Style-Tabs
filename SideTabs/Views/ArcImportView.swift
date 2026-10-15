import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Reading and browsing this window never imports or opens a website.
struct ArcImportView: View {
    @Environment(TabStore.self) private var store
    @State private var snapshot: ArcImportSnapshot?
    @State private var sourceURL = ArcImportReader.defaultURL
    @State private var selectedSpaces = Set<String>()
    @State private var focusedSpace: String? = nil
    @State private var includeFavorites = true
    @State private var query = ""
    @State private var error: String?
    @State private var loading = false
    @State private var confirming = false
    @State private var undoing: UUID?
    @State private var showOptions = false
    @State private var showHistory = false
    @State private var restoreNow = false
    @State private var destinations: [String: ArcImportDestination] = [:]

    private var selectedProfiles: [String] {
        Array(Set(snapshot?.spaces.filter { selectedSpaces.contains($0.id) }.map(\.profileID) ?? [])).sorted()
    }
    private var eligibleEntries: [ArcImportEntry] {
        snapshot?.entries.filter { $0.spaceID.map(selectedSpaces.contains) ?? (includeFavorites && selectedProfiles.contains($0.profileID)) } ?? []
    }
    private var newCount: Int {
        (snapshot?.spaces.filter { selectedSpaces.contains($0.id) && store.arcDisposition($0) == .add }.count ?? 0)
        + eligibleEntries.filter { store.arcDisposition($0) == .add }.count
    }
    private var reviewCount: Int { eligibleEntries.filter { store.arcDisposition($0) == .conflict || store.arcDisposition($0) == .attention }.count }
    private var safariWindows: [(ArcImportDestination, String)] {
        store.snapshots.values.filter { $0.capabilities?.contains("arcMigrationV1") == true }.sorted { $0.instance < $1.instance }.flatMap { snapshot in
            snapshot.windows.filter { !$0.incognito }.map { window in
                let title = window.tabs.first(where: \.active)?.title ?? "Safari Window"
                let label = "\(snapshot.profile ?? String(snapshot.instance.prefix(6))) · \(title.prefix(48)) (\(window.tabs.count) tabs)"
                return (ArcImportDestination(instance: snapshot.instance, windowID: window.id), label)
            }
        }
    }
    private var visibleEntries: [ArcImportEntry] {
        (snapshot?.entries ?? []).filter { entry in
            let matchesSpace = focusedSpace == "favorites" ? entry.spaceID == nil : (focusedSpace == nil || entry.spaceID == focusedSpace)
            return matchesSpace && (query.isEmpty || entry.title.localizedCaseInsensitiveContains(query) || (entry.url?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let snapshot {
                summary(snapshot)
                HSplitView {
                    spacesList(snapshot).frame(minWidth: 230, idealWidth: 260, maxWidth: 320)
                    detail(snapshot).frame(minWidth: 480)
                }
                .frame(minHeight: 270)
                DisclosureGroup("Import options and notes", isExpanded: $showOptions) {
                    options(snapshot)
                }
                if !store.arcMigration.receipts.isEmpty || !store.arcMigration.tabs.isEmpty {
                    DisclosureGroup("Migration history and queued tabs", isExpanded: $showHistory) { history }
                }
                Divider()
                HStack {
                    Text("\(selectedSpaces.count) spaces selected · \(newCount) new items · \(reviewCount) need review")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Review Import…") { confirming = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedSpaces.isEmpty || store.arcRestoreRunning || loading)
                }
            } else if loading {
                ProgressView("Reading Arc’s saved sidebar…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Choose your Arc sidebar", systemImage: "tray.and.arrow.down", description: Text("Read the local Arc file or choose a saved StorableSidebar.json. Previewing makes no changes."))
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
        }
        .padding(20)
        .frame(width: 1060, height: 740)
        .task { refresh() }
        .onChange(of: showOptions) { _, expanded in if expanded { showHistory = false } }
        .onChange(of: showHistory) { _, expanded in if expanded { showOptions = false } }
        .sheet(isPresented: $confirming) { confirmation }
        .confirmationDialog("Undo this import?", isPresented: Binding(get: { undoing != nil }, set: { if !$0 { undoing = nil } })) {
            Button("Remove unchanged imported items", role: .destructive) {
                guard let id = undoing else { return }
                do { try store.undoArcImport(id); error = nil } catch { self.error = error.localizedDescription }
                undoing = nil
            }
        } message: {
            Text("Edited items and containers with later content are kept. Safari tabs stay open. Pending restorations from this import are cancelled.")
        }
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import from Arc").font(.title2.bold())
                Text("Preview your spaces, folders, Favorites, and tabs before importing.").foregroundStyle(.secondary)
                Text(sourceURL.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(sourceURL.path)
            }
            Spacer()
            Button("Choose File…") { chooseFile() }.disabled(loading)
            Button("Refresh Arc") { refresh() }.disabled(loading)
        }
    }
    private func summary(_ snapshot: ArcImportSnapshot) -> some View {
        HStack(spacing: 22) {
            statistic("Spaces", snapshot.spaces.count)
            statistic("Folders", snapshot.folders)
            statistic("Pins", snapshot.count(.pin))
            statistic("Favorites", snapshot.count(.favorite))
            statistic("Open tabs", snapshot.count(.tab))
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text(store.arcMigration.receipts.contains { $0.snapshotHash == snapshot.hash && !$0.undone } ? "Import recorded · review history" : "Preview only · nothing imported").font(.callout.bold()).foregroundStyle(.blue)
                if let date = snapshot.savedAt { Text("Arc saved \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
            }
        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
    private func statistic(_ title: String, _ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(count.formatted()).font(.title3.bold()); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    private func spacesList(_ snapshot: ArcImportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Arc Spaces").font(.headline)
                Spacer()
                Button("All") { selectedSpaces = Set(snapshot.spaces.map(\.id)) }.buttonStyle(.link)
                Button("None") { selectedSpaces.removeAll() }.buttonStyle(.link)
            }.padding(.horizontal, 6)
            List(selection: $focusedSpace) {
                Label("Favorites (\(snapshot.count(.favorite)))", systemImage: "star.fill").tag("favorites")
                ForEach(snapshot.spaces) { space in
                    HStack(spacing: 8) {
                        Toggle(isOn: Binding(get: { selectedSpaces.contains(space.id) }, set: { value in
                            if value { selectedSpaces.insert(space.id) } else { selectedSpaces.remove(space.id) }
                        })) { EmptyView() }.toggleStyle(.checkbox).labelsHidden()
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(space.originalIcon ?? "◉") \(space.name)").lineLimit(1)
                            Text("\(space.profileID) · \(snapshot.entries.filter { $0.spaceID == space.id && $0.kind != .folder }.count) items")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(space.id)
                }
            }.listStyle(.sidebar)
        }
    }
    private func detail(_ snapshot: ArcImportSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(snapshot.spaces.first(where: { $0.id == focusedSpace })?.name ?? (focusedSpace == "favorites" ? "Favorites by Arc profile" : "All Arc items")).font(.headline)
                Spacer()
                TextField("Search titles or URLs", text: $query).textFieldStyle(.roundedBorder).frame(width: 240)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleEntries) { entry in
                        ArcPreviewRow(entry: entry, disposition: store.arcDisposition(entry))
                    }
                }
            }.background(.background, in: RoundedRectangle(cornerRadius: 6))
            Text("\(visibleEntries.count) records shown. Repeated URLs remain separate tabs. Pins load only when you open them.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.leading, 10)
    }
    private func options(_ snapshot: ArcImportSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Include Favorites for the selected Arc profiles", isOn: $includeFavorites)
                Toggle("Restore open tabs after importing", isOn: $restoreNow)
                Text("Open tabs are saved in a resumable queue either way. Choose a regular Safari window for each source profile to restore them. This does not transfer logins or create Safari profiles.")
                    .font(.caption).foregroundStyle(.secondary)
                destinationPickers(profiles: selectedProfiles)
                if safariWindows.isEmpty {
                    Text("No migration-ready Safari window is connected. Turn Side Tabs off and on in Safari’s Extensions settings after updating; queued tabs can stay saved until then.").font(.caption).foregroundStyle(.orange)
                }
                ForEach(Array(snapshot.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                let attention = snapshot.entries.filter { $0.issue != nil }
                if !attention.isEmpty {
                    Text("\(attention.count) items require manual handling. They remain listed in the preview and receipt.").font(.caption).foregroundStyle(.orange)
                    ForEach(attention) { entry in
                        Text("\(entry.title): \(entry.issue ?? "")").font(.caption).textSelection(.enabled)
                    }
                }
                Text("Emoji icons are preserved and space colors use the closest supported match. The original Arc data is retained locally with the import backup.").font(.caption).foregroundStyle(.secondary)
            }.padding(.top, 6)
        }.frame(maxHeight: 155)
    }
    private func destinationPickers(profiles: [String]) -> some View {
        VStack(alignment: .leading) {
            ForEach(profiles, id: \.self) { profile in
                Picker("\(profile) → Safari", selection: Binding<ArcImportDestination?>(get: { destinations[profile] }, set: { destinations[profile] = $0 })) {
                    Text("Save tabs for later").tag(ArcImportDestination?.none)
                    ForEach(safariWindows, id: \.0) { destination, label in
                        Text(label).tag(Optional(destination))
                    }
                }
            }
        }
    }
    private var history: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !store.arcMigration.tabs.isEmpty {
                    Text("\(store.arcPendingTabs.count) queued · \(store.arcMigration.tabs.filter { $0.status == .restored }.count) restored · \(store.arcMigration.tabs.filter { $0.status == .attention }.count) need attention").font(.callout)
                    destinationPickers(profiles: Array(Set(store.arcPendingTabs.map(\.profileID))).sorted())
                    HStack {
                        Button(store.arcRestoreRunning ? "Pause restoration" : "Resume queued tabs") {
                            if store.arcRestoreRunning { store.pauseArcRestore() } else { store.restoreArcTabs(destinations: destinations) }
                        }.disabled(store.arcPendingTabs.isEmpty)
                        if let message = store.arcRestoreMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
                    }
                    ForEach(store.arcMigration.tabs.filter { $0.status == .attention || $0.status == .sending }) { job in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(job.title): \(job.message ?? "Awaiting a confirmed Safari result; resuming checks the same request.")").font(.caption).foregroundStyle(.orange)
                            HStack {
                                Text(job.url).font(.caption).lineLimit(1).textSelection(.enabled)
                                Button("Copy Link") { store.copyLink(job.url) }
                                Button("Mark Handled") {
                                    do { try store.markArcTabHandled(job.id) } catch { self.error = error.localizedDescription }
                                }.disabled(store.arcRestoreRunning)
                            }
                        }
                    }
                }
                ForEach(store.arcMigration.receipts.reversed()) { receipt in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(receipt.date.formatted()) · \(receipt.added) added · \(receipt.retained) already imported\(receipt.undone ? " · undone" : "")").font(.callout)
                            Spacer()
                            Button("Show Receipt") { NSWorkspace.shared.open(URL(fileURLWithPath: receipt.backupPath)) }
                            Button("Undo…") { undoing = receipt.id }.disabled(receipt.undone || store.arcRestoreRunning)
                        }
                        Text("\(receipt.conflicts.count) conflicts kept unchanged · \(receipt.attention.count) items require manual handling").font(.caption).foregroundStyle(.secondary)
                        ForEach(Array(receipt.conflicts.enumerated()), id: \.offset) { _, conflict in Text(conflict).font(.caption) }
                    }
                }
            }.padding(.top, 6)
        }.frame(maxHeight: 160)
    }
    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Ready to import from Arc?").font(.title2.bold())
            Text("Add \(newCount) new items from \(selectedSpaces.count) spaces. Existing sidebar content stays in place. Previously imported items are matched by Arc ID; conflicts are kept for review.")
            Text("Pins are saved without opening their pages. \(eligibleEntries.filter { $0.kind == .tab && $0.issue == nil }.count) open tabs will be queued\(restoreNow ? " and restored where you chose a Safari window" : " for later restoration").")
            if reviewCount > 0 { Text("\(reviewCount) items need review and will not be overwritten or automatically opened.").foregroundStyle(.orange) }
            Text("A local backup and original Arc snapshot are saved before applying changes.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Back to Preview") { confirming = false }
                Button("Import Selected Spaces") { applyImport() }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 550)
    }
    private func refresh() {
        loading = true; error = nil
        do {
            let value = try ArcImportReader.read(sourceURL)
            snapshot = value; selectedSpaces = Set(value.spaces.map(\.id))
            focusedSpace = value.spaces.first?.id
        } catch { self.error = error.localizedDescription; snapshot = nil }
        loading = false
    }
    private func chooseFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        panel.message = "Choose Arc’s StorableSidebar.json or a saved copy. The source will not be modified."
        if panel.runModal() == .OK, let url = panel.url { sourceURL = url; refresh() }
    }
    private func applyImport() {
        guard let snapshot else { return }
        do {
            _ = try store.importArc(snapshot, selectedSpaces: selectedSpaces, includeFavorites: includeFavorites)
            confirming = false; error = nil; showHistory = true
            if restoreNow { store.restoreArcTabs(destinations: destinations) }
        } catch { self.error = error.localizedDescription; confirming = false }
    }
}

private struct ArcPreviewRow: View {
    let entry: ArcImportEntry
    let disposition: ArcImportDisposition
    private var icon: String {
        switch entry.kind {
        case .folder: "folder.fill"
        case .favorite: "star.fill"
        case .pin: "pin.fill"
        case .tab: "doc"
        case .unsupported: "exclamationmark.triangle"
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(entry.issue == nil ? Color.secondary : .orange).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).lineLimit(1).help(entry.title)
                if let url = entry.url { Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(url).textSelection(.enabled) }
                if let issue = entry.issue { Text(issue).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                if entry.kind == .favorite { Text("Arc profile: \(entry.profileID)").font(.caption).foregroundStyle(.secondary) }
                if entry.splitID != nil { Text("From an Arc split view").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 4)
            Text(disposition.rawValue).font(.caption).foregroundStyle(disposition == .conflict || disposition == .attention ? .orange : .secondary)
        }
        .padding(.vertical, 7).padding(.trailing, 10).padding(.leading, CGFloat(min(entry.depth, 8)) * 14 + 8)
        Divider()
    }
}
