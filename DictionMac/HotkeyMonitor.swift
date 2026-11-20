import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// The key you hold to dictate.
enum HotkeyTrigger: String, CaseIterable, Identifiable {
    case dictationKey   // the 🎤 key (F5 row), remapped to F18 by DictationKeyRemapper
    case fn             // Fn / Globe
    case rightOption
    case rightCommand

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dictationKey: return "🎤 Dictation key"
        case .fn: return "Fn / Globe"
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        }
    }

    var shortName: String {
        switch self {
        case .dictationKey: return "🎤"
        case .fn: return "Fn"
        case .rightOption: return "right ⌥"
        case .rightCommand: return "right ⌘"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .dictationKey: return Int64(kVK_F18)
        case .fn: return Int64(kVK_Function)
        case .rightOption: return Int64(kVK_RightOption)
        case .rightCommand: return Int64(kVK_RightCommand)
        }
    }

    var isModifier: Bool { self != .dictationKey }

    /// Whether the trigger modifier is down in a flagsChanged event.
    func isPressed(in flags: CGEventFlags) -> Bool {
        switch self {
        case .dictationKey: return false
        case .fn: return flags.contains(.maskSecondaryFn)
        // Device-dependent bits distinguish right-hand modifiers from left-hand ones.
        case .rightOption: return flags.rawValue & UInt64(NX_DEVICERALTKEYMASK) != 0
        case .rightCommand: return flags.rawValue & UInt64(NX_DEVICERCMDKEYMASK) != 0
        }
    }
}

/// Global keyboard hook (CGEventTap). Requires Accessibility permission.
///
/// Callbacks are delivered on the main thread.
final class HotkeyMonitor {
    var trigger: HotkeyTrigger = .dictationKey {
        didSet { isDown = false }
    }

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Another key was pressed while a modifier trigger was held (e.g. ⌥+letter):
    /// the user is typing a shortcut, not dictating.
    var onInterrupt: (() -> Void)?
    /// Escape pressed. Return true to swallow the key (we were recording).
    var onEscape: (() -> Bool)?
    /// The user typed or clicked (not counting our own synthetic paste).
    var onUserInput: (() -> Void)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isDown = false

    var isRunning: Bool { tap != nil }

    /// Returns false if the tap couldn't be created (Accessibility not granted yet).
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            return monitor.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.runLoopSource = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isDown = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables slow taps; turn ourselves back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == TextInserter.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }

        if type == .leftMouseDown || type == .rightMouseDown {
            onUserInput?()
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if trigger == .dictationKey, keyCode == trigger.keyCode, type == .keyDown || type == .keyUp {
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !isRepeat && !isDown {
                    isDown = true
                    onPress?()
                }
            } else if isDown {
                isDown = false
                onRelease?()
            }
            return nil // swallow: F18 should never reach other apps
        }

        if trigger.isModifier, type == .flagsChanged, keyCode == trigger.keyCode {
            let pressed = trigger.isPressed(in: event.flags)
            if pressed && !isDown {
                isDown = true
                onPress?()
            } else if !pressed && isDown {
                isDown = false
                onRelease?()
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            if keyCode == Int64(kVK_Escape), let onEscape, onEscape() {
                return nil
            }
            onUserInput?()
            if trigger.isModifier && isDown {
                isDown = false
                onInterrupt?()
            }
        }

        return Unmanaged.passUnretained(event)
    }
}
