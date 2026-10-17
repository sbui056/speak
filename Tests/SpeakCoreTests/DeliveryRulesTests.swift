import Testing
@testable import SpeakCore

/// A snapshot where every rule passes; each test breaks exactly one thing.
private func ok(_ change: (inout DeliverySnapshot) -> Void = { _ in }) -> DeliverySnapshot {
    var s = DeliverySnapshot(text: "Hello", accessibilityTrusted: true, secureInput: false, pressPID: 42,
                             frontmostPID: 42, focus: .element(sameAsAtPress: true), modifiersHeld: false)
    change(&s)
    return s
}

struct DeliveryRulesTests {
    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let snapshot: DeliverySnapshot
        let decision: DeliveryDecision
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        Row(name: "0 empty text does nothing", snapshot: ok { $0.text = " \n " }, decision: .nothing),
        Row(name: "1 no Accessibility copies", snapshot: ok { $0.accessibilityTrusted = false },
            decision: .copy(reason: .accessibility, concealed: false)),
        Row(name: "2 secure input copies concealed", snapshot: ok { $0.secureInput = true },
            decision: .copy(reason: .secure, concealed: true)),
        Row(name: "3 app changed copies", snapshot: ok { $0.frontmostPID = 7 },
            decision: .copy(reason: .appChanged, concealed: false)),
        Row(name: "3 Speak was frontmost at press", snapshot: ok { $0.pressPID = nil },
            decision: .copy(reason: .appChanged, concealed: false)),
        Row(name: "3 Speak's own test field pastes while Speak is frontmost",
            snapshot: ok { $0.ownField = true; $0.pressPID = nil; $0.frontmostPID = nil }, decision: .paste),
        Row(name: "3 own test field, but another app came forward",
            snapshot: ok { $0.ownField = true; $0.pressPID = nil; $0.frontmostPID = 7 },
            decision: .copy(reason: .appChanged, concealed: false)),
        Row(name: "4 own test field still needs a focused field",
            snapshot: ok { $0.ownField = true; $0.pressPID = nil; $0.frontmostPID = nil; $0.focus = .none },
            decision: .copy(reason: .noField, concealed: false)),
        Row(name: "4 no focused element copies", snapshot: ok { $0.focus = .none },
            decision: .copy(reason: .noField, concealed: false)),
        Row(name: "5 focus moved copies", snapshot: ok { $0.focus = .element(sameAsAtPress: false) },
            decision: .copy(reason: .focusChanged, concealed: false)),
        Row(name: "6 modifiers held copies", snapshot: ok { $0.modifiersHeld = true },
            decision: .copy(reason: .modifiers, concealed: false)),
        Row(name: "7 all clear pastes", snapshot: ok(), decision: .paste),
        Row(name: "7 AX query error still pastes", snapshot: ok { $0.focus = .error }, decision: .paste),
        Row(name: "7 focus unreadable at press still pastes", snapshot: ok { $0.focus = .element(sameAsAtPress: nil) },
            decision: .paste),
        Row(name: "order 0 before 1", snapshot: ok { $0.text = ""; $0.accessibilityTrusted = false }, decision: .nothing),
        Row(name: "order 1 before 2", snapshot: ok { $0.secureInput = true; $0.accessibilityTrusted = false },
            decision: .copy(reason: .accessibility, concealed: false)),
        Row(name: "order 2 before 3", snapshot: ok { $0.secureInput = true; $0.frontmostPID = 7 },
            decision: .copy(reason: .secure, concealed: true)),
        Row(name: "order 3 before 4", snapshot: ok { $0.frontmostPID = 7; $0.focus = .none },
            decision: .copy(reason: .appChanged, concealed: false)),
        Row(name: "order 4 before 6", snapshot: ok { $0.focus = .none; $0.modifiersHeld = true },
            decision: .copy(reason: .noField, concealed: false)),
        Row(name: "order 5 before 6", snapshot: ok { $0.focus = .element(sameAsAtPress: false); $0.modifiersHeld = true },
            decision: .copy(reason: .focusChanged, concealed: false)),
    ]

    @Test(arguments: rows)
    func rule(_ row: Row) {
        #expect(evaluateDelivery(row.snapshot) == row.decision)
    }
}
