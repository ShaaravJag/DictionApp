import AppKit
import DictationCore
import OSLog
import ServiceManagement
import SwiftUI

/// Owns the whole dictation flow: hotkey → record → transcribe → format → paste.
@MainActor
final class AppController: ObservableObject {
    static let shared = AppController()

    enum Phase: Equatable {
        case loadingModel(Double)
        case idle
        case recording(handsFree: Bool)
        case transcribing
        case error(String)
    }

    // MARK: - Published state

    @Published private(set) var phase: Phase = .loadingModel(0)
    @Published private(set) var levels: [Float] = Array(repeating: 0, count: 16)
    @Published private(set) var lastTranscript: String?
    @Published private(set) var lastTiming: String?
    @Published private(set) var microphoneGranted = Permissions.microphoneGranted
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted

    // MARK: - Settings (persisted)

    /// The app whose Secure Input is hiding keypresses from us (e.g. "Google Chrome"), if any.
    @Published private(set) var secureInputApp: String?
    private let secureInput = SecureInputWatcher()

    /// macOS hides key presses like the 🎤 key while another app has Secure Input on.
    /// (Modifier triggers like Fn still get through.)
    var dictationKeyBlocked: Bool { trigger == .dictationKey && secureInputApp != nil }

    @Published var trigger: HotkeyTrigger {
        didSet {
            defaults.set(trigger.rawValue, forKey: Keys.trigger)
            applyTrigger()
        }
    }

    @Published var model: ParakeetModel {
        didSet {
            guard model != oldValue else { return }
            defaults.set(model.rawValue, forKey: Keys.model)
            loadModel()
        }
    }

    @Published var removeFillers: Bool {
        didSet { defaults.set(removeFillers, forKey: Keys.removeFillers) }
    }

    /// Say "comma", "question mark", "new line"… (automatic punctuation stays on regardless).
    @Published var spokenPunctuation: Bool {
        didSet { defaults.set(spokenPunctuation, forKey: Keys.spokenPunctuation) }
    }

    /// "six" -> 6, "three a m" -> 3am, "five dollars" -> $5.
    @Published var numbersAsDigits: Bool {
        didSet { defaults.set(numbersAsDigits, forKey: Keys.numbersAsDigits) }
    }

    /// Look at the text around the cursor to add spaces and fix capitalization.
    @Published var smartSpacing: Bool {
        didSet { defaults.set(smartSpacing, forKey: Keys.smartSpacing) }
    }

    // MARK: - Per-app writing styles

    struct AppInfo: Equatable {
        let bundleID: String
        let name: String
    }

    /// The app you were last in (the one dictation goes into), ignoring DictionApp itself.
    @Published private(set) var currentApp: AppInfo?

    /// Bundle ID → style. Apps not listed use Standard.
    @Published private(set) var appStyles: [String: WritingStyle] = [:]

    func style(for bundleID: String?) -> WritingStyle {
        guard let bundleID else { return .standard }
        return appStyles[bundleID] ?? .standard
    }

    func setStyle(_ style: WritingStyle, for bundleID: String) {
        appStyles[bundleID] = style == .standard ? nil : style
        defaults.set(appStyles.mapValues(\.rawValue), forKey: Keys.appStyles)
    }

