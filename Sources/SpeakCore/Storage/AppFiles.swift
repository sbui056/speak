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
            return Loaded(value: TermDictionary(validating: file.terms, pairs: (file.pairs ?? []).compactMap(\.pair),
                                                pack: file.pack?.record), wasCorrupt: false)
        } catch {
            moveAside(url)
            return Loaded(value: TermDictionary(), wasCorrupt: true)
        }
    }

    public func saveDictionary(_ dictionary: TermDictionary) throws {
        let data = try JSONEncoder().encode(DictionaryFile(version: 2, terms: dictionary.terms,
                                                             pairs: dictionary.pairs.map { StoredPair(heard: $0.heard, write: $0.write) },
                                                             pack: dictionary.pack.map(StoredPack.init)))
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

    private static let dictionaryFile = "dictionary.json"
    private static let historyFile = "history.jsonl"

    /// Version 2 added `pairs`; version 1 files have none.
    private struct DictionaryFile: Codable {
        var version: Int
        var terms: [String]
        var pairs: [StoredPair]?
        var pack: StoredPack?
    }

    /// What the tech-term pack added. Unreadable means unknown: Remove is then
    /// not offered, and nothing else is lost.
    private struct StoredPack: Codable {
        var terms: [String]?
        var pairs: [StoredPair]?

        init(_ record: PackRecord) {
            terms = record.terms
            pairs = record.pairs.map { StoredPair(heard: $0.heard, write: $0.write) }
        }

        init(from decoder: any Decoder) {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            terms = try? fields?.decodeIfPresent([String].self, forKey: .terms)
            pairs = try? fields?.decodeIfPresent([StoredPair].self, forKey: .pairs)
        }

        var record: PackRecord? {
            guard terms != nil || pairs != nil else { return nil }
            return PackRecord(terms: terms ?? [], pairs: (pairs ?? []).compactMap(\.pair))
        }
    }

    /// A pair as stored. A malformed entry decodes as empty and is dropped, so
    /// one bad pair never sets aside the whole dictionary.
    private struct StoredPair: Codable {
        var heard: String?
        var write: String?

        init(heard: String, write: String) {
            self.heard = heard
            self.write = write
        }

        init(from decoder: any Decoder) {
            let fields = try? decoder.container(keyedBy: CodingKeys.self)
            heard = try? fields?.decodeIfPresent(String.self, forKey: .heard)
            write = try? fields?.decodeIfPresent(String.self, forKey: .write)
        }

        var pair: ReplacementPair? {
            guard let heard, let write else { return nil }
            return ReplacementPair(heard: heard, write: write)
        }
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
