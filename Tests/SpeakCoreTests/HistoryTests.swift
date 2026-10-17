import Foundation
import Testing
@testable import SpeakCore

private func names(_ files: AppFiles) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: files.directory.path)) ?? []).sorted()
}

@MainActor
struct HistoryTests {
    @Test func offRecordsNothingAndWritesNoFile() {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let history = HistoryModel(files: files, isOn: false)
        history.record("Hello there")
        #expect(history.entries.isEmpty)
        #expect(names(files).isEmpty)
    }

    @Test func onRecordsNewestFirstAndSurvivesARelaunch() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var now = Date(timeIntervalSince1970: 1000)
        let history = HistoryModel(files: files, isOn: true, now: { now })
        history.record("first")
        now = Date(timeIntervalSince1970: 2000)
        history.record("second")
        #expect(history.entries.map(\.text) == ["second", "first"])
        #expect(history.entries.first?.date == Date(timeIntervalSince1970: 2000))

        let reloaded = HistoryModel(files: files, isOn: true)
        #expect(reloaded.entries == history.entries)
        let mode = try FileManager.default.attributesOfItem(
            atPath: files.directory.appendingPathComponent("history.jsonl").path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func keepsOnlyTheNewestEntries() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let history = HistoryModel(files: files, isOn: true)
        for i in 0...Constants.historyMax { history.record("entry \(i)") }
        #expect(history.entries.count == Constants.historyMax)
        #expect(history.entries.first?.text == "entry \(Constants.historyMax)")
        #expect(!history.entries.contains { $0.text == "entry 0" })
        let lines = try String(contentsOf: files.directory.appendingPathComponent("history.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == Constants.historyMax)
    }

    @Test func emptyTextIsNotRecorded() {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let history = HistoryModel(files: files, isOn: true)
        history.record("")
        #expect(history.entries.isEmpty)
    }

    @Test func deleteOneEntry() {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let history = HistoryModel(files: files, isOn: true)
        history.record("keep")
        history.record("drop")
        history.delete(history.entries[0].id)
        #expect(history.entries.map(\.text) == ["keep"])
        #expect(HistoryModel(files: files, isOn: true).entries.map(\.text) == ["keep"])
    }

    @Test func deleteAllAlsoRemovesCorruptCopies() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data("not json\n".utf8).write(to: files.directory.appendingPathComponent("history.jsonl"))
        let history = HistoryModel(files: files, isOn: true)
        history.record("new")
        try Data("{}".utf8).write(to: files.directory.appendingPathComponent("dictionary.json"))
        #expect(names(files).contains { $0.hasPrefix("history.jsonl.corrupt-") })

        history.deleteAll()
        #expect(history.entries.isEmpty)
        #expect(names(files) == ["dictionary.json"])
    }

    @Test func corruptFileIsMovedAsideAndHistoryStartsEmpty() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data("{\"broken\n".utf8).write(to: files.directory.appendingPathComponent("history.jsonl"))
        let history = HistoryModel(files: files, isOn: true)
        #expect(history.entries.isEmpty)
        #expect(history.showCorruptNotice)
        #expect(names(files).count == 1)
        #expect(names(files)[0].hasPrefix("history.jsonl.corrupt-"))
    }

    @Test func turningOffStopsRecordingButKeepsSavedEntries() {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        let history = HistoryModel(files: files, isOn: true)
        history.record("kept")
        history.isOn = false
        history.record("not kept")
        #expect(history.entries.map(\.text) == ["kept"])
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct HistoryHookTests {
    @Test func everyFinishedDeliveryIsReported() async {
        let h = Harness()
        var reported: [String] = []
        h.controller.onFinished = { reported.append($0) }
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.phase == .idle && h.env.pastes.count == 1 })
        #expect(reported == [Harness.fakeText])
    }

    @Test func copyFromThePreviewIsReportedAndCancelIsNot() async {
        let h = Harness()
        var reported: [String] = []
        h.controller.onFinished = { reported.append($0) }
        h.controller.send(.rewriteSettings(mode: .polished, preview: .whenChanged))
        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        h.controller.choose(.cancel)
        #expect(await eventually { h.phase == .idle })
        #expect(reported.isEmpty)

        await h.hold(for: .milliseconds(1500))
        #expect(await eventually { h.controller.preview != nil })
        h.controller.send(.preview(SessionID(99), .copy("Stale"))) // another session's panel: ignored
        h.controller.choose(.copy("Edited text"))
        #expect(await eventually { h.phase == .idle })
        #expect(reported == ["Edited text"])
    }
}
