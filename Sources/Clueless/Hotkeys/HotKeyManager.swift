import Carbon.HIToolbox
import AppKit

/// 'CLUL' — hotkey signature. File-level because the Carbon event handler is
/// a C function pointer and cannot capture dynamic `Self`.
private let kCluelessHotKeySignature: OSType = 0x434C554C

/// Global hotkeys via the Carbon HotKey API. Unlike NSEvent global monitors,
/// these fire even when another app is fullscreen and require no
/// Accessibility permission.
final class HotKeyManager {
    private enum Action: UInt32 {
        case toggleOverlay = 1
        case sendScreenRequest = 2
    }

    private var handlers: [Action: @MainActor () -> Void] = [:]
    private var hotKeyRefs: [EventHotKeyRef?] = []
    private var eventHandlerRef: EventHandlerRef?

    func register(
        toggleOverlay: @escaping @MainActor () -> Void,
        sendScreenRequest: @escaping @MainActor () -> Void
    ) {
        handlers[.toggleOverlay] = toggleOverlay
        handlers[.sendScreenRequest] = sendScreenRequest

        installEventHandler()

        // ⌘\ — toggle overlay visibility
        registerHotKey(action: .toggleOverlay, keyCode: UInt32(kVK_ANSI_Backslash), modifiers: UInt32(cmdKey))

        // ⌘Return — capture the screen and ask for help, even with no draft.
        registerHotKey(action: .sendScreenRequest, keyCode: UInt32(kVK_Return), modifiers: UInt32(cmdKey))
    }

    private func registerHotKey(action: Action, keyCode: UInt32, modifiers: UInt32) {
        let hotKeyID = EventHotKeyID(signature: kCluelessHotKeySignature, id: action.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRefs.append(ref)
        } else {
            NSLog("Clueless: failed to register hotkey \(action.rawValue), status \(status)")
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData -> OSStatus in
                guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    eventRef,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard hotKeyID.signature == kCluelessHotKeySignature,
                      let action = Action(rawValue: hotKeyID.id),
                      let handler = manager.handlers[action] else {
                    return OSStatus(eventNotHandledErr)
                }

                Task { @MainActor in handler() }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        if status != noErr {
            NSLog("Clueless: failed to install hotkey event handler, status \(status)")
        }
    }

    deinit {
        for ref in hotKeyRefs {
            if let ref { UnregisterEventHotKey(ref) }
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}
