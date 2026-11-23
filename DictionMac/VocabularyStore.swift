import AppKit
import DictationCore
import OSLog

/// Your vocabulary file: ~/Library/Application Support/DictionApp/Vocabulary.md.
/// Created from a template on first launch and reloaded whenever you save it.
@MainActor
final class VocabularyStore {
    static let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("DictionApp", isDirectory: true)
            .appendingPathComponent("Vocabulary.md")
    }()

    /// Called with the parsed file whenever its contents change.
    var onChange: ((Vocabulary) -> Void)?
    private(set) var vocabulary = Vocabulary()

    private let logger = Logger(subsystem: "com.dictionapp.mac", category: "vocabulary")
    private var lastContents: String?
    private var folderWatcher: DispatchSourceFileSystemObject?
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var pendingReload: DispatchWorkItem?

    func start() {
        createFileIfNeeded()
        reload()
        watchFolder()
        watchFile()
    }

    /// Opens the file in your default Markdown editor, or TextEdit if there isn't one.
    func openInEditor() {
        createFileIfNeeded()
        let url = Self.fileURL
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Saves "it wrote `heard`, I meant `meant`" under Words and applies it right away.
    func addCorrection(heard: String, meant: String) throws {
        createFileIfNeeded()
        let url = Self.fileURL
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? Vocabulary.template
        let updated = Vocabulary.addingCorrection(heard: heard, meant: meant, to: contents)
        guard updated != contents else { return }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        logger.info("Saved a name correction")
        reload()
    }

    private func createFileIfNeeded() {
        let url = Self.fileURL
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Vocabulary.template.write(to: url, atomically: true, encoding: .utf8)
            logger.info("Created vocabulary file")
        } catch {
            logger.error("Couldn't create vocabulary file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reload() {
        let contents = (try? String(contentsOf: Self.fileURL, encoding: .utf8)) ?? ""
        guard contents != lastContents else { return }
        lastContents = contents
        vocabulary = Vocabulary.parse(markdown: contents)
        logger.info("Vocabulary loaded: \(self.vocabulary.words.count) words, \(self.vocabulary.slang.count) slang, \(self.vocabulary.replacements.count) replacements")
        onChange?(vocabulary)
    }

    /// Editors either rewrite the file in place or save a new copy and swap it in,
    /// so watch both the file and its folder.
    private func scheduleReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reload()
            self?.watchFile()  // the file may be a new one now
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func watchFolder() {
        folderWatcher = makeWatcher(for: Self.fileURL.deletingLastPathComponent(), events: .write)
    }

    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = makeWatcher(for: Self.fileURL, events: [.write, .extend, .delete, .rename])
    }

    private func makeWatcher(for url: URL, events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleReload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
