import Foundation

// [TEMP-tabSwitchMethod] Delete this file, and every other line that carries the marker above,
// once the measurements for issue 18 have decided which way of switching tabs stays.

/// How a click on a tab in the sidebar switches Safari's tab. Read at every switch, so both ways
/// can be measured on one build without restarting anything:
///
///     defaults write com.digitaln.sidetabs tabSwitchMethod push           # the extension's command only
///     defaults write com.digitaln.sidetabs tabSwitchMethod accessibility  # press the tab bar's button; the extension as fallback
///     defaults delete com.digitaln.sidetabs tabSwitchMethod               # back to the default (accessibility)
enum TabSwitchMethod: String {
    case push
    case accessibility

    static var current: TabSwitchMethod {
        UserDefaults.standard.string(forKey: "tabSwitchMethod").flatMap(TabSwitchMethod.init(rawValue:)) ?? .accessibility
    }
}
