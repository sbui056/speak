import Foundation
@testable import SpeakCore

// MARK: Reducer tests

/// The first session the reducer issues.
let s1 = SessionID(1)

func ms(_ n: Int) -> KeyTime { .milliseconds(n) }

/// Runs events through the reducer, returning the final state and the effects of the last event.
func run(_ events: [SessionEvent], from start: SessionState = SessionState()) -> (SessionState, [Effect]) {
    var state = start
    var last: [Effect] = []
    for event in events { (state, last) = reduce(state, event) }
    return (state, last)
}

// MARK: Storage tests

/// A fresh, not-yet-created directory in the temporary folder. Callers remove it when done.
func tempFiles() -> AppFiles {
    AppFiles(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("speak-tests-\(UUID().uuidString)", isDirectory: true))
}
