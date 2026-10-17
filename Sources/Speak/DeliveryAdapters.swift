import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SpeakCore

/// The desktop as delivery sees it: frontmost app, focused element, keys, ⌘V.
final class SystemDeliveryEnvironment: DeliveryEnvironment {
    /// A hung app answers Accessibility queries slowly; don't wait on it for long.
    private static let axTimeout: Float = 0.5
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func frontmostPID() async -> Int32? {
        let pid = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        return pid == ownPID ? nil : pid
    }

    func frontmostBundleID() async -> String? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }

    func focusedElement() async -> FocusedElement {
        // Ask the frontmost app for its own focus. System-wide focus follows
        // Speak's menu or preview panel while they're open, which would hide the
        // user's text field from the delivery and undo checks.
        let root = await frontmostPID().map(AXUIElementCreateApplication) ?? AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, Self.axTimeout)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(root, kAXFocusedUIElementAttribute as CFString, &value)
        switch error {
        case .success:
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return .error }
            // Safe: the type ID was checked above.
            let element = unsafeDowncast(value, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(element, Self.axTimeout)
            return .element(ElementRef(AXBox(element)))
        case .noValue:
            return .none
        default:
            // Common in Electron apps; it doesn't block the paste.
            Log.insert.info("focused element query failed code=\(error.rawValue, privacy: .public)")
            return .error
        }
    }

    func isSameElement(_ a: ElementRef, _ b: ElementRef) async -> Bool {
        guard let a = a.raw as? AXBox, let b = b.raw as? AXBox else { return false }
        return CFEqual(a.element, b.element)
    }

    func accessibilityTrusted() async -> Bool {
        AXIsProcessTrusted()
    }

    func secureInputActive(_ focus: FocusedElement) async -> Bool {
        if IsSecureEventInputEnabled() { return true }
        guard case .element(let ref) = focus, let box = ref.raw as? AXBox else { return false }
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(box.element, kAXSubroleAttribute as CFString, &subrole) == .success else {
            return false
        }
        return (subrole as? String) == kAXSecureTextFieldSubrole
    }

    func modifiersDown() async -> Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        return !flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }

    func keyboardLayout() async -> [UInt16: Character] {
        // Text Input Sources must be used on the main thread.
        await MainActor.run { currentLayoutTable() }
    }

    func postPaste(keyCode: UInt16) async {
        postCommand(keyCode)
    }

    func postUndo(keyCode: UInt16) async {
        postCommand(keyCode)
    }

    func activate(pid: Int32) async {
        await MainActor.run { _ = NSRunningApplication(processIdentifier: pid)?.activate() }
    }

    func textLength(of element: ElementRef) async -> Int? {
        guard let box = element.raw as? AXBox else { return nil }
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(box.element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let n = count as? Int { return n }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(box.element, kAXValueAttribute as CFString, &value) == .success,
              let text = value as? String else { return nil }
        return (text as NSString).length
    }

    func selectionLength(of element: ElementRef) async -> Int? {
        guard let box = element.raw as? AXBox else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(box.element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // Safe: the type ID was checked above.
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return range.length
    }

    /// Posts ⌘ plus `keyCode`.
    private func postCommand(_ keyCode: UInt16) {
        // A private source, so the user's own held keys don't leak into the event.
        let source = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Holds a focused element so it can travel through SpeakCore as an opaque reference.
private final class AXBox {
    let element: AXUIElement
    init(_ element: AXUIElement) { self.element = element }
}

/// What each keycode types with no modifiers, in the current layout (or the
/// current ASCII-capable one if the active layout isn't, e.g. Japanese input).
@MainActor
private func currentLayoutTable() -> [UInt16: Character] {
    guard let layoutData = layoutData() else { return [:] }
    let bytes = CFDataGetBytePtr(layoutData)
    return bytes?.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
        var table: [UInt16: Character] = [:]
        for code in UInt16(0)..<128 {
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count,
                                        &length, &chars)
            if status == noErr, length == 1, let scalar = Unicode.Scalar(chars[0]) {
                table[code] = Character(scalar)
            }
        }
        return table
    } ?? [:]
}

@MainActor
private func layoutData() -> CFData? {
    for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
        guard let source = source?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
    }
    return nil
}

/// The general pasteboard.
final class SystemPasteboard: SpeakCore.Pasteboard {
    /// Conventions clipboard managers honor (nspasteboard.org).
    private static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    func changeCount() async -> Int {
        await MainActor.run { NSPasteboard.general.changeCount }
    }

    func snapshot() async -> PasteboardSnapshot? {
        await MainActor.run {
            var items: [[String: [UInt8]]] = []
            for item in NSPasteboard.general.pasteboardItems ?? [] {
                var types: [String: [UInt8]] = [:]
                for type in item.types {
                    // A promised or lazy type can't be read now; don't restore half a clipboard.
                    guard let data = item.data(forType: type) else {
                        Log.insert.info("clipboard has an unreadable item; restore skipped")
                        return nil
                    }
                    types[type.rawValue] = Array(data)
                }
                items.append(types)
            }
            return PasteboardSnapshot(items: items)
        }
    }

    @discardableResult
    func write(_ text: String, as kind: PasteboardWrite) async -> Int {
        await MainActor.run {
            let board = NSPasteboard.general
            board.clearContents()
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            if kind == .transient { item.setData(Data(), forType: Self.transient) }
            if kind != .normal { item.setData(Data(), forType: Self.concealed) }
            board.writeObjects([item])
            return board.changeCount
        }
    }

    func restore(_ snapshot: PasteboardSnapshot) async {
        await MainActor.run {
            let board = NSPasteboard.general
            board.clearContents()
            let items = snapshot.items.map { types in
                let item = NSPasteboardItem()
                for (type, bytes) in types { item.setData(Data(bytes), forType: .init(type)) }
                return item
            }
            board.writeObjects(items)
        }
    }
}
