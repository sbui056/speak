import Foundation
import Testing
@testable import SpeakCore

struct AppFilesTests {
    @Test func roundTripsWithPrivatePermissions() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        var d = TermDictionary()
        try d.add("Siobhan")
        try files.saveDictionary(d)

        let loaded = files.loadDictionary()
        #expect(loaded.value == d)
        #expect(!loaded.wasCorrupt)
        let fm = FileManager.default
        let dirMode = try fm.attributesOfItem(atPath: files.directory.path)[.posixPermissions] as? Int
        let fileMode = try fm.attributesOfItem(atPath: files.directory.appendingPathComponent("dictionary.json").path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
        #expect(fileMode == 0o600)
        #expect(try files.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func missingFileStartsEmpty() {
        let loaded = tempFiles().loadDictionary()
        #expect(loaded.value.terms.isEmpty)
        #expect(!loaded.wasCorrupt)
    }

    @Test func corruptFileIsMovedAsideAndAppStartsEmpty() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: files.directory.appendingPathComponent("dictionary.json"))

        let loaded = files.loadDictionary()
        #expect(loaded.value.terms.isEmpty)
        #expect(loaded.wasCorrupt)
        let names = try FileManager.default.contentsOfDirectory(atPath: files.directory.path)
        #expect(names.count == 1)
        #expect(names[0].hasPrefix("dictionary.json.corrupt-"))
    }

    @Test func invalidTermsInFileAreDropped() throws {
        let files = tempFiles()
        defer { try? FileManager.default.removeItem(at: files.directory) }
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        try Data(#"{"version":1,"terms":["Siobhan","<x>","siobhan"]}"#.utf8)
            .write(to: files.directory.appendingPathComponent("dictionary.json"))
        #expect(files.loadDictionary().value.terms == ["Siobhan"])
    }
}
