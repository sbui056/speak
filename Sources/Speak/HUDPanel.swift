import AppKit
import SpeakCore
import SwiftUI

/// A small floating panel at the bottom of the screen with the pointer. It never
/// becomes key or activates Speak, so typing keeps going to the user's app.
@MainActor
final class HUDPanelController {
    private let panel: NSPanel

    init(controller: SessionController, openSettings: @escaping () -> Void) {
        panel = HUDWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 96),
                          styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        let view = HUDView(controller: controller, openSettings: openSettings)
        let host = NSHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        // A direct callback rather than observation tracking: a re-subscription
        // chain that breaks once would leave the HUD hidden for good.
        controller.hud.onContentChange = { [weak self] in self?.update($0) }
    }

    private func update(_ content: HUDContent?) {
        guard content != nil else {
            panel.orderOut(nil)
            return
        }
        let wasVisible = panel.isVisible
        if !wasVisible { position() }
        panel.orderFrontRegardless()
        if !wasVisible {
            Log.session.info("hud shown visible=\(self.panel.isVisible, privacy: .public) activeSpace=\(self.panel.isOnActiveSpace, privacy: .public) occluded=\(!self.panel.occlusionState.contains(.visible), privacy: .public) y=\(Int(self.panel.frame.minY), privacy: .public)")
        }
    }

    /// Bottom-center of the screen that has the pointer.
    private func position() {
        guard let screen = NSScreen.withPointer else { return }
        let frame = screen.visibleFrame
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 72))
    }
}

extension NSScreen {
    /// The screen the pointer is on, where the user is looking.
    @MainActor static var withPointer: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }
}

private final class HUDWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct HUDView: View {
    let controller: SessionController
    let openSettings: () -> Void
    @State private var listeningSince = Date()

    var body: some View {
        Group {
            switch controller.hud.content {
            case .listening, .partial:
                listening
            case .processing, .rewriting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(controller.hud.content == .rewriting ? "Rewriting…" : "Transcribing…")
                }
            case .result(let message):
                Label(message.text, systemImage: message == .empty ? "questionmark.circle" : "checkmark.circle")
            case .error(let message):
                error(message)
            case nil:
                EmptyView()
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onHover { controller.hud.hover($0) }
        .onChange(of: isListening) { _, now in if now { listeningSince = Date() } }
    }

    private var isListening: Bool {
        switch controller.hud.content {
        case .listening, .partial: true
        default: false
        }
    }

    private var listening: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
                Text("Listening")
                TimelineView(.periodic(from: listeningSince, by: 1)) { context in
                    Text(elapsed(context.date)).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                LevelMeter(level: controller.level)
            }
            if case .partial(let text) = controller.hud.content {
                Text(text)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func error(_ message: Messages) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message.text, systemImage: "exclamationmark.triangle")
            HStack {
                if controller.lastTranscript != nil, message.isCopyFallback {
                    Button("Copy transcript") { Task { await controller.copyLast() } }
                }
                if message.needsSettings {
                    Button("Open Settings", action: openSettings)
                }
            }
            .controlSize(.small)
        }
    }

    private func elapsed(_ now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(listeningSince)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A simple bar on a decibel scale. With Reduce Motion it jumps instead of animating.
private struct LevelMeter: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Float { LevelMeterScale.fraction(rms: level) }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(.secondary).frame(width: 60 * CGFloat(fraction))
        }
        .frame(width: 60, height: 6)
        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: level)
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(fraction * 100)) percent")
    }
}

private extension Messages {
    /// The text was copied instead of typed.
    var isCopyFallback: Bool {
        switch self {
        case .accessibility, .secure, .appChanged, .noField, .focusChanged, .modifiers: true
        default: false
        }
    }

    var needsSettings: Bool {
        switch self {
        case .mic, .accessibility, .inputMonitoring, .modelUnavailable: true
        default: false
        }
    }
}
