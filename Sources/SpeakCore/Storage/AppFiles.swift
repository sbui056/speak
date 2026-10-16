import Foundation

/// The app's own files: private to the user, kept out of backups, written
/// atomically. A file that can't be read is moved aside, never deleted, and the
/// app carries on empty.
public struct AppFiles: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Application Support/Speak`.
    public static var standard: AppFiles {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppFiles(directory: base.appendingPathComponent("Speak", isDirectory: true))
    }

    public struct Loaded<Value> {
        public let value: Value
        /// The file existed but was unreadable and has been moved aside.
        public let wasCorrupt: Bool
    }

    public func loadDictionary() -> Loaded<TermDictionary> {
        let url = directory.appendingPathComponent(Self.dictionaryFile)
        guard let data = try? Data(contentsOf: url) else { return Loaded(value: TermDictionary(), wasCorrupt: false) }
        do {
            let file = try JSONDecoder().decode(DictionaryFile.self, from: data)
            return Loaded(value: TermDictionary(validating: file.terms), wasCorrupt: false)
        } catch {
            moveAside(url)
            return Loaded(value: TermDictionary(), wasCorrupt: true)
        }
    }

    public func saveDictionary(_ dictionary: TermDictionary) throws {
        let data = try JSONEncoder().encode(DictionaryFile(version: 1, terms: dictionary.terms))
        try write(data, to: Self.dictionaryFile)
    }

    /// One JSON entry per line, oldest first. Any unreadable line sets the whole file aside.
    public func loadHistory() -> Loaded<[HistoryEntry]> {
        let url = directory.appendingPathComponent(Self.historyFile)
        guard let data = try? Data(contentsOf: url) else { return Loaded(value: [], wasCorrupt: false) }
        do {
            let decoder = JSONDecoder()
            let entries = try data.split(separator: UInt8(ascii: "\n"))
                .map { try decoder.decode(HistoryEntry.self, from: Data($0)) }
            return Loaded(value: entries, wasCorrupt: false)
        } catch {
            moveAside(url)
            return Loaded(value: [], wasCorrupt: true)
        }
    }

    public func saveHistory(_ entries: [HistoryEntry]) throws {
        let encoder = JSONEncoder()
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(UInt8(ascii: "\n"))
        }
        try write(data, to: Self.historyFile)
    }

    /// Removes the history file and every `history.jsonl.corrupt-*` copy.
    public func deleteHistory() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name == Self.historyFile || name.hasPrefix(Self.historyFile + ".corrupt-") {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Private

    static let dictionaryFile = "dictionary.json"
    static let historyFile = "history.jsonl"

    private struct DictionaryFile: Codable {
        var version: Int
        var terms: [String]
    }

    private func write(_ data: Data, to name: String) throws {
        try prepareDirectory()
        let url = directory.appendingPathComponent(name)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func prepareDirectory() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Also tightens a directory that already existed with looser permissions.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try dir.setResourceValues(values)
    }

    private func moveAside(_ url: URL) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        let target = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).corrupt-\(stamp)")
        try? FileManager.default.moveItem(at: url, to: target)
    }
}
