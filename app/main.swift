// PDFPrintPrepare — macOS-приложение: перетащите PDF, получите пакеты для печати.
// Без внешних зависимостей: только системные PDFKit и Vision (OCR).
//
// Сборка: bash build_app.sh

import Cocoa

// ─────────────────────────── зона drag & drop ───────────────────────────────
final class DropView: NSView {
    var onFiles: (([URL]) -> Void)?
    private var highlighted = false { didSet { updateAppearance() } }
    private let label = NSTextField(labelWithString: "Перетащите сюда PDF\nили нажмите, чтобы выбрать")
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        registerForDraggedTypes([.fileURL])

        icon.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        label.alignment = .center
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon); addSubview(label)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -22),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 10),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -24),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        layer?.borderColor = (highlighted ? NSColor.controlAccentColor
                                          : NSColor.separatorColor).cgColor
        layer?.backgroundColor = (highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.10)
                                              : NSColor.textBackgroundColor).cgColor
        layer?.borderWidth = highlighted ? 3 : 2
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !pdfURLs(from: sender).isEmpty else { return [] }
        highlighted = true
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = false }
    override func draggingEnded(_ sender: NSDraggingInfo?) { highlighted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlighted = false
        let urls = pdfURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onFiles?(urls)
        return true
    }

    private func pdfURLs(from info: NSDraggingInfo) -> [URL] {
        guard let items = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "pdf" }
    }

    override func mouseDown(with event: NSEvent) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Выберите PDF для подготовки к печати"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            onFiles?(panel.urls)
        }
    }
}

