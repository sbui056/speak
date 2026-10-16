import os

/// One logger per area. Only enums, numbers, and durations are ever marked
/// public; transcript text, app names, and window titles are never logged.
enum Log {
    private static let subsystem = "io.github.sbui056.speak"
    static let session = Logger(subsystem: subsystem, category: "session")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let stt = Logger(subsystem: subsystem, category: "stt")
    static let insert = Logger(subsystem: subsystem, category: "insert")
    static let perm = Logger(subsystem: subsystem, category: "perm")
}
