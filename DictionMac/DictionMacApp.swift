import AppKit
import DictationCore
import SwiftUI

@main
struct DictionMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.menuBarSymbol)
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppController.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppController.shared.shutdown() }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var controller: AppController

    var body: some View {
        Text(controller.statusText)

        if controller.dictationKeyBlocked, let app = controller.secureInputApp {
            Text("It has Secure Input on (a password field), which hides keys from other apps.")
            Text("Click out of the password field, or quit and reopen \(app).")
            Text("Or pick Fn / Globe as the Dictation Key, which usually still works.")
        }

        if !controller.microphoneGranted {
            Button("Grant Microphone Access…") { Permissions.openMicrophoneSettings() }
        }
        if !controller.accessibilityGranted {
            Button("Grant Accessibility Access…") {
                Permissions.promptAccessibility()
                Permissions.openAccessibilitySettings()
            }
        }

        Divider()

        if let last = controller.lastTranscript {
            Text("Last: \(last.count > 60 ? String(last.prefix(60)) + "…" : last)")
            if let timing = controller.lastTiming {
                Text(timing)
            }
            Button("Paste Last Dictation") { controller.pasteLastTranscript() }
            Button("Copy Last Dictation") { controller.copyLastTranscript() }
            Divider()
        }

        Picker("Dictation Key", selection: $controller.trigger) {
            ForEach(HotkeyTrigger.allCases) { Text($0.displayName).tag($0) }
        }
        Picker("Speech Model", selection: $controller.model) {
            ForEach(ParakeetModel.allCases) { Text($0.displayName).tag($0) }
        }
        Toggle("Remove Filler Words", isOn: $controller.removeFillers)
        Toggle("Spoken Punctuation (say \"comma\", \"new line\"…)", isOn: $controller.spokenPunctuation)
        Toggle("Numbers as Digits (six → 6, three a m → 3am)", isOn: $controller.numbersAsDigits)
        Toggle("Smart Spacing & Capitalization", isOn: $controller.smartSpacing)
        Toggle("Play Sounds", isOn: $controller.playSounds)

        Divider()

        if let app = controller.currentApp {
            Picker("Writing Style in \(app.name)", selection: styleBinding(for: app.bundleID)) {
                ForEach(WritingStyle.allCases) { Text($0.displayName).tag($0) }
            }
        }
        let others = controller.customizedApps.filter { $0.bundleID != controller.currentApp?.bundleID }
        if !others.isEmpty {
            Menu("Other Apps with Custom Styles") {
                ForEach(others, id: \.bundleID) { app in
                    Picker(app.name, selection: styleBinding(for: app.bundleID)) {
                        ForEach(WritingStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                }
            }
        }

        Divider()

        Button("Edit Vocabulary… (\(controller.vocabularySummary))") { controller.editVocabulary() }
        Button("Fix a Name…") { controller.fixName() }
        Toggle(
            controller.useContactNames && controller.contactNameCount > 0
                ? "Use Contact Names (\(controller.contactNameCount) names)"
                : "Use Contact Names",
            isOn: $controller.useContactNames
        )
        if controller.contactsDenied {
            Button("Contacts Access Is Off. Open Settings…") { Permissions.openContactsSettings() }
        }

        Divider()

        Toggle("Launch at Login", isOn: $controller.launchAtLogin)

        Divider()

        Text("Hold \(controller.trigger.shortName) to talk · double-tap for hands-free · Esc cancels")

        Divider()

        Button("Quit DictionApp") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func styleBinding(for bundleID: String) -> Binding<WritingStyle> {
        Binding(
            get: { controller.style(for: bundleID) },
            set: { controller.setStyle($0, for: bundleID) }
        )
    }
}