    /// Apps with a non-standard style, sorted by name, for the menu.
    var customizedApps: [AppInfo] {
        appStyles.keys
            .map { AppInfo(bundleID: $0, name: Self.appName(for: $0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    private func trackFrontmostApp() {
        let update: (NSRunningApplication?) -> Void = { [weak self] app in
            guard let self, let app, let bundleID = app.bundleIdentifier,
                  bundleID != Bundle.main.bundleIdentifier else { return }
            self.currentApp = AppInfo(bundleID: bundleID, name: app.localizedName ?? Self.appName(for: bundleID))
        }
        update(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { update(app) }
        }
    }

    @Published var playSounds: Bool {
        didSet { defaults.set(playSounds, forKey: Keys.playSounds) }
    }

    // MARK: - Personal vocabulary

    /// Recognize names from Contacts. Turning it on asks for Contacts access once.
    @Published var useContactNames: Bool {
        didSet {
            guard useContactNames != oldValue else { return }
            defaults.set(useContactNames, forKey: Keys.useContactNames)
            applyContactsSetting()
        }
    }
    @Published private(set) var contactNameCount = 0
    @Published private(set) var contactsDenied = false
    @Published private(set) var vocabularySummary = ""

    func editVocabulary() {
        vocabularyStore.openInEditor()
    }

    /// "It wrote X, I meant Y": saved to the vocabulary file and used from the next dictation on.
    func fixName() {
        // Let the menu finish closing before showing a window.
        DispatchQueue.main.async { [weak self] in self?.presentFixName(heard: "", meant: "") }
    }

    private func presentFixName(heard: String, meant: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Fix a Name"
        var info = "Type what DictionApp wrote and what you meant. It's corrected from your next dictation on, in every app."
        if let lastTranscript {
            info += "\n\nLast dictation: \u{201C}\(lastTranscript.prefix(140))\u{201D}"
        }
        alert.informativeText = info

        let heardField = NSTextField(string: heard)
        heardField.placeholderString = "e.g. Sharav"
        let meantField = NSTextField(string: meant)
        meantField.placeholderString = "e.g. Shaarav"
        let form = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
        for (row, (label, field)) in [("It wrote:", heardField), ("You meant:", meantField)].enumerated() {
            let y = CGFloat(row == 0 ? 34 : 2)
            let labelView = NSTextField(labelWithString: label)
            labelView.frame = NSRect(x: 0, y: y + 3, width: 80, height: 18)
            field.frame = NSRect(x: 84, y: y, width: 216, height: 24)
            form.addSubview(labelView)
            form.addSubview(field)
        }
        heardField.nextKeyView = meantField
        alert.accessoryView = form
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = heardField

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newHeard = heardField.stringValue, newMeant = meantField.stringValue

        if let problem = Vocabulary.correctionProblem(heard: newHeard, meant: newMeant) {
            let warning = NSAlert()
            warning.messageText = problem
            warning.runModal()
            presentFixName(heard: newHeard, meant: newMeant)
            return
        }
        do {
            try vocabularyStore.addCorrection(heard: newHeard, meant: newMeant)
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
        }
    }

    private func applyContactsSetting() {
        if useContactNames {
            Task {
                let granted = await contacts.enable()
                contactsDenied = !granted
                if !granted { useContactNames = false }
            }
        } else {
            contacts.disable()
        }
    }

    /// Rebuilds everything that depends on the vocabulary file or contact names.
    private func vocabularyChanged() {
        let vocabulary = vocabularyStore.vocabulary
        let contactNames = contacts.names
        standardReplacer = VocabularyReplacer(vocabulary.textReplacements(casual: false))
        casualReplacer = VocabularyReplacer(vocabulary.textReplacements(casual: true))
        ProperNouns.setCustomNames((vocabulary.words + contactNames).map(\.text))
        contactNameCount = contactNames.count

        var parts = ["\(vocabulary.words.count) words", "\(vocabulary.slang.count) slang"]
        if !vocabulary.replacements.isEmpty { parts.append("\(vocabulary.replacements.count) replacements") }
        vocabularySummary = parts.joined(separator: " · ")

        pushVocabulary()
    }

    private func pushVocabulary() {
        let vocabulary = vocabularyStore.vocabulary
        let standard = vocabulary.words + contacts.names
        let casual = standard + vocabulary.slang
        let transcriber = self.transcriber
        Task {
            await transcriber.setCommonWordCheck { await ProperNouns.isCommonWord($0) }
            await transcriber.setVocabulary(standard: standard, casual: casual)
        }
    }

    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet {
            guard launchAtLogin != oldValue else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                logger.error("Launch at login: \(error.localizedDescription, privacy: .public)")
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    // MARK: - Collaborators

    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.dictionapp.mac", category: "controller")
    private let recorder = AudioRecorder()
    private let hotkey = HotkeyMonitor()
    private let inserter = TextInserter()
    private lazy var overlay = OverlayController(controller: self)
    private var transcriber: ParakeetTranscriber
    private var modelLoadTask: Task<Void, Never>?
    private let vocabularyStore = VocabularyStore()
    private let contacts = ContactsNameSource()
    private var standardReplacer = VocabularyReplacer([])
    private var casualReplacer = VocabularyReplacer([])

    // Tap / double-tap detection
    private var pressedAt = Date.distantPast
    private var awaitingSecondTap = false
    private var tapTimeout: DispatchWorkItem?
    private static let tapThreshold: TimeInterval = 0.3
    private static let doubleTapWindow: TimeInterval = 0.35
    private static let minimumAudio: TimeInterval = 0.3

    private var permissionTimer: Timer?

    private enum Keys {
        static let trigger = "hotkeyTrigger"
        static let model = "speechModel"
        static let removeFillers = "removeFillers"
        static let spokenPunctuation = "spokenPunctuation"
        static let smartSpacing = "smartSpacing"
        static let numbersAsDigits = "numbersAsDigits"
        static let appStyles = "appStyles"
        static let playSounds = "playSounds"
        static let useContactNames = "useContactNames"
    }

    private init() {
        defaults.register(defaults: [
            Keys.removeFillers: true, Keys.playSounds: true,
            Keys.spokenPunctuation: true, Keys.smartSpacing: true, Keys.numbersAsDigits: true,
            // You text in lowercase in Messages.
            Keys.appStyles: ["com.apple.MobileSMS": WritingStyle.casual.rawValue],
        ])
        trigger = HotkeyTrigger(rawValue: defaults.string(forKey: Keys.trigger) ?? "") ?? .dictationKey
        let model = ParakeetModel(rawValue: defaults.string(forKey: Keys.model) ?? "") ?? .ultra
        self.model = model
        removeFillers = defaults.bool(forKey: Keys.removeFillers)
        spokenPunctuation = defaults.bool(forKey: Keys.spokenPunctuation)
        smartSpacing = defaults.bool(forKey: Keys.smartSpacing)
        numbersAsDigits = defaults.bool(forKey: Keys.numbersAsDigits)
        let storedStyles = defaults.dictionary(forKey: Keys.appStyles) as? [String: String] ?? [:]
        appStyles = storedStyles.compactMapValues(WritingStyle.init(rawValue:))
        playSounds = defaults.bool(forKey: Keys.playSounds)
        useContactNames = defaults.bool(forKey: Keys.useContactNames)
        transcriber = ParakeetTranscriber(model: model)
    }

    // MARK: - Lifecycle

    func start() {
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.pushLevel(level) }
        }
        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        hotkey.onInterrupt = { [weak self] in self?.cancelRecording() }
        hotkey.onUserInput = { [weak self] in self?.inserter.forgetLastInsertion() }
        hotkey.onEscape = { [weak self] in
            guard let self, case .recording = self.phase else { return false }
            self.cancelRecording()
            return true
        }

        ProperNouns.preload()
        trackFrontmostApp()
        applyTrigger()
        loadModel()

        vocabularyStore.onChange = { [weak self] _ in self?.vocabularyChanged() }
        contacts.onChange = { [weak self] _ in self?.vocabularyChanged() }
        vocabularyStore.start()
        if useContactNames { applyContactsSetting() }

        requestPermissionsIfNeeded()

        secureInput.onChange = { [weak self] app in self?.secureInputApp = app }
        secureInput.start()
    }

    func shutdown() {
        hotkey.stop()
        recorder.stop()
        DictationKeyRemapper.disable()
    }

    private func applyTrigger() {
        hotkey.trigger = trigger
        if trigger == .dictationKey {
            DictationKeyRemapper.enable()
        } else {
            DictationKeyRemapper.disable()
        }
    }

    private func loadModel() {
        modelLoadTask?.cancel()
        let transcriber = ParakeetTranscriber(model: model)
        self.transcriber = transcriber
        pushVocabulary()
        phase = .loadingModel(0)
        modelLoadTask = Task { [weak self] in
            do {
                try await transcriber.prepare { fraction in
                    Task { @MainActor in
                        guard let self, case .loadingModel = self.phase else { return }
                        self.phase = .loadingModel(fraction)
                    }
                }
                guard !Task.isCancelled else { return }
                self?.phase = .idle
            } catch {
                guard !Task.isCancelled else { return }
                self?.logger.error("Model load failed: \(error.localizedDescription, privacy: .public)")
                self?.phase = .error("Couldn't load the speech model: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Permissions

    private func requestPermissionsIfNeeded() {
        if Permissions.microphoneUndetermined {
            Task {
                _ = await Permissions.requestMicrophone()
                refreshPermissions()
            }
        }
        if !Permissions.accessibilityGranted {
            Permissions.promptAccessibility()
        }
        refreshPermissions()

        // Poll until both are granted; the event tap can only start after Accessibility is on.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    func refreshPermissions() {
        microphoneGranted = Permissions.microphoneGranted
        accessibilityGranted = Permissions.accessibilityGranted
        if accessibilityGranted && !hotkey.isRunning {
            if hotkey.start() {
                logger.info("Hotkey monitor started")
            }
        }
        if microphoneGranted && accessibilityGranted && hotkey.isRunning {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    // MARK: - Hotkey handling

    private func handlePress() {
        // Second tap of a double-tap: keep the recording going, hands-free.
        if awaitingSecondTap {
            awaitingSecondTap = false
            tapTimeout?.cancel()
            phase = .recording(handsFree: true)
            return
        }

        switch phase {
        case .recording(handsFree: true):
            finishRecording()
        case .idle, .error:
            startRecording()
        case .loadingModel:
            NSSound.beep()
        case .recording(handsFree: false), .transcribing:
            break
        }
    }

    private func handleRelease() {
        guard case .recording(handsFree: false) = phase else { return }

        if Date().timeIntervalSince(pressedAt) < Self.tapThreshold {
            // Quick tap: wait briefly to see if it's a double-tap.
            awaitingSecondTap = true
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.awaitingSecondTap else { return }
                self.awaitingSecondTap = false
                self.cancelRecording()
            }
            tapTimeout = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.doubleTapWindow, execute: work)
            return
        }

        finishRecording()
    }

    // MARK: - Recording

    private func startRecording() {
        guard microphoneGranted else {
            showError("Microphone access is off. Open the menu bar icon to grant it.")
            return
        }
        do {
            try recorder.start()
        } catch {
            showError(error.localizedDescription)
            return
        }
        pressedAt = Date()
        if smartSpacing { FocusedTextReader.prepareFrontmostApp() }
        levels = Array(repeating: 0, count: levels.count)
        phase = .recording(handsFree: false)
        overlay.show()
        play("Tink")
    }

    private func cancelRecording() {
        awaitingSecondTap = false
        tapTimeout?.cancel()
        guard case .recording = phase else { return }
        recorder.stop()
        phase = .idle
        overlay.hide()
    }

    private func finishRecording() {
        let audio = recorder.stop()
        guard audio.duration >= Self.minimumAudio else {
            phase = .idle
            overlay.hide()
            return
        }

        phase = .transcribing
        play("Pop")
        let transcriber = self.transcriber
        let isProperNoun: ProperNounCheck = { ProperNouns.isProperNoun($0) }
        let targetBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let style = style(for: targetBundleID)
        let formatter = TextFormatter(
            removeFillers: removeFillers,
            spokenPunctuation: spokenPunctuation,
            automaticPunctuation: style.usesAutomaticPunctuation,
            numbersAsDigits: numbersAsDigits,
            isProperNoun: isProperNoun
        )
        let boost: VocabularyBoost = style == .casual ? .casual : .standard
        let replacer = style == .casual ? casualReplacer : standardReplacer
        let contextual = smartSpacing
            ? ContextualFormatter(adjustsCapitalization: style.adjustsCapitalization, isProperNoun: isProperNoun)
            : nil
        let started = Date()

        Task {
            do {
                let raw = replacer.apply(try await transcriber.transcribe(audio, boost: boost))
                let formatted = formatter.formatDetailed(raw)
                var text = style.apply(formatted.text, keepFinalPunctuation: formatted.endsWithSpokenPunctuation)

                var snapshot = FocusedTextReader.read()
                if let contextual, !text.isEmpty {
                    var source = "accessibility"
                    let axBefore = snapshot.context.textBefore
                    // Nothing typed or clicked since our last paste into this field: we know exactly
                    // what's before the cursor, even in apps that hide their text.
                    if axBefore == nil || axBefore == "", let remembered = inserter.remembered(for: snapshot) {
                        snapshot.context.textBefore = remembered.textBefore
                        source = "memory"
                    } else if snapshot.context.isUnknown {
                        source = "unknown"
                    }
                    text = contextual.adapt(text, to: snapshot.context, keepFinalPeriod: formatted.endsWithSpokenPunctuation)
                    logger.info("Insertion context from \(source, privacy: .public)")
                }
                let elapsed = Date().timeIntervalSince(started)
                lastTiming = String(format: "%.1fs audio → %.2fs to text", audio.duration, elapsed)
                logger.info("Transcribed \(audio.duration, format: .fixed(precision: 1))s in \(elapsed, format: .fixed(precision: 2))s")

                if !text.isEmpty {
                    lastTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    inserter.insert(text, into: snapshot)
                }
                phase = .idle
                overlay.hide()
            } catch {
                logger.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                showError("Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func showError(_ message: String) {
        phase = .error(message)
        overlay.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, case .error = self.phase else { return }
            self.phase = .idle
            self.overlay.hide()
        }
    }

    private func pushLevel(_ level: Float) {
        guard case .recording = phase else { return }
        levels.removeFirst()
        levels.append(level)
    }

    private func play(_ name: String) {
        guard playSounds, let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.volume = 0.25
        sound.play()
    }

    // MARK: - Menu actions

    func copyLastTranscript() {
        guard let lastTranscript else { return }
        inserter.copyToClipboard(lastTranscript)
    }

    func pasteLastTranscript() {
        guard let lastTranscript else { return }
        // Let the menu close and focus return to the previous app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.inserter.insert(lastTranscript)
        }
    }

    // MARK: - Display helpers

    var statusText: String {
        switch phase {
        case .loadingModel(let fraction):
            return fraction > 0 && fraction < 1
                ? "Downloading speech model… \(Int(fraction * 100))%"
                : "Loading speech model…"
        case .idle:
            if !accessibilityGranted { return "Needs Accessibility permission" }
            if !microphoneGranted { return "Needs Microphone permission" }
            if dictationKeyBlocked, let app = secureInputApp { return "⚠️ \(app) is blocking the 🎤 key" }
            return "Ready: hold \(trigger.shortName) to dictate"
        case .recording(let handsFree):
            return handsFree ? "Listening (hands-free)…" : "Listening…"
        case .transcribing:
            return "Transcribing…"
        case .error(let message):
            return message
        }
    }

    var menuBarSymbol: String {
        switch phase {
        case .recording: return "mic.fill"
        case .transcribing: return "ellipsis.circle"
        case .loadingModel: return "arrow.down.circle"
        case .error: return "exclamationmark.triangle"
        case .idle: return accessibilityGranted && microphoneGranted && !dictationKeyBlocked ? "waveform" : "exclamationmark.triangle"
        }
    }
}
