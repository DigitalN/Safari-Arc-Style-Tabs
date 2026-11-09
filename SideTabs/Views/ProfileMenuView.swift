import AppKit

/// A view that opens a menu on mouse-down. Any left click on the sidebar brings Safari forward first
/// (SidebarPanel), but Safari coming forward as the menu opens would close it. So the panel leaves such
/// a click alone, and the view brings Safari forward once its menu has closed (`finishMenuMouseDown`),
/// unless a choice in the menu does that itself.
protocol OpensMenuOnMouseDown: NSView {}

/// The profile dropdown's clickable part (#39): opens a menu of every profile, in Safari's order, each
/// with its symbol (or letter) and name, the current one checked. Choosing one switches to it exactly as
/// its button would (`SafariProfiles.select`). Reads as a pop-up button: "Profile", and the profile's name.
final class ProfileMenuView: NSView, OpensMenuOnMouseDown {
    /// Shown where no profile is current: in a private window.
    static let noProfileSymbol = "person.2"

    var profiles: [SafariProfile] = []
    var currentID: UUID?
    /// The current profile's name, or nil in a private window.
    var name: String?
    /// Switches to a profile; says whether that started a switch.
    var select: ((SafariProfile) -> Bool)?

    override var isFlipped: Bool { true }

    /// The sidebar is almost never the key window; the first click has to open the menu.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        openMenu()
    }

    private func openMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let picker = Picker()
        for (index, profile) in profiles.enumerated() {
            let item = NSMenuItem(title: profile.name, action: #selector(Picker.pick(_:)), keyEquivalent: "")
            item.target = picker
            item.tag = index
            item.image = Self.image(for: profile)
            item.state = profile.id == currentID ? .on : .off
            menu.addItem(item)
        }
        if let current = menu.items.first(where: { $0.state == .on }) {
            // Like a pop-up button: the current profile over the dropdown.
            menu.popUp(positioning: current, at: NSPoint(x: 0, y: 0), in: self)
        } else {
            // No current profile: above the dropdown, which sits at the bottom of the sidebar.
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -menu.size.height - 4), in: self)
        }
        let chosen = picker.chosen.flatMap { profiles.indices.contains($0) ? profiles[$0] : nil }
        // A switch brings Safari forward itself; anything else (the current profile, or no choice) does
        // what the click would have done.
        let switching = chosen.map { select?($0) ?? false } ?? false
        if !switching {
            (window as? SidebarPanel)?.finishMenuMouseDown()
        }
    }

    /// Receives the menu's choice.
    private final class Picker: NSObject {
        var chosen: Int?

        @objc func pick(_ item: NSMenuItem) {
            chosen = item.tag
        }
    }

    /// The profile's symbol, or its first letter drawn as a template image the size of a symbol.
    private static func image(for profile: SafariProfile) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        if let symbol = profile.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            return image.withSymbolConfiguration(configuration) ?? image
        }
        let letter = profile.initial as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityLabel() -> String? { "Profile" }
    override func accessibilityValue() -> Any? { name ?? "Profiles" }

    override func accessibilityPerformPress() -> Bool {
        openMenu()
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        openMenu()
        return true
    }
}
