import SwiftUI

func spaceColor(_ theme: String) -> Color {
    switch theme {
    case "purple": .purple
    case "pink": .pink
    case "orange": .orange
    case "green": .green
    case "gray": .gray
    default: .blue
    }
}

struct SpaceIcon: View {
    let space: BrowserSpace
    var size: CGFloat = 14
    var body: some View {
        Group {
            if let emoji = space.emoji.flatMap(BrowserSpace.normalizedEmoji) {
                Text(emoji).font(.system(size: size + 2))
            } else {
                Image(systemName: space.icon)
                    .font(.system(size: size))
                    .foregroundStyle(spaceColor(space.theme))
            }
        }
        .accessibilityHidden(true)
    }
}

struct FavoritesSection: View {
    @Environment(TabStore.self) private var store
    var body: some View {
        VStack(alignment: .leading, spacing: SidebarDrag.rowSpacing) {
            SectionHeader(title: "Favorites") { EmptyView() }
            ForEach(store.favorites) { bookmark in
                BookmarkRow(bookmark: bookmark, draggable: false)
            }
        }
    }
}

struct SpaceHeader: View {
    @Environment(TabStore.self) private var store
    @State private var editing: BrowserSpace?
    @State private var confirmingDelete = false

    var body: some View {
        HStack {
            Label { Text(store.selectedSpace.name) } icon: { SpaceIcon(space: store.selectedSpace, size: 13) }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(spaceColor(store.selectedSpace.theme))
                .lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Button("Edit Space…") { editing = store.selectedSpace }
                Button("Move Space Left") { store.reorderSelectedSpace(direction: -1) }
                Button("Move Space Right") { store.reorderSelectedSpace(direction: 1) }
                Divider()
                Button("Delete Space…") { confirmingDelete = true }
                    .disabled(store.spaces.count < 2)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Space Options")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .popover(item: $editing) { space in
            SpaceEditor(space: space) { edited in
                store.updateSpace(edited)
                editing = nil
            } onCancel: { editing = nil }
        }
        .confirmationDialog("Delete \(store.selectedSpace.name)?", isPresented: $confirmingDelete) {
            Button("Move Items to \(store.spaces.first { $0.id != store.selectedSpace.id }?.name ?? "Another Space") and Delete Space") {
                store.deleteSpace(store.selectedSpace.id)
            }
        } message: {
            Text("Tabs and pinned sites will move to the first remaining space. Safari tabs stay open.")
        }
    }
}

struct SpaceSwitcher: View {
    @Environment(TabStore.self) private var store
    @State private var editing: BrowserSpace?
    var body: some View {
        VStack(spacing: 6) {
            Divider()
            HStack(spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 4) {
                            ForEach(store.spaces) { space in
                                Button { store.selectSpace(space.id) } label: {
                                    SpaceIcon(space: space)
                                        .frame(width: 28, height: 28)
                                        .foregroundStyle(spaceColor(space.theme))
                                        .background(RoundedRectangle(cornerRadius: 7).fill(spaceColor(space.theme).opacity(space.id == store.selectedSpace.id ? 0.22 : 0)))
                                }
                                .buttonStyle(.plain)
                                .help(space.name)
                                .accessibilityLabel(space.name)
                                .accessibilityAddTraits(space.id == store.selectedSpace.id ? .isSelected : [])
                                .contextMenu {
                                    Button("Edit Space…") { editing = space }
                                }
                                .id(space.id)
                            }
                        }
                    }
                    // Keep the strip implicit even when macOS is set to always show scrollbars.
                    .scrollIndicators(.never)
                    .frame(height: 30)
                    .onAppear {
                        DispatchQueue.main.async { proxy.scrollTo(store.selectedSpace.id, anchor: .center) }
                    }
                    .onChange(of: store.selectedSpace.id) { _, id in
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                Button { editing = store.createSpace() } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("New Space")
                .accessibilityLabel("New Space")
            }
            .background(SpaceSwitcherScrollRegion())
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .popover(item: $editing) { space in
            SpaceEditor(space: space) { edited in
                store.updateSpace(edited)
                editing = nil
            } onCancel: { editing = nil }
        }
    }
}

private struct SpaceEditor: View {
    @Environment(TabStore.self) private var store
    @State var space: BrowserSpace
    @FocusState private var emojiFocused: Bool
    let onSave: (BrowserSpace) -> Void
    let onCancel: () -> Void

    private var canSave: Bool {
        !space.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (space.emoji == nil || space.emoji.flatMap(BrowserSpace.normalizedEmoji) != nil)
    }
    private func save() {
        guard canSave else { return }
        var edited = space
        edited.emoji = edited.emoji.flatMap(BrowserSpace.normalizedEmoji)
        onSave(edited)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Space").font(.headline)
            TextField("Space Name", text: $space.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            Picker("Icon style", selection: Binding(get: { space.emoji != nil }, set: { space.emoji = $0 ? "🌐" : nil })) {
                Text("Symbol").tag(false)
                Text("Emoji").tag(true)
            }
            .pickerStyle(.segmented)
            if space.emoji != nil {
                HStack {
                    TextField("Emoji", text: Binding(get: { space.emoji ?? "" }, set: { space.emoji = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .focused($emojiFocused)
                        .onSubmit(save)
                        .accessibilityLabel("Space emoji")
                    Button("Choose Emoji…") {
                        emojiFocused = true
                        DispatchQueue.main.async { NSApp.orderFrontCharacterPalette(nil) }
                    }
                }
                Text(space.emoji.flatMap(BrowserSpace.normalizedEmoji) != nil ? "Type or paste any single emoji." : "Choose one emoji to save.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Icon", selection: $space.icon) {
                    ForEach(BrowserSpace.icons, id: \.self) { icon in
                        Label(icon.replacingOccurrences(of: ".fill", with: ""), systemImage: icon).tag(icon)
                    }
                }
            }
            Picker("Theme", selection: $space.theme) {
                ForEach(BrowserSpace.themes, id: \.self) { theme in
                    Text(theme.capitalized).tag(theme)
                }
            }
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(16)
        .frame(width: 250)
        .onAppear {
            store.isEditingSpace = true
            store.onRenameStateChanged?(true)
        }
        .onDisappear {
            store.isEditingSpace = false
            store.onRenameStateChanged?(false)
        }
    }
}
