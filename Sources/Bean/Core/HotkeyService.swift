import AppKit
import Carbon.HIToolbox

// Global hotkey registration, fully isolated so the rest of the app never
// touches Carbon. Supports MULTIPLE shortcuts (e.g. quick proofread + Bean
// menu), each identified by a small integer id, and can swap any of them at
// runtime while keeping the previous working shortcut if the new one fails.
//
// Carbon's RegisterEventHotKey is the only API that reliably delivers a
// system-wide hotkey to a background (.accessory) app. It needs no Accessibility
// permission to fire.
final class HotkeyService {

    enum HotkeyError: LocalizedError {
        case registrationFailed(OSStatus)
        var errorDescription: String? {
            switch self {
            case .registrationFailed(let status):
                return "The system rejected that shortcut — it may already be in use by another app (code \(status))."
            }
        }
    }

    // Stable slot ids for Bean's shortcuts.
    static let quickProofreadID: UInt32 = 1
    static let beanMenuID: UInt32 = 2

    private struct Slot {
        var ref: EventHotKeyRef?
        var shortcut: GlobalShortcut?
        var handler: () -> Void
    }

    private var slots: [UInt32: Slot] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private let signature: OSType = 0x4245414E // 'BEAN'

    // MARK: - Public API

    /// Registers (or replaces) the shortcut for `id`. If the new shortcut can't
    /// be registered, the previous one for that id is re-registered and the
    /// error is thrown.
    func set(_ shortcut: GlobalShortcut, id: UInt32, handler: @escaping () -> Void) throws {
        installEventHandlerIfNeeded()

        let previous = slots[id]
        if let previousRef = previous?.ref {
            UnregisterEventHotKey(previousRef)
        }

        do {
            let ref = try registerHotKey(shortcut, id: id)
            slots[id] = Slot(ref: ref, shortcut: shortcut, handler: handler)
        } catch {
            // Re-register the previous shortcut so that slot keeps working.
            if let previous, let prevShortcut = previous.shortcut,
               let restoredRef = try? registerHotKey(prevShortcut, id: id) {
                slots[id] = Slot(ref: restoredRef, shortcut: prevShortcut, handler: previous.handler)
            } else {
                slots[id] = nil
            }
            throw error
        }
    }

    func shortcut(for id: UInt32) -> GlobalShortcut? { slots[id]?.shortcut }

    func stop() {
        for slot in slots.values {
            if let ref = slot.ref { UnregisterEventHotKey(ref) }
        }
        slots.removeAll()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    // MARK: - Carbon plumbing (isolated)

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return OSStatus(eventNotHandledErr) }
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                service.slots[hotKeyID.id]?.handler()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }

    private func registerHotKey(_ shortcut: GlobalShortcut, id: UInt32) throws -> EventHotKeyRef {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            throw HotkeyError.registrationFailed(status)
        }
        return ref
    }

    deinit { stop() }
}
