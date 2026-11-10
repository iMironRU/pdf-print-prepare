// PDFPrintPrepare — macOS-приложение: перетащите PDF, получите пакеты для печати.
// Собирается: swiftc -O PDFPrintPrepare.swift -o PDFPrintPrepare.app/Contents/MacOS/PDFPrintPrepare

import Cocoa

// ─────────────────────────── настройки поиска инструментов ───────────────────
let pythonCandidates = [
    "/opt/homebrew/bin/python3",
    "/usr/local/bin/python3",
    "/usr/bin/python3",
]

/// Быстрая проверка: есть ли в интерпретаторе PyMuPDF (без login-shell).
func findPython() -> String? {
    for path in pythonCandidates {
        guard FileManager.default.isExecutableFile(atPath: path) else { continue }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = ["-c", "import fitz"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { return path }
        } catch { continue }
    }
    return nil
}

func hasTesseract() -> Bool {
    let paths = ["/opt/homebrew/bin/tesseract", "/usr/local/bin/tesseract", "/usr/bin/tesseract"]
    return paths.contains { FileManager.default.isExecutableFile(atPath: $0) }
}

// ─────────────────────────── зона drag & drop ───────────────────────────────
final class DropView: NSView {
    var onFiles: (([URL]) -> Void)?
    private var highlighted = false { didSet { needsDisplay = true } }
    private let label = NSTextField(labelWithString: "Перетащите сюда PDF\nили нажмите, чтобы выбрать")
    private let icon = NSImageView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 2
        registerForDraggedTypes([.fileURL])

