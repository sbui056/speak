import AppKit
import SpeakCore
import SwiftUI

/// The dictionary editor, in its own window.
@MainActor
final class DictionaryWindowController {
    private var window: NSWindow?
    private let dictionary: DictionaryModel
    private let history: HistoryModel

    init(dictionary: DictionaryModel, history: HistoryModel) {
        self.dictionary = dictionary
        self.history = history
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: DictionaryTabs(dictionary: dictionary, history: history)))
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

/// Terms, plus History while history is on.
private struct DictionaryTabs: View {
    let dictionary: DictionaryModel
    let history: HistoryModel

    var body: some View {
        if history.isOn {
            TabView {
                DictionaryView(model: dictionary).tabItem { Text("Dictionary") }
                HistoryView(model: history).tabItem { Text("History") }
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
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle").accessibilityHidden(true)
                    Text("The saved history couldn't be read, so it was set aside and a new one started.")
                        .font(.callout)
                    Spacer()
                    Button("OK") { model.showCorruptNotice = false }
                }
                .padding(8)
                .background(.yellow.opacity(0.15), in: .rect(cornerRadius: 6))
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

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
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
            .accessibilityLabel("Copy")
            Button {
                model.delete(entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete")
        }
    }
}

private struct DictionaryView: View {
    let model: DictionaryModel
    @State private var newTerm = ""
    @State private var addError: TermError?
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.showCorruptNotice {
                notice("The saved dictionary couldn't be read, so it was set aside and a new one started.") {
                    model.showCorruptNotice = false
                }
            }
            if model.saveFailed {
                notice("Couldn't save the dictionary. Changes last until Speak quits.", dismiss: nil)
            }

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
                Text("\(model.terms.count) of \(Constants.dictMaxEntries)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 360, minHeight: 320)
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

    private func notice(_ text: String, dismiss: (() -> Void)?) -> some View {
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
