import AppKit
import SpeakCore
import SwiftUI

/// The dictionary editor, in its own window.
@MainActor
final class DictionaryWindowController {
    private var window: NSWindow?
    private let dictionary: DictionaryModel

    init(dictionary: DictionaryModel) {
        self.dictionary = dictionary
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: DictionaryView(model: dictionary)))
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
