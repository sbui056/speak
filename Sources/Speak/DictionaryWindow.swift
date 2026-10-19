import AppKit
import SpeakCore
import SwiftUI

/// The dictionary editor, in its own window.
@MainActor
final class DictionaryWindowController {
    private var window: NSWindow?
    private let dictionary: DictionaryModel
    private let history: HistoryModel
    private let tab = DictionaryTab()

    init(dictionary: DictionaryModel, history: HistoryModel) {
        self.dictionary = dictionary
        self.history = history
    }

    func show(_ which: DictionaryTab.Which = .dictionary) {
        tab.selected = which
        if window == nil {
            let root = DictionaryTabs(dictionary: dictionary, history: history, tab: tab)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Speak Dictionary"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window.setContentSize(NSSize(width: 420, height: 440))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

/// Which tab the window shows, so the menu's History… can open it on History.
@MainActor @Observable
final class DictionaryTab {
    enum Which: Hashable { case dictionary, history }
    var selected = Which.dictionary
}

/// Terms, plus History while history is on.
private struct DictionaryTabs: View {
    let dictionary: DictionaryModel
    let history: HistoryModel
    @Bindable var tab: DictionaryTab

    var body: some View {
        if history.isOn {
            TabView(selection: $tab.selected) {
                DictionaryView(model: dictionary).tabItem { Text("Dictionary") }.tag(DictionaryTab.Which.dictionary)
                HistoryView(model: history).tabItem { Text("History") }.tag(DictionaryTab.Which.history)
            }
        } else {
            DictionaryView(model: dictionary)
        }
    }
}

/// Recent dictations, newest first: Copy or Delete each, or Delete all.
private struct HistoryView: View {
    let model: HistoryModel
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.showCorruptNotice {
                Notice(text: "The saved history couldn't be read, so it was set aside and a new one started.") {
                    model.showCorruptNotice = false
                }
            }
            if model.saveFailed {
                Text("Couldn't save history. Entries last until Speak quits.").font(.callout)
            }
            if model.entries.isEmpty {
                Spacer()
                Text("Your dictations will appear here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(model.entries) { entry in
                    HistoryRow(entry: entry, model: model)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                HStack {
                    Text("\(model.entries.count) of \(Constants.historyMax)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete all…") { confirmDelete = true }
                }
                .confirmationDialog("Delete all \(model.entries.count) entries?", isPresented: $confirmDelete) {
                    Button("Delete all", role: .destructive) { model.deleteAll() }
                }
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 320)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let model: HistoryModel

    private var time: String { entry.date.formatted(.dateTime.month().day().hour().minute()) }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(time).font(.caption).foregroundStyle(.secondary)
                Text(entry.text).textSelection(.enabled)
            }
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy dictation from \(time)")
            Button {
                model.delete(entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete dictation from \(time)")
        }
    }
}

/// Terms and replacement pairs, one at a time, under shared notices.
private struct DictionaryView: View {
    enum Section: Hashable { case terms, replacements }

    let model: DictionaryModel
    @State private var section = Section.terms

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.showCorruptNotice {
                Notice(text: "The saved dictionary couldn't be read, so it was set aside and a new one started.") {
                    model.showCorruptNotice = false
                }
            }
            if model.saveFailed {
                Notice(text: "Couldn't save the dictionary. Changes last until Speak quits.")
            }
            Picker("Show", selection: $section) {
                Text("Terms").tag(Section.terms)
                Text("Replacements").tag(Section.replacements)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch section {
            case .terms: TermsSection(model: model)
            case .replacements: ReplacementsSection(model: model)
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 320)
    }
}

private struct TermsSection: View {
    let model: DictionaryModel
    @State private var newTerm = ""
    @State private var addError: TermError?
    @State private var packStatus: String?
    @FocusState private var addFocused: Bool

    private var packAdded: Bool { model.dictionary.pack != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Add a name or term", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .focused($addFocused)
                    .onSubmit(add)
                    .onChange(of: newTerm) { addError = nil }
                Button("Add", action: add)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let addError {
                Label(addError.message, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
            }

            if model.terms.isEmpty {
                Spacer()
                Text("Add names or terms Speak gets wrong — like 'Kubernetes' or a colleague's name.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(Array(model.terms.enumerated()), id: \.element) { index, term in
                        TermRow(term: term, index: index, model: model)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            HStack {
                if !model.terms.isEmpty {
                    Text("\(model.terms.count) of \(Constants.dictMaxEntries)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let packStatus {
                    Text(packStatus).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if packAdded {
                    Button("Remove tech terms") {
                        _ = model.removePack()
                        packStatus = nil
                    }
                } else {
                    Button("Add common tech terms") {
                        let result = model.addPack(terms: TechTerms.terms, pairs: TechTerms.pairs)
                        packStatus = result.skipped == 0 ? "Added \(result.added) terms"
                            : "Added \(result.added), \(result.skipped) skipped"
                    }
                }
            }
        }
        .onAppear { addFocused = true }
    }

    private func add() {
        do {
            try model.add(newTerm)
            newTerm = ""
        } catch {
            addError = error
        }
    }
}

/// "When Speak hears this, write that" pairs.
private struct ReplacementsSection: View {
    let model: DictionaryModel
    @State private var heard = ""
    @State private var write = ""
    @State private var addError: TermError?
    @FocusState private var heardFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Heard", text: $heard)
                    .textFieldStyle(.roundedBorder)
                    .focused($heardFocused)
                Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Write", text: $write)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty
                        || write.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .onChange(of: heard) { addError = nil }
            .onChange(of: write) { addError = nil }
            if let addError {
                Label(addError.message, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.red)
            }

            if model.pairs.isEmpty {
                Spacer()
                Text("Add what Speak hears and what it should write — like 'pool request' → 'pull request'.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(Array(model.pairs.enumerated()), id: \.element.heard) { index, pair in
                        PairRow(pair: pair, index: index, model: model)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                Text("\(model.pairs.count) of \(Constants.pairsMax)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear { heardFocused = true }
    }

    private func add() {
        do {
            try model.addPair(heard: heard, write: write)
            heard = ""
            write = ""
            heardFocused = true
        } catch {
            addError = error
        }
    }
}

/// A pair that edits in place: Return saves, Esc reverts.
private struct PairRow: View {
    let pair: ReplacementPair
    let index: Int
    let model: DictionaryModel
    @State private var heard = ""
    @State private var write = ""
    @State private var editing = false
    @State private var error: TermError?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if editing {
                    TextField("Heard", text: $heard)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(save)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Write", text: $write)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Save") { save() }
                        .buttonStyle(.borderless)
                } else {
                    Text("\(pair.heard) → \(pair.write)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture(count: 2) { startEditing() }
                    Button("Edit") { startEditing() }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit \(pair.heard)")
                }
                Button {
                    model.removePair(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(pair.heard)")
            }
            .onExitCommand { if editing { editing = false; error = nil } }
            .onChange(of: heard) { error = nil }
            .onChange(of: write) { error = nil }
            if let error {
                Text(error.message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func startEditing() {
        heard = pair.heard
        write = pair.write
        editing = true
        focused = true
    }

    private func save() {
        do {
            try model.replacePair(at: index, heard: heard, write: write)
            editing = false
        } catch {
            self.error = error
        }
    }
}

/// A warning banner above the list, with OK when it can be dismissed.
private struct Notice: View {
    let text: String
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
            Text(text).font(.callout)
            Spacer()
            if let dismiss { Button("OK", action: dismiss) }
        }
        .padding(8)
        .background(.yellow.opacity(0.15), in: .rect(cornerRadius: 6))
    }
}

/// A term that edits in place: Return saves, Esc reverts.
private struct TermRow: View {
    let term: String
    let index: Int
    let model: DictionaryModel
    @State private var draft = ""
    @State private var editing = false
    @State private var error: TermError?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                if editing {
                    TextField("Term", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        .onSubmit(save)
                        .onExitCommand(perform: cancelEditing)
                        .onChange(of: draft) { error = nil }
                } else {
                    Text(term)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                        .onTapGesture(count: 2) { startEditing() }
                }
                if editing {
                    Button("Save") { save() }
                        .buttonStyle(.borderless)
                } else {
                    Button("Edit") { startEditing() }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit \(term)")
                }
                Button {
                    model.remove(at: index)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete \(term)")
            }
            if let error {
                Text(error.message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func startEditing() {
        draft = term
        editing = true
        focused = true
    }

    private func cancelEditing() {
        editing = false
        error = nil
    }

    private func save() {
        do {
            try model.replace(at: index, with: draft)
            editing = false
        } catch {
            self.error = error
        }
    }
}
