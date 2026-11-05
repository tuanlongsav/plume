import Carbon.HIToolbox

/// One system-wide shortcut, through Carbon's RegisterEventHotKey.
///
/// Carbon, not an NSEvent global monitor: a monitor needs the Accessibility
/// permission and only observes the key (the frontmost app still gets it),
/// while a registered hot key needs no permission and is consumed. Nothing
/// polls: the handler runs only when the key is pressed.
final class GlobalHotKey {
    private static let signature: OSType = 0x504C_554D   // 'PLUM'
    private static var nextID: UInt32 = 1

    private let id: UInt32
    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    /// nil when the system refuses the combination (another app holds it).
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        id = Self.nextID
        Self.nextID += 1
        self.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Unretained: `deinit` removes the handler before `self` is gone, so
        // the pointer never outlives the object.
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            // Every handler on the application target sees every hot key.
            guard status == noErr, pressed.signature == GlobalHotKey.signature,
                  pressed.id == hotKey.id
            else { return OSStatus(eventNotHandledErr) }
            hotKey.action()
            return noErr
        }, 1, &spec, me, &handler)
        guard installed == noErr else { return nil }

        let registered = RegisterEventHotKey(keyCode, modifiers,
                                             EventHotKeyID(signature: Self.signature, id: id),
                                             GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr, hotKey != nil else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return nil
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// ⌃⌥⌘ in Carbon's modifier bits.
    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)
}
