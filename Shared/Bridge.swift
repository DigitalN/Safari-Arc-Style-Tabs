import Foundation

/// Names shared by the app and its Safari extension.
///
/// The extension's native handler runs sandboxed in its own process, so it reaches the
/// app over a CFMessagePort. A sandboxed process may only look up Mach ports whose name
/// starts with one of its app groups, hence the port name is built from the app group.
enum SideTabsBridge {
    static let appBundleIdentifier = "com.digitaln.sidetabs"
    static let extensionBundleIdentifier = "com.digitaln.sidetabs.extension"

    /// `$(TeamIdentifierPrefix)com.digitaln.sidetabs`, expanded at build time into Info.plist.
    static var appGroup: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "SideTabsAppGroup") as? String
        return value?.isEmpty == false ? value! : appBundleIdentifier
    }

    static var portName: String { appGroup + ".bridge" }

    /// Message id used for every request; the payload is JSON.
    static let messageID: Int32 = 1
}
