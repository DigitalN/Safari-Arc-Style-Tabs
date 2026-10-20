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
                Button("Delete Space…") { store.requestDeleteSpace(store.selectedSpace.id) }
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
    }
}

struct SpaceSwitcher: View {
    @Environment(TabStore.self) private var store
    @State private var editing: BrowserSpace?
    @State private var drag: SpaceIconDrag?
    @GestureState private var gestureActive = false
    @State private var dragCancelled = false
    @State private var contentX: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    private static let stripCoordinates = "spaceIconStrip"

    private var orderedSpaces: [BrowserSpace] {
        guard let drag else { return store.spaces }
        let byID = Dictionary(uniqueKeysWithValues: store.spaces.map { ($0.id, $0) })
        return drag.order.compactMap { byID[$0] }
    }

    var body: some View {
        VStack(spacing: 6) {
            Divider()
            HStack(spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: SpaceIconDrag.spacing) {
                            ForEach(orderedSpaces) { space in
                                Button { store.selectSpace(space.id) } label: {
                                    icon(space)
                                        .opacity(drag?.id == space.id ? 0 : 1)
                                        .overlay {
                                            if drag?.id == space.id {
                                                RoundedRectangle(cornerRadius: 7)
                                                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .highPriorityGesture(
                                    DragGesture(minimumDistance: 5, coordinateSpace: .named(Self.stripCoordinates))
                                        .updating($gestureActive) { _, active, _ in active = true }
                                        .onChanged { value in
                                            guard !dragCancelled, store.renaming == nil, !store.isEditingSpace else { return }
                                            if drag == nil {
                                                drag = SpaceIconDrag(id: space.id, order: store.spaces.map(\.id), start: value.startLocation, contentX: contentX)
                                            }
                                            updateDrag(at: value.location)
                                        }
                                        .onEnded { value in
                                            defer { drag = nil; dragCancelled = false }
                                            guard !dragCancelled else { return }
                                            updateDrag(at: value.location)
                                            if let drag, drag.canDrop(in: viewportWidth),
                                               let index = drag.order.firstIndex(of: drag.id) {
                                                store.moveSpace(drag.id, to: index)
                                            }
                                        }
                                )
                                .help("\(space.name) — drag to reorder")
                                .accessibilityLabel(space.name)
                                .accessibilityAddTraits(space.id == store.selectedSpace.id ? .isSelected : [])
                                .accessibilityAction(named: "Move Space Left") { move(space, direction: -1) }
                                .accessibilityAction(named: "Move Space Right") { move(space, direction: 1) }
                                .contextMenu {
                                    Button("Edit Space…") { editing = space }
                                    Button("Move Space Left") { move(space, direction: -1) }
                                        .disabled(store.spaces.first?.id == space.id)
                                    Button("Move Space Right") { move(space, direction: 1) }
                                        .disabled(store.spaces.last?.id == space.id)
                                }
                                .id(space.id)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { geometry in
                            geometry.frame(in: .named(Self.stripCoordinates)).minX
                        } action: { x in
                            contentX = x
                            if let point = drag?.location { updateDrag(at: point) }
                        }
                        .animation(.snappy(duration: 0.16), value: drag?.order)
                    }
                    // Keep the strip implicit even when macOS always shows scrollbars.
                    .scrollIndicators(.never)
                    .frame(height: 30)
                    .coordinateSpace(name: Self.stripCoordinates)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
                    .overlay(alignment: .topLeading) {
                        if let drag, let space = store.spaces.first(where: { $0.id == drag.id }) {
                            icon(space)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
                                .shadow(radius: 3, y: 1)
                                .offset(x: min(max(drag.ghostX, 0), max(viewportWidth - SpaceIconDrag.size, 0)))
                                .allowsHitTesting(false)
                        }
                    }
                    .task(id: drag?.id) {
                        while !Task.isCancelled, let current = drag {
                            if let target = current.scrollTarget(width: viewportWidth, contentX: contentX) {
                                proxy.scrollTo(target.id, anchor: target.towardEnd ? .trailing : .leading)
                            }
                            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        }
                    }
                    .onAppear {
                        DispatchQueue.main.async { proxy.scrollTo(store.selectedSpace.id, anchor: .center) }
                    }
                    .onChange(of: store.selectedSpace.id) { _, id in
                        cancelDrag()
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
        .onChange(of: gestureActive) { _, active in
            if !active { drag = nil; dragCancelled = false }
        }
        .onChange(of: store.spaces.map(\.id)) { _, _ in cancelDrag() }
        .onDisappear { cancelDrag() }
        .onExitCommand { cancelDrag() }
        .popover(item: $editing) { space in
            SpaceEditor(space: space) { edited in
                store.updateSpace(edited)
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    private func icon(_ space: BrowserSpace) -> some View {
        SpaceIcon(space: space)
            .frame(width: SpaceIconDrag.size, height: SpaceIconDrag.size)
            .background(RoundedRectangle(cornerRadius: 7).fill(spaceColor(space.theme).opacity(space.id == store.selectedSpace.id ? 0.22 : 0)))
    }

    private func cancelDrag() {
        drag = nil
        dragCancelled = gestureActive
    }

    private func updateDrag(at point: CGPoint) {
        drag?.update(at: point, contentX: contentX)
    }

    private func move(_ space: BrowserSpace, direction: Int) {
        guard let index = store.spaces.firstIndex(where: { $0.id == space.id }) else { return }
        store.moveSpace(space.id, to: index + direction)
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
        }
        .onDisappear {
            store.isEditingSpace = false
        }
    }
}
