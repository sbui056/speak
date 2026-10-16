/// What the Accessibility API said about the focused element.
public enum FocusQuery: Equatable, Sendable {
    /// Readable. `sameAsAtPress` is nil when the element wasn't readable at press.
    case element(sameAsAtPress: Bool?)
    /// The query succeeded and nothing is focused.
    case none
    /// The query failed, which Electron apps do routinely.
    case error
}

/// Everything the delivery rules look at, gathered at the moment of pasting.
public struct DeliverySnapshot: Equatable, Sendable {
    public var text: String
    public var accessibilityTrusted: Bool
    /// System secure input is on, or the focused element is a secure text field.
    public var secureInput: Bool
    /// The app frontmost at press; nil if Speak itself was, since Speak is never a target.
    public var pressPID: Int32?
    public var frontmostPID: Int32?
    public var focus: FocusQuery
    /// Modifier keys were still down after the wait.
    public var modifiersHeld: Bool

    public init(text: String, accessibilityTrusted: Bool, secureInput: Bool, pressPID: Int32?,
                frontmostPID: Int32?, focus: FocusQuery, modifiersHeld: Bool) {
        self.text = text
        self.accessibilityTrusted = accessibilityTrusted
        self.secureInput = secureInput
        self.pressPID = pressPID
        self.frontmostPID = frontmostPID
        self.focus = focus
        self.modifiersHeld = modifiersHeld
    }
}

public enum DeliveryDecision: Equatable, Sendable {
    case nothing
    /// A pasteboard copy instead of a paste. Concealed keeps it out of clipboard history.
    case copy(reason: Messages, concealed: Bool)
    case paste
}

/// The insertion safety rules, in order. Paste only when every one passes;
/// otherwise copy and say why.
public func evaluateDelivery(_ s: DeliverySnapshot) -> DeliveryDecision {
    if s.text.allSatisfy(\.isWhitespace) { return .nothing }
    if !s.accessibilityTrusted { return .copy(reason: .accessibility, concealed: false) }
    if s.secureInput { return .copy(reason: .secure, concealed: true) }
    if s.pressPID == nil || s.frontmostPID != s.pressPID { return .copy(reason: .appChanged, concealed: false) }
    switch s.focus {
    case .none: return .copy(reason: .noField, concealed: false)
    case .element(sameAsAtPress: false): return .copy(reason: .focusChanged, concealed: false)
    case .element, .error: break // An unreadable focus doesn't block the paste.
    }
    if s.modifiersHeld { return .copy(reason: .modifiers, concealed: false) }
    return .paste
}
