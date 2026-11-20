import Foundation
import OSLog

/// Turns the MacBook's 🎤 dictation key into F18 so the app can see it.
///
/// macOS normally routes the dictation key (HID Consumer usage 0xCF, "Voice
/// Command") straight to Apple Dictation. `hidutil` user key mappings remap it
/// at the HID level, so we receive ordinary F18 key-down / key-up events.
/// Mappings don't survive a reboot, so this runs every time the app launches,
/// and is removed again when the app quits.
enum DictationKeyRemapper {
    private static let logger = Logger(subsystem: "com.dictionapp.mac", category: "remap")

    /// Consumer page 0x0C, usage 0xCF (Voice Command / Dictation)
    static let dictationKeyUsage: UInt64 = 0xC0000_00CF
    /// Keyboard page 0x07, usage 0x6D (F18)
    static let f18Usage: UInt64 = 0x7_0000_006D

    static func enable() {
        let json = """
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":\(dictationKeyUsage),"HIDKeyboardModifierMappingDst":\(f18Usage)}]}
        """
        run(["property", "--set", json])
    }

    static func disable() {
        run(["property", "--set", #"{"UserKeyMapping":[]}"#])
    }

    private static func run(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                logger.error("hidutil exited with \(process.terminationStatus)")
            }
        } catch {
            logger.error("hidutil failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
