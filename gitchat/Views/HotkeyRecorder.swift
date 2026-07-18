import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Click-to-record shortcut field. While recording, a local key monitor
/// swallows keystrokes until a valid combo lands (Esc cancels, Delete clears).
struct HotkeyRecorder: View {
    @Binding var hotkey: HotkeyConfig?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { recording ? stopRecording() : startRecording() }) {
                Text(recording ? "Type a shortcut…" : (hotkey?.display ?? "Record Shortcut"))
                    .font(.system(size: 12, weight: hotkey != nil && !recording ? .semibold : .regular))
                    .frame(minWidth: 110)
            }
            if hotkey != nil, !recording {
                Button(action: { hotkey = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil   // swallow keystrokes while recording
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let bareModifiers = event.modifierFlags
            .intersection([.command, .option, .control, .shift]).isEmpty
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording()
        case kVK_Delete where bareModifiers:
            hotkey = nil
            stopRecording()
        default:
            if let config = HotkeyConfig(event: event) {
                hotkey = config
                stopRecording()
            }
            // else keep listening — a global combo needs ⌘/⌥/⌃ (or an F-key)
        }
    }
}
