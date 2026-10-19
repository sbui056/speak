import SpeakCore
import SwiftUI

/// Recent dictations, newest first: Copy or Delete each, or Delete all.
struct HistoryView: View {
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
