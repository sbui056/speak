import Testing
@testable import SpeakCore

struct LiteralCleanerTests {
    @Test(arguments: [
        ("  hello   world  ", "Hello world"),
        ("hello\n\tthere", "Hello there"),
        ("élan vital", "Élan vital"),
        ("Already fine.", "Already fine."),
        ("um so basically", "Um so basically"), // fillers stay: Literal never rewords
        ("\"hello\" she said", "\"Hello\" she said"),
        ("¿qué tal?", "¿Qué tal?"),
        ("42 apples", "42 apples"),
        ("   ", ""),
        ("", ""),
    ])
    func cleans(_ input: String, _ expected: String) {
        #expect(cleanLiteral(input) == expected)
    }
}
