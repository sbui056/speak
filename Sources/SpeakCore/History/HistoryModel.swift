import Foundation
import Observation

/// One dictation as it was delivered. Text only; no audio, app, or window.
public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let date: Date
    public let text: String
}

/// Recent dictations, kept only when the user turns history on (off by default).
/// Newest first, at most C-HISTORY, saved after every change.
@MainActor
@Observable
public final class HistoryModel {
    /// Stops recording when off; entries already saved stay until deleted.
    public var isOn: Bool
    public private(set) var entries: [HistoryEntry]
    /// The saved file couldn't be read and was set aside; shown once.
    public var showCorruptNotice: Bool
    /// The last save failed; entries last until Speak quits.
    public private(set) var saveFailed = false
    @ObservationIgnored private let files: AppFiles
    @ObservationIgnored private let now: () -> Date

    public init(files: AppFiles, isOn: Bool, now: @escaping () -> Date = Date.init) {
        self.files = files
        self.isOn = isOn
        self.now = now
        let loaded = files.loadHistory()
        entries = loaded.value.reversed()
        showCorruptNotice = loaded.wasCorrupt
    }

    public func record(_ text: String) {
        guard isOn, !text.isEmpty else { return }
        entries.insert(HistoryEntry(id: UUID(), date: now(), text: text), at: 0)
        if entries.count > Constants.historyMax { entries.removeLast(entries.count - Constants.historyMax) }
        save()
    }

    public func delete(_ id: HistoryEntry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Removes every entry, the file, and any copies set aside as corrupt.
    public func deleteAll() {
        entries = []
        files.deleteHistory()
        showCorruptNotice = false
        saveFailed = false
    }

    private func save() {
        do {
            try files.saveHistory(entries.reversed())
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }
}