        icon.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 42, weight: .regular)
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
            icon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),
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
        if let l = layer, highlighted { l.borderWidth = 3 }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if pdfURLs(from: sender).isEmpty { return [] }
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
    let spinner = NSProgressIndicator()
    let runButton = NSButton(title: "Обработать", target: nil, action: nil)
    let openButton = NSButton(title: "Открыть папку результата", target: nil, action: nil)
    let copiesField = NSTextField(string: "4")
    let printerField = NSTextField(string: "")
    let printNow = NSButton(checkboxWithTitle: "Печатать сразу (если принтер подключён)", target: nil, action: nil)

    var queue: [URL] = []
    var currentFile: URL?
    var currentOutDir: URL?
    var running = false { didSet { updateControls() } }
    var pythonPath: String = ""
    var uiReady = false

    // запуск через "Открыть с помощью" / перетаскивание на иконку
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
            .filter { $0.pathExtension.lowercased() == "pdf" }
        guard !urls.isEmpty else { return }
        enqueue(urls)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Определяем интерпретатор до openFiles — Finder присылает файлы очень рано
        pythonPath = findPython() ?? ""
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildUI()
        NSApp.activate(ignoringOtherApps: true)
        if pythonPath.isEmpty { pythonPath = findPython() ?? "" }
        uiReady = true
        if !queue.isEmpty && !running { startNext() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // ── UI ─────────────────────────────────────────────────────────────────
    func buildUI() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Подготовка PDF к печати"
        window.minSize = NSSize(width: 660, height: 520)
        // Центрируем на основном дисплее (у пользователя их несколько)
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
        printerField.widthAnchor.constraint(equalToConstant: 200).isActive = true
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

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let controls = NSStackView(views: [settingsRow, printerRow, printNow, NSView(), spinner, openButton, runButton])
        controls.orientation = .horizontal
        controls.spacing = 12
        controls.alignment = .centerY
        controls.translatesAutoresizingMaskIntoConstraints = false

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

        for v in [dropView, controls, scroll] { content.addSubview(v) }

        NSLayoutConstraint.activate([
            dropView.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            dropView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            dropView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            dropView.heightAnchor.constraint(equalToConstant: 160),

            controls.topAnchor.constraint(equalTo: dropView.bottomAnchor, constant: 16),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])

        appendLog("Готово. Перетащите PDF в окно — приложение разложит его на пакеты печати.\n")
        if pythonPath.isEmpty {
            appendLog("⚠️  Не найден python3 с PyMuPDF. Установите:  pip3 install pymupdf\n")
        }
        if !hasTesseract() {
            appendLog("⚠️  Не найден tesseract. Установите:  brew install tesseract tesseract-lang\n")
        }
    }

    @objc func stepperChanged(_ s: NSStepper) {
        copiesField.stringValue = "\(s.integerValue)"
    }

    func updateControls() {
        // «Обработать» активна, пока есть очередь или есть с чем перезапуститься
        runButton.isEnabled = !running && (!queue.isEmpty || currentFile != nil)
        dropView.alphaValue = running ? 0.5 : 1
    }

    // ── очередь ────────────────────────────────────────────────────────────
    func enqueue(_ urls: [URL]) {
        queue.append(contentsOf: urls)
        // UI может быть ещё не построен (Finder присылает файлы раньше окна)
        if uiReady && !running { startNext() }
    }

    func startNext() {
        guard !queue.isEmpty else { running = false; return }
        // openFiles может прийти раньше didFinishLaunching — определяем интерпретатор лениво
        if pythonPath.isEmpty { pythonPath = findPython() ?? "" }
        guard !pythonPath.isEmpty else {
            alert("Не найден python3 с PyMuPDF",
                  "Установите зависимости:\n\npip3 install pymupdf\nbrew install tesseract tesseract-lang")
            queue.removeAll(); return
        }
        guard hasTesseract() else {
            alert("Не найден tesseract",
                  "Установите:\n\nbrew install tesseract tesseract-lang")
            queue.removeAll(); return
        }

        let file = queue.removeFirst()
        currentFile = file
        currentOutDir = file.deletingLastPathComponent()
            .appendingPathComponent(file.deletingPathExtension().lastPathComponent + "_print")
        openButton.isEnabled = false

        running = true
        spinner.startAnimation(nil)
        appendLog("\n══════════════════════════════════════════\n")
        appendLog("Файл: \(file.lastPathComponent)\n")

        guard let script = Bundle.main.path(forResource: "pdf_print_analyzer", ofType: "py") else {
            appendLog("❌ Внутренняя ошибка: скрипт не найден в бандле\n")
            running = false; spinner.stopAnimation(nil); return
        }

        var args = [script, file.path, "--copies", copiesField.stringValue]
        let printer = printerField.stringValue.trimmingCharacters(in: .whitespaces)
        if !printer.isEmpty { args += ["--printer", printer] }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = ["-u"] + args   // -u: без буферизации, лог идёт в реальном времени
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        task.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.appendLog(s) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.appendLog("⚠️ " + s) }
        }

        task.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self = self else { return }
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                self.spinner.stopAnimation(nil)
                self.running = false

                if proc.terminationStatus == 0 {
                    self.appendLog("\n✅ Готово. Папка: \(self.currentOutDir?.lastPathComponent ?? "")\n")
                    self.openButton.isEnabled = true
                    if self.printNow.state == .on { self.runPrintScript() }
                } else {
                    self.appendLog("\n❌ Ошибка (код \(proc.terminationStatus))\n")
                }
                if !self.queue.isEmpty { self.startNext() }
            }
        }

        do {
            try task.run()
        } catch {
            appendLog("❌ Не удалось запустить: \(error.localizedDescription)\n")
            running = false; spinner.stopAnimation(nil)
        }
    }

    func runPrintScript() {
        guard let dir = currentOutDir else { return }
        let sh = dir.appendingPathComponent("print_commands.sh")
        guard FileManager.default.fileExists(atPath: sh.path) else { return }
        appendLog("\n🖨  Отправляю пакеты на принтер...\n")
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
                                ? "🖨  Задания отправлены в очередь печати.\n"
                                : "⚠️  Печать завершилась с кодом \(p.terminationStatus)\n")
            }
        }
        try? task.run()
    }

    @objc func runTapped() {
        if !queue.isEmpty { startNext(); return }
        // повторный запуск того же файла (результаты лягут в ту же папку)
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

    func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .warning
        a.runModal()
    }
}

// ─────────────────────────── запуск ─────────────────────────────────────────
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
