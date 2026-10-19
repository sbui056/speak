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

struct KeepGuardTests {
    private func check(_ literal: String, _ cleaned: String, terms: [String] = [], unknown: Set<String> = [],
                       language: String = "en") -> KeepFailure? {
        keepGuard(literal: literal, cleaned: cleaned, terms: terms, unknownWords: unknown, language: language)
    }

    // MARK: Accepted

    @Test(arguments: [
        ("The meaning notes are in the share folder.", "The meeting notes are in the shared folder."),
        ("I highlighted the actual items for the team.", "I highlighted the action items for the team."),
        ("It was the retry logic whenever a quest timed out.", "It was the retry logic whenever a request timed out."),
        ("Look at the pool request I sent.", "Look at the pull request I sent."),
        ("The cash wasn't the problem at all.", "The cache wasn't the problem at all."),
        ("It was the really try logic hammering the server.", "It was the retry logic hammering the server."),
        ("I pushed the fix to man.", "I pushed the fix to main."),
        ("CI should be clean in a few minutes.", "CI should be green in a few minutes."),
        ("Okay, remind me it's called the landlord tomorrow.", "Remind me to call the landlord tomorrow."),
    ])
    func soundAlikeSwapsAreRejected(_ literal: String, _ cleaned: String) {
        // User, 2026-10-18: Polished leaves mishearings to Literal, so any sound-alike swap is unrequested.
        #expect(check(literal, cleaned) == .soundAlike)
    }

    @Test(arguments: [
        ("Um, so I think we should, uh, ship it.", "I think we should ship it."),
        ("I'm gonna send it later.", "I'm going to send it later."),
        ("The results is ready.", "The results are ready."),
        ("I don't think so.", "I do not think so."),
        ("Let's do a follow up next week.", "Let's do a follow-up next week."),
        ("We need two more days.", "We need 2 more days."),
        ("we need twenty five chairs", "We need 25 chairs."),
        ("meet at two thirty pm", "Meet at 2:30 PM."),
        ("send the report to sarah", "Send the report to Sarah."),
        ("please review the swift UI change", "Please review the SwiftUI change."),
    ])
    func cleanupPasses(_ literal: String, _ cleaned: String) {
        #expect(check(literal, cleaned) == nil)
    }

