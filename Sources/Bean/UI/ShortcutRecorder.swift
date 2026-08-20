import SwiftUI
import AppKit
import Carbon.HIToolbox

// A small shortcut recorder. While recording it installs a LOCAL key-down event
// monitor so the next key combination is captured by Bean (and consumed, so it
// doesn't trigger any normal action). Escape cancels.
//
// The captured GlobalShortcut is handed to `onCapture`; the parent validates and
// applies it (and shows any error), so this view stays purely about capture.
struct ShortcutRecorderButton: View {
    /// Called with the captured combo. Parent validates + applies.
    let onCapture: (GlobalShortcut) -> Void
    /// Called when the user presses Escape to cancel.
    var onCancel: () -> Void = {}

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(isRecording ? "Press new shortcut… (⎋ to cancel)" : "Record Shortcut")
                .frame(minWidth: 180)
        }
        .onDisappear(perform: stopRecording)
    }

    private func toggle() {
        if isRecording { stopRecording() } else { startRecording() }
    }

    private func startRecording() {
        isRecording = true
        // Local monitor: only fires while Bean's window is key (it is — the user
        // just clicked this button). Returning nil consumes the event so it
        // doesn't perform a normal action.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(_ event: NSEvent) {
        // Escape cancels recording without changing anything.
        if Int(event.keyCode) == kVK_Escape {
            stopRecording()
            onCancel()
            return
        }
        let shortcut = GlobalShortcut.from(event: event)
        stopRecording()
        onCapture(shortcut)
    }
}
