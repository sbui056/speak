import Testing
@testable import SpeakCore

struct PhoneticTests {
    @Test(arguments: [("pool", "pull"), ("cash", "cache"), ("really try", "retry"), ("meaning", "meeting"),
                      ("actual", "action"), ("quest", "request"), ("man", "main"), ("clean", "green"),
                      ("it's called", "to call"), ("share", "shared")])
    func realMishearingsSoundAlike(_ heard: String, _ meant: String) {
        #expect(soundsAlike(heard.split(separator: " ").map(String.init), meant.split(separator: " ").map(String.init)))
    }

    @Test(arguments: [("Thursday", "Tuesday"), ("call", "email"), ("cat", "bat"), ("now", "not"),
                      ("meeting", "party"), ("deploy", "delete"), ("staging", "production"),
                      // "tough" keys as "T": one letter is too little to call anything alike.
                      ("try", "tough")])
    func differentWordsDoNot(_ heard: String, _ meant: String) {
        #expect(!soundsAlike([heard], [meant]))
    }

    @Test func keysFollowThePrototype() {
        #expect(phoneticKey("cash") == "KX")
        #expect(phoneticKey("meeting") == "MTNK")
        #expect(phoneticKey("Thursday") == "0RST")
        #expect(phoneticKey("kubectl") == "KPKTL")
    }
}
