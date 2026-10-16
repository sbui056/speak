import AppKit
import SpeakCore
import SwiftUI

/// Shows a rewrite for approval. The panel takes keyboard focus without
/// activating Speak, so the user's app stays frontmost and its text field
/// keeps focus for the paste that follows.
@MainActor
final class PreviewPanelController {
    private let panel: PreviewWindow
    private let controller: SessionController

    init(controller: SessionController) {
        self.controller = controller
        panel = PreviewWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
                              styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                              backing: .buffered, defer: true)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Stays open when the user clicks elsewhere; there's no timeout.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.onCancel = { [weak controller] in controller?.choose(.cancel) }
        controller.onPreviewChange = { [weak self] in self?.update($0) }
    }

    private func update(_ content: PreviewContent?) {
        guard let content else {
            panel.orderOut(nil)
            return
        }
        let host = NSHostingView(rootView: PreviewView(content: content) { [weak controller] in controller?.choose($0) })
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        position()
        panel.makeKeyAndOrderFront(nil)
        Log.rewrite.info("preview shown key=\(self.panel.isKeyWindow, privacy: .public)")
    }

    /// Upper middle of the screen with the pointer, where it's hard to miss.
    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let frame = screen.visibleFrame
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62 - size.height / 2))
    }
}

private final class PreviewWindow: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Esc, even when a text field inside has focus.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct PreviewView: View {
    let content: PreviewContent
    let choose: (PreviewAction) -> Void
    @State private var editing = false
    @State private var draft = ""
    @State private var showOriginal = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("\(content.mode.title) — review before inserting", systemImage: "text.badge.checkmark")
                .font(.headline)

            if editing {
                TextField("Text to insert", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...12)
                    .focused($editorFocused)
                    .onSubmit { choose(.insert(draft)) }
                    .accessibilityLabel("Edit the text to insert")
                Text("Return inserts. Option-Return adds a line break.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    Text(diffText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Rewritten text")
                .accessibilityValue(content.rewrite)
                legend
            }

            DisclosureGroup("Original transcript", isExpanded: $showOriginal) {
                Text(content.literal)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }

            HStack {
                Button("Cancel") { choose(.cancel) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if editing {
                    Button("Insert edited") { choose(.insert(draft)) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Copy") { choose(.copy(content.rewrite)) }
                        .keyboardShortcut("c", modifiers: .command)
                    Button("Edit") {
                        draft = content.rewrite
                        editing = true
                        editorFocused = true
                    }
                    Button("Insert literal") { choose(.insertLiteral) }
                        .keyboardShortcut(.return, modifiers: .option)
                        .help("Insert the original transcript (⌥⏎)")
                    Button("Insert") { choose(.insert(content.rewrite)) }
                        .keyboardShortcut(.defaultAction)
                        .help("Insert the rewrite (⏎)")
                }
            }
        }
        .padding(16)
        .frame(width: 520)
    }

    /// Insertions underlined on green, deletions struck through on red, so the
    /// marks still read without color.
    private var diffText: AttributedString {
        var result = AttributedString()
        for segment in content.diff {
            switch segment {
            case .same(let text):
                result += AttributedString(text)
            case .inserted(let text):
                var run = AttributedString(text)
                run.underlineStyle = .single
                run.backgroundColor = .green.opacity(0.22)
                result += run
            case .deleted(let text):
                var run = AttributedString(text)
                run.strikethroughStyle = .single
                run.backgroundColor = .red.opacity(0.18)
                run.foregroundColor = .secondary
                result += run
            }
        }
        return result
    }

    private var legend: some View {
        HStack(spacing: 12) {
            Text("added").underline().padding(.horizontal, 3).background(.green.opacity(0.22))
            Text("removed").strikethrough().padding(.horizontal, 3).background(.red.opacity(0.18))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}
