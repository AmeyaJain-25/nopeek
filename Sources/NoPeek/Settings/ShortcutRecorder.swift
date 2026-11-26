import AppKit
import Carbon.HIToolbox
import NoPeekCore
import SwiftUI

/// Click, press a combo, done. Esc cancels, ⌫ clears.
/// Requires ⌃, ⌥ or ⌘ (or an F-key) so it can't collide with typing a secret word.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    var placeholder = "Record Shortcut"

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var hint: String?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(title)
                    .font(.system(.body, design: .rounded).weight(shortcut == nil || isRecording ? .regular : .semibold))
                    .frame(minWidth: 150)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)

            if shortcut != nil, !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear(perform: stop)
    }

    private var title: String {
        if isRecording { return "Press keys… (esc to cancel)" }
        return shortcut?.displayString ?? placeholder
    }

    private func toggle() {
        isRecording ? stop() : start()
    }

    private func start() {
        hint = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = ModifierKeys(event.modifierFlags)
            if Int(event.keyCode) == kVK_Escape, modifiers.isEmpty {
                stop()
                return nil
            }
            if Int(event.keyCode) == kVK_Delete, modifiers.isEmpty {
                shortcut = nil
                stop()
                return nil
            }
            guard !modifiers.isDisjoint(with: ModifierKeys.chordModifiers) || KeyLabel.isFunctionKey(event.keyCode) else {
                hint = "Add ⌃, ⌥ or ⌘"
                NSSound.beep()
                return nil
            }
            shortcut = KeyShortcut(keyCode: event.keyCode, modifiers: modifiers, keyLabel: KeyLabel.label(for: event))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
