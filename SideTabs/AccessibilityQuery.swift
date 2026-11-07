@preconcurrency import ApplicationServices

/// Accessibility calls with a short messaging timeout, for use from one queue.
///
/// Every Accessibility call waits for the other app's main thread to answer, and gives up after
/// six seconds by default. That is far too long for anything the sidebar is waiting on, so each
/// call here sets a shorter timeout first. `timedOut` says whether any call since the last
/// `clearTimedOut()` couldn't get an answer, which is how a caller tells "Safari didn't answer"
/// from "there is nothing there".
///
/// Not thread safe: each instance belongs to one queue (hence the `@unchecked`).
nonisolated final class AXQuery: @unchecked Sendable {
    let timeout: Float
    private(set) var timedOut = false

    init(timeout: TimeInterval) {
        self.timeout = Float(timeout)
    }

    func clearTimedOut() {
        timedOut = false
    }

    private func note(_ error: AXError) {
        if error == .cannotComplete {
            timedOut = true
        }
    }

    func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            note(error)
            return nil
        }
        return value
    }

    /// Several attributes in one round trip. An attribute the element doesn't have comes back nil.
    func copyMultiple(_ element: AXUIElement, _ attributes: [String]) -> [CFTypeRef?]? {
        AXUIElementSetMessagingTimeout(element, timeout)
        var values: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, attributes as CFArray, [], &values)
        guard error == .success, let values else {
            note(error)
            return nil
        }
        return (values as [AnyObject]).map { value in
            // A value that couldn't be read is an AXValue of the "error" kind, not a missing item.
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                return nil
            }
            return value
        }
    }

    func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        (copy(element, attribute) as? [AXUIElement]) ?? []
    }

    func value(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = copy(element, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }

    func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        copy(element, attribute) as? Bool
    }

    /// The actions the element can perform (`AXPress`, ...). Empty if it has none or can't be read.
    func actionNames(_ element: AXUIElement) -> [String] {
        AXUIElementSetMessagingTimeout(element, timeout)
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        guard error == .success else {
            note(error)
            return []
        }
        return (names as? [String]) ?? []
    }

    @discardableResult
    func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetMessagingTimeout(element, timeout)
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value)
        note(error)
        return error
    }

    @discardableResult
    func perform(_ element: AXUIElement, _ action: String) -> AXError {
        AXUIElementSetMessagingTimeout(element, timeout)
        let error = AXUIElementPerformAction(element, action as CFString)
        note(error)
        return error
    }
}