// ─────────────────────────── приложение ─────────────────────────────────────
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let dropView = DropView(frame: .zero)
    let logView = NSTextView()
    let progressBar = NSProgressIndicator()
    let runButton = NSButton(title: "Обработать", target: nil, action: nil)
    let openButton = NSButton(title: "Открыть папку результата", target: nil, action: nil)
    let copiesField = NSTextField(string: "4")
    let printerField = NSTextField(string: "")
    let printNow = NSButton(checkboxWithTitle: "Печатать сразу (если принтер подключён)",
                            target: nil, action: nil)

    var queue: [URL] = []
    var currentFile: URL?
    var currentOutDir: URL?
    var running = false { didSet { updateControls() } }
    var uiReady = false

    // ── события системы ─────────────────────────────────────────────────────
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
            .filter { $0.pathExtension.lowercased() == "pdf" }
        guard !urls.isEmpty else { return }
        enqueue(urls)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        NSApp.activate(ignoringOtherApps: true)
        uiReady = true
        if !queue.isEmpty && !running { startNext() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // ── UI ──────────────────────────────────────────────────────────────────
    func buildUI() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "PDF к печати"
        window.minSize = NSSize(width: 660, height: 520)
        if let screen = NSScreen.screens.first {
            let vf = screen.visibleFrame
            let size = window.frame.size
            window.setFrameOrigin(NSPoint(x: vf.midX - size.width / 2,
                                          y: vf.midY - size.height / 2))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)

        let content = NSView()
        window.contentView = content

        dropView.onFiles = { [weak self] urls in self?.enqueue(urls) }
        dropView.translatesAutoresizingMaskIntoConstraints = false

        // Экземпляры
        let copiesLabel = NSTextField(labelWithString: "Экземпляров:")
        copiesField.alignment = .center
        copiesField.translatesAutoresizingMaskIntoConstraints = false
        copiesField.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let stepper = NSStepper()
        stepper.minValue = 1; stepper.maxValue = 99; stepper.increment = 1; stepper.integerValue = 4
        stepper.target = self; stepper.action = #selector(stepperChanged(_:))
        stepper.translatesAutoresizingMaskIntoConstraints = false

        let settingsRow = NSStackView(views: [copiesLabel, copiesField, stepper])
        settingsRow.orientation = .horizontal
        settingsRow.spacing = 6
        settingsRow.translatesAutoresizingMaskIntoConstraints = false

        // Принтер
        let printerLabel = NSTextField(labelWithString: "Принтер (необязательно):")
        printerField.placeholderString = "например HP_LaserJet_M404"
        printerField.translatesAutoresizingMaskIntoConstraints = false
        printerField.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let printerRow = NSStackView(views: [printerLabel, printerField])
        printerRow.orientation = .horizontal
        printerRow.spacing = 6
        printerRow.translatesAutoresizingMaskIntoConstraints = false

        printNow.translatesAutoresizingMaskIntoConstraints = false

        runButton.target = self; runButton.action = #selector(runTapped)
        runButton.keyEquivalent = "\r"
        runButton.bezelStyle = .rounded
        runButton.translatesAutoresizingMaskIntoConstraints = false

        openButton.target = self; openButton.action = #selector(openResult)
        openButton.isEnabled = false
        openButton.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [settingsRow, printerRow, printNow, NSView(),
                                           openButton, runButton])
        controls.orientation = .horizontal
        controls.spacing = 12
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false

        // Прогресс
        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.isHidden = true
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        // Лог
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        logView.isEditable = false
        logView.isRichText = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .textColor
        logView.backgroundColor = .textBackgroundColor
        logView.autoresizingMask = [.width]
        logView.isVerticallyResizable = true
        logView.textContainer?.widthTracksTextView = true
        scroll.documentView = logView

        for v in [dropView, controls, progressBar, scroll] { content.addSubview(v) }

        NSLayoutConstraint.activate([
            dropView.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            dropView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            dropView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            dropView.heightAnchor.constraint(equalToConstant: 150),

            controls.topAnchor.constraint(equalTo: dropView.bottomAnchor, constant: 14),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            progressBar.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            progressBar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            progressBar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        appendLog("Перетащите PDF в окно — приложение разложит документ на пакеты печати.\n")
        appendLog("Акты пойдут на двустороннюю печать, листы А3 — отдельным заданием.\n")
    }

    @objc func stepperChanged(_ s: NSStepper) {
        copiesField.stringValue = "\(s.integerValue)"
    }

    func updateControls() {
        runButton.isEnabled = !running && (!queue.isEmpty || currentFile != nil)
        dropView.alphaValue = running ? 0.55 : 1
    }

    // ── очередь ─────────────────────────────────────────────────────────────
    func enqueue(_ urls: [URL]) {
        queue.append(contentsOf: urls)
        if uiReady && !running { startNext() }
    }

    func startNext() {
        guard !queue.isEmpty else { running = false; return }

        let file = queue.removeFirst()
        currentFile = file
        currentOutDir = file.deletingLastPathComponent()
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent + "_print")
        openButton.isEnabled = false

        running = true
        progressBar.isHidden = false
        progressBar.isIndeterminate = true
        progressBar.startAnimation(nil)

        appendLog("\n════════════════════════════════════════════\n")

        let copies = max(1, Int(copiesField.stringValue) ?? 4)
        let printer = printerField.stringValue.trimmingCharacters(in: .whitespaces)

        let analyzer = Analyzer { [weak self] message in
            guard let self = self else { return }
            self.appendLog(message + "\n")
            if message.contains("распознано") {
                let parts = message.split(separator: " ").last?.split(separator: "/")
                if let parts = parts, parts.count == 2,
                   let done = Double(parts[0]), let total = Double(parts[1]), total > 0 {
                    self.progressBar.isIndeterminate = false
                    self.progressBar.stopAnimation(nil)
                    self.progressBar.doubleValue = done / total
                }
            }
            if message.contains("Пакеты записаны") {
                self.progressBar.isIndeterminate = false
                self.progressBar.stopAnimation(nil)
                self.progressBar.doubleValue = 1
            }
        }

        analyzer.analyze(pdfURL: file, copies: copies, printer: printer) { [weak self] result in
            guard let self = self else { return }
            self.running = false
            self.progressBar.stopAnimation(nil)
            self.progressBar.isHidden = true
            self.progressBar.doubleValue = 0

            switch result {
            case .success(let summary):
                self.appendLog("\nГотово: \(summary.pages) стр., актов \(summary.actPairs), "
                               + "листов А3 \(summary.a3Sheets), пакетов \(summary.groups) "
                               + String(format: "(%.0f с)\n", summary.seconds))
                self.appendLog("Папка: \(summary.outDir.lastPathComponent)\n")
                self.openButton.isEnabled = true
                NSWorkspace.shared.activateFileViewerSelecting([summary.outDir])
                if self.printNow.state == .on { self.runPrintScript(at: summary.outDir) }
            case .failure(let error):
                self.appendLog("\nОшибка: \(error.localizedDescription)\n")
                let alert = NSAlert()
                alert.messageText = "Не удалось обработать файл"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.runModal()
            }

            if !self.queue.isEmpty { self.startNext() }
        }
    }

    func runPrintScript(at dir: URL) {
        let sh = dir.appendingPathComponent("print_commands.sh")
        guard FileManager.default.fileExists(atPath: sh.path) else { return }
        appendLog("\nОтправляю пакеты на принтер...\n")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [sh.path]
        task.currentDirectoryURL = dir
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.appendLog(s) }
        }
        task.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self?.appendLog(p.terminationStatus == 0
                                ? "Задания отправлены в очередь печати.\n"
                                : "Печать завершилась с кодом \(p.terminationStatus)\n")
            }
        }
        try? task.run()
    }

    @objc func runTapped() {
        if !queue.isEmpty { startNext(); return }
        if let f = currentFile { queue.append(f); startNext() }
    }

    @objc func openResult() {
        guard let dir = currentOutDir else { return }
        NSWorkspace.shared.open(dir)
    }

    func appendLog(_ s: String) {
        logView.textStorage?.append(NSAttributedString(
            string: s,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                         .foregroundColor: NSColor.textColor]))
        logView.scrollToEndOfDocument(nil)
    }
}

// ─────────────────────────── запуск ─────────────────────────────────────────
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