    @Test func inflectedTermStillCountsAsKept() {
        #expect(check("the script deploy to staging every night", "The script deploys to staging every night.",
                      terms: ["deploy", "staging"]) == nil)
        #expect(check("Pages is slow today.", "Page is slow today.", terms: ["Pages"]) == .lostProtected)
        #expect(check("open a pull request", "Open pull requests.", terms: ["pull request"]) == nil)
    }

    @Test func dictionaryTermThatStaysPasses() {
        #expect(check("run kubectl apply on staging", "Run kubectl apply on staging.", terms: ["kubectl"]) == nil)
    }

    // MARK: Rejected

    @Test func changedWeekdayIsRejected() {
        #expect(check("Can we do Tuesday instead of Monday?", "Can we do Thursday instead of Monday?") == .lostProtected)
    }

    @Test func changedNumberIsRejected() {
        #expect(check("We need 3 more days.", "We need 4 more days.") == .lostProtected)
        #expect(check("We need three more days.", "We need 4 more days.") == .lostProtected)
    }

    @Test func addedNumberIsRejected() {
        #expect(check("I want to go to the store.", "I want two go to the store.") == .addedProtected)
        #expect(check("Talk to you soon.", "Talk 2 you soon.") == .addedProtected)
    }

    @Test func droppedNegationIsRejected() {
        #expect(check("I did not send the invoice.", "I did send the invoice.") == .negation)
        #expect(check("I don't want the update.", "I do want the update.") == .negation)
        #expect(check("We never ship on Fridays.", "We ship on Fridays.") == .negation)
    }

    @Test func changedNameIsRejected() {
        #expect(check("Please ask Sarah's team first.", "Please ask Sara's team first.") == .lostProtected)
    }

    @Test func flattenedAcronymIsRejected() {
        #expect(check("The API is down again.", "The app is down again.") == .lostProtected)
    }

    @Test func droppedTermIsRejected() {
        #expect(check("open a ticket in jira today", "Open a ticket in gyro today.", terms: ["jira"]) == .lostProtected)
    }

    @Test func changedUnknownWordIsRejected() {
        #expect(check("run kubectl apply now", "Run cuddle apply now.", unknown: ["kubectl"]) == .lostProtected)
    }

    @Test func unrelatedWordIsRejected() {
        #expect(check("The meeting is at noon.", "The party is at noon.") == .unrelated)
    }

    @Test func addedContentIsRejected() {
        #expect(check("Send the file.", "Send the file to legal.") == .unrelated)
    }

    @Test func evenOneSoundAlikeSwapIsRejected() {
        #expect(check("The cash and the pool and the man are fine", "The cache and the pull and the main are fine")
            == .soundAlike)
        #expect(check("The cash is fine today and every day after", "The cache is fine today and every day after")
            == .soundAlike)
    }

    // Review of the first keep guard: meaning changes that passed.
    @Test(arguments: [
        ("I want the blue one.", "I want one."),
        ("Delete the old staging branch.", "Delete the branch."),
        ("Only invite managers.", "Invite managers."),
        ("We meet last Friday.", "We meet this Friday."),
        ("Turn off the alarm.", "Turn on the alarm."),
        ("Ship it without the tests.", "Ship it with the tests."),
        ("Send it to him.", "Send it to her."),
        ("Bring cats and dogs.", "Bring cats or dogs."),
        ("You must sign it.", "You might sign it."),
        ("Increase the budget now.", "Decrease the budget now."),
        ("Please merge the branch.", "Please purge the branch."),
        ("We accept the terms.", "We except the terms."),
        ("Mark will review it.", "Mike will review it."),
        ("The first item is ready.", "The second item is ready."),
        ("Lunch at noon.", "Lunch at 1 PM."),
        ("Ask Dr. Smith about it.", "Ask Dr. Smyth about it."),
        ("It takes two to four days.", "It takes 24 days."),
        ("Invite two or three people.", "Invite 23 people."),
        ("for the second time", "For two times."),
        ("the first two weeks are busy", "The 12 weeks are busy."),
    ])
    func meaningChangesAreRejected(_ literal: String, _ cleaned: String) {
        #expect(check(literal, cleaned) != nil)
    }

    @Test func moreNegationWordsCount() {
        #expect(check("I have nothing to add.", "I have something to add.") == .negation)
        #expect(check("Nobody approved it.", "Somebody approved it.") == .negation)
    }

    @Test(arguments: [
        ("Oh, one more thing.", "One more thing."),
        ("He is late again.", "He's late again."),
        ("What is the plan?", "What's the plan?"),
        ("They will be there.", "They'll be there."),
        ("we need two thousand five hundred units", "We need 2,500 units."),
        ("I tried I tried restarting it", "I tried restarting it."),
        ("The first item is ready.", "The 1st item is ready."),
        ("the twenty first of June works", "The 21st of June works."),
        ("let's do a one on one tomorrow", "Let's do a 1:1 tomorrow."),
        ("lunch at noon on Friday", "Lunch at 12 PM on Friday."),
        ("it takes two to four days", "It takes 2-4 days."),
        ("we need two thousand five hundred chairs", "We need 2,500 chairs."),
        ("Ask Dr. Smith about it.", "Ask Dr. Smith about it"),
    ])
    func everydayCleanupsPass(_ literal: String, _ cleaned: String) {
        #expect(check(literal, cleaned) == nil)
    }

    // MARK: Other languages

    @Test func otherLanguagesKeepOnlyLanguageNeutralFacts() {
        #expect(check("euh je pense qu'on peut livrer 3 écrans", "Je pense que nous pouvons livrer 3 écrans.",
                      language: "fr") == nil)
        #expect(check("on livre 3 écrans", "On livre 4 écrans.", language: "fr") == .lostProtected)
        #expect(check("déployer sur kubectl", "Déployer sur kube.", terms: ["kubectl"], language: "fr") == .lostProtected)
    }
}

struct RewriteKeepGuardTests {
    @Test func polishedReplyThatBreaksAFactFallsBack() {
        #expect(checkRewrite("<cleaned>Can we do Thursday instead?</cleaned>", literal: "can we do tuesday instead",
                             mode: .polished, terms: []) == .failure(.keep(.lostProtected)))
        #expect(validateRewrite("<cleaned>Can we do Thursday instead?</cleaned>", literal: "can we do tuesday instead",
                                mode: .polished, terms: []) == nil)
    }

    @Test func polishedReplyThatSwapsASoundAlikeFallsBack() {
        #expect(checkRewrite("<cleaned>The cache wasn't the problem.</cleaned>", literal: "the cash wasn't the problem",
                             mode: .polished, terms: []) == .failure(.keep(.soundAlike)))
    }

    @Test func rejectionsHaveLoggableNames() {
        #expect(RewriteRejection.keep(.negation).name == "keep.negation")
        #expect(RewriteRejection.ratio.name == "ratio")
    }
}
