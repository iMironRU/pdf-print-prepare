// Analyzer.swift — разбор PDF и нарезка на пакеты печати.
// Только системные фреймворки: PDFKit + Vision (OCR встроен в macOS).

import Foundation
import PDFKit
import Vision
import CoreGraphics

// ───────────────────────────── модели ────────────────────────────────────────
enum PrintMode: String {
    case simplexA4 = "simplex_A4"
    case duplexA4  = "duplex_A4"
    case simplexA3 = "simplex_A3"

    var media: String {
        switch self {
        case .simplexA4, .duplexA4: return "А4"
        case .simplexA3: return "А3"
        }
    }
    var sidesText: String {
        switch self {
        case .simplexA4: return "НЕТ — односторонний"
        case .duplexA4: return "ДА — двусторонний по ДЛИННОЙ стороне"
        case .simplexA3: return "НЕТ — односторонний"
        }
    }
}

struct PrintGroup {
    var index: Int = 0
    var pages: [Int]            // 1-based, порядок сохраняется
    var mode: PrintMode
    var label: String
    var file: String = ""
}

struct AnalysisSummary {
    var file: String
    var outDir: URL
    var pages: Int
    var actPairs: Int
    var a3Sheets: Int
    var groups: Int
    var copies: Int
    var seconds: Double
}

enum AnalysisError: LocalizedError {
    case openFailed
    case emptyPDF
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .openFailed: return "Не удалось открыть PDF"
        case .emptyPDF: return "В документе нет страниц"
        case .writeFailed(let what): return "Не удалось сохранить: \(what)"
        }
    }
}

// ───────────────────────────── анализ ────────────────────────────────────────
final class Analyzer {

    private enum PageKind { case a4, a3, actFront, actBack }

    private struct PageState {
        var number: Int
        var isA3: Bool
        var text: String = ""
        var kind: PageKind = .a4
    }

    /// Порог A3: у A4 длинная сторона ≈ 842 pt, у A3 ≈ 1191 pt
    private static let a3Threshold: CGFloat = 1000
    /// DPI рендера для OCR: 150 достаточно, 200 — чуть точнее и медленнее
    private static let ocrDPI: CGFloat = 150

    private let progress: (String) -> Void
    private let renderLock = NSLock()

    init(progress: @escaping (String) -> Void) {
        self.progress = progress
    }

    /// Все сообщения прогресса — только в главном потоке (AppKit не любит иначе)
    private func report(_ message: String) {
        DispatchQueue.main.async { [progress] in progress(message) }
    }

    // ── публичная точка входа ────────────────────────────────────────────────
    func analyze(pdfURL: URL,
                 copies: Int,
                 printer: String,
                 completion: @escaping (Result<AnalysisSummary, Error>) -> Void) {

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let summary = try self.run(pdfURL: pdfURL, copies: copies, printer: printer)
                DispatchQueue.main.async { completion(.success(summary)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // ── основной конвейер ────────────────────────────────────────────────────
    private func run(pdfURL: URL, copies: Int, printer: String) throws -> AnalysisSummary {
        let started = Date()

        guard let doc = PDFDocument(url: pdfURL) else { throw AnalysisError.openFailed }
        let pageCount = doc.pageCount
        guard pageCount > 0 else { throw AnalysisError.emptyPDF }

        let outDir = pdfURL.deletingLastPathComponent()
            .appendingPathComponent(pdfURL.deletingPathExtension().lastPathComponent + "_print")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        report("Файл: \(pdfURL.lastPathComponent) — \(pageCount) стр.")
        report("Папка результата: \(outDir.path)")

        // 1. OCR (или кэш)
        let cacheURL = outDir.appendingPathComponent("ocr_cache.json")
        var states = loadCache(cacheURL, pageCount: pageCount, doc: doc)
        if states == nil {
            states = ocrAll(doc: doc, pageCount: pageCount, cacheURL: cacheURL)
        } else {
            report("Кэш OCR найден — распознавание пропущено")
        }
        var pages = states!

        // 2. Классификация + починка пар
        for i in pages.indices {
            pages[i].kind = classify(text: pages[i].text, isA3: pages[i].isA3)
        }
        let repaired = repairPairs(&pages)
        if repaired > 0 { report("Достроено начал актов по обороту: \(repaired)") }

        let actPairs = pages.filter { $0.kind == .actBack }.count
        let a3Count = pages.filter { $0.isA3 }.count
        let frontCount = pages.filter { $0.kind == .actFront }.count
        report("Найдено: актов \(frontCount), листов А3 \(a3Count)")

        // 3. Группировка
        var groups = buildGroups(pages)
        report("Пакетов для печати: \(groups.count)")

        // 4. Нарезка PDF
        try split(doc: doc, groups: &groups, outDir: outDir)
        report("Пакеты записаны")

        // 5. План и команды
        let planTXT = outDir.appendingPathComponent("print_plan.txt")
        let planSH  = outDir.appendingPathComponent("print_commands.sh")
        let planJSON = outDir.appendingPathComponent("print_plan.json")
        try writePlan(groups: groups, copies: copies, to: planTXT)
        try writeCommands(groups: groups, copies: copies, printer: printer, to: planSH)
        try writeJSON(groups: groups, copies: copies, to: planJSON, pdfURL: pdfURL, outDir: outDir)

        let seconds = Date().timeIntervalSince(started)
        return AnalysisSummary(file: pdfURL.lastPathComponent, outDir: outDir,
                               pages: pageCount, actPairs: actPairs, a3Sheets: a3Count,
                               groups: groups.count, copies: copies, seconds: seconds)
    }

    // ── OCR ──────────────────────────────────────────────────────────────────
    private func ocrAll(doc: PDFDocument, pageCount: Int, cacheURL: URL) -> [PageState] {
        report("Распознавание текста (встроенный OCR macOS)...")
        var results = Array(repeating: PageState(number: 0, isA3: false), count: pageCount)
        let lock = NSLock()
        var done = 0

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 6

        for idx in 0..<pageCount {
            queue.addOperation { [weak self] in
                guard let self, let page = doc.page(at: idx) else { return }
                let box = page.bounds(for: .mediaBox)
                let isA3 = max(box.width, box.height) > Analyzer.a3Threshold
                var text = ""
                if !isA3, let img = self.render(page: page) {
                    text = self.recognize(img)
                }
                lock.lock()
                results[idx] = PageState(number: idx + 1, isA3: isA3, text: text)
                done += 1
                let now = done
                lock.unlock()
                if now % 5 == 0 || now == pageCount {
                    self.report("  распознано \(now)/\(pageCount)")
                }
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        // кэш
        let payload: [[String: Any]] = results.map {
            ["page": $0.number, "fmt": $0.isA3 ? "A3" : "A4", "text": $0.text]
        }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            try? data.write(to: cacheURL)
        }
        return results
    }

    private func loadCache(_ url: URL, pageCount: Int, doc: PDFDocument) -> [PageState]? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              raw.count == pageCount else { return nil }
        var out: [PageState] = []
        for item in raw {
            guard let n = item["page"] as? Int,
                  let fmt = item["fmt"] as? String,
                  let text = item["text"] as? String else { return nil }
            out.append(PageState(number: n, isA3: fmt == "A3", text: text))
        }
        // пересчитываем формат по факту (файл мог измениться)
        for i in out.indices {
            if let p = doc.page(at: i) {
                let box = p.bounds(for: .mediaBox)
                out[i].isA3 = max(box.width, box.height) > Analyzer.a3Threshold
            }
        }
        return out
    }

    /// Рендер страницы в CGImage. PDFPage не потокобезопасен — под замком.
    private func render(page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let scale = Analyzer.ocrDPI / 72.0
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard w > 0, h > 0 else { return nil }

        renderLock.lock()
        defer { renderLock.unlock() }

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        let rotation = page.rotation
        if rotation != 0 {
            ctx.translateBy(x: box.width / 2, y: box.height / 2)
            ctx.rotate(by: -CGFloat(rotation) * .pi / 180)
            ctx.translateBy(x: -box.width / 2, y: -box.height / 2)
        }
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    private func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // ── классификация ────────────────────────────────────────────────────────
    private func classify(text: String, isA3: Bool) -> PageKind {
        if isA3 { return .a3 }
        let t = text.lowercased().replacingOccurrences(of: "\n", with: " ")
        let compact = t.split(whereSeparator: { $0 == " " }).joined(separator: " ")

        let isFront = compact.contains("объект капитальн")
            && (compact.contains("застройщик")
                || compact.contains("технический заказчик")
                || compact.contains("лицо, осуществляющ")
                || compact.contains("лицо осуществляющ")
                || compact.contains("заказчик"))

        let isBack = compact.contains("составили настоящий акт")
            || (compact.contains("освидетельствован") && compact.contains("предъявлен"))

        if isFront { return .actFront }
        if isBack { return .actBack }
        return .a4
    }

    /// Если оборот есть, а начало не распозналось — поднимаем предыдущую страницу.
    private func repairPairs(_ pages: inout [PageState]) -> Int {
        var fixed = 0
        for i in pages.indices where pages[i].kind == .actBack {
            guard i > 0 else { continue }
            let prev = i - 1
            if pages[prev].kind == .a4, !pages[prev].isA3,
               pages[prev].text.lowercased().contains("объект капитальн") {
                pages[prev].kind = .actFront
                fixed += 1
            }
        }
        return fixed
    }

    // ── группировка ──────────────────────────────────────────────────────────
    private func buildGroups(_ pages: [PageState]) -> [PrintGroup] {
        var groups: [PrintGroup] = []
        var i = 0
        while i < pages.count {
            let p = pages[i]
            switch p.kind {
            case .actFront:
                if i + 1 < pages.count, pages[i + 1].kind == .actBack {
                    groups.append(PrintGroup(pages: [p.number, pages[i + 1].number],
                                             mode: .duplexA4,
                                             label: "Акт освидетельствования скрытых работ (двусторонний, длинная сторона)"))
                    i += 2
                } else {
                    groups.append(PrintGroup(pages: [p.number], mode: .simplexA4,
                                             label: "A4 односторонний (акт без оборота)"))
                    i += 1
                }
            case .actBack:
                groups.append(PrintGroup(pages: [p.number], mode: .simplexA4,
                                         label: "A4 односторонний (оборот без начала)"))
                i += 1
            case .a3:
                var nums = [p.number]
                i += 1
                while i < pages.count, pages[i].kind == .a3 {
                    nums.append(pages[i].number); i += 1
                }
                groups.append(PrintGroup(pages: nums, mode: .simplexA3, label: "A3 односторонний"))
            case .a4:
                var nums = [p.number]
                i += 1
                while i < pages.count, pages[i].kind == .a4 {
                    nums.append(pages[i].number); i += 1
                }
                groups.append(PrintGroup(pages: nums, mode: .simplexA4, label: "A4 односторонний"))
            }
        }
        return groups
    }

    // ── запись файлов ────────────────────────────────────────────────────────
    private func split(doc: PDFDocument, groups: inout [PrintGroup], outDir: URL) throws {
        for gi in groups.indices {
            let g = groups[gi]
            guard let target = PDFDocument() as PDFDocument? else { throw AnalysisError.writeFailed("создание PDF") }
            for pnum in g.pages {
                guard let page = doc.page(at: pnum - 1) else { continue }
                target.insert(page, at: target.pageCount)
            }
            var name = String(format: "batch_%02d_%@_p%d", gi + 1, g.mode.rawValue, g.pages.first ?? 0)
            if g.pages.count > 1 { name += "-\(g.pages.last ?? 0)" }
            name += ".pdf"
            let url = outDir.appendingPathComponent(name)
            guard target.write(to: url) else { throw AnalysisError.writeFailed(name) }
            groups[gi].file = name
            groups[gi].index = gi + 1
        }
    }

    private func writePlan(groups: [PrintGroup], copies: Int, to url: URL) throws {
        var L: [String] = []
        L.append(String(repeating: "=", count: 72))
        L.append("  ПЛАН ПЕЧАТИ — \(copies) экз.")
        L.append(String(repeating: "=", count: 72))
        L.append("")
        L.append("Печатайте пакеты СТРОГО по порядку номеров: так сохраняется")
        L.append("последовательность листов. После печати разложите по экземплярам.")
        L.append("")
        var sheets = 0
        for g in groups {
            let rng = g.pages.count > 1
                ? "стр. \(g.pages.first!)–\(g.pages.last!)"
                : "стр. \(g.pages.first!)"
            L.append(String(format: "Пакет %02d: %@", g.index, g.file))
            L.append("   Страницы документа : \(rng)  (\(g.pages.count) л.)")
            L.append("   Тип                : \(g.label)")
            L.append("   Бумага             : \(g.mode.media)")
            L.append("   Дуплекс            : \(g.mode.sidesText)")
            L.append("   Экземпляров        : \(copies)")
            L.append("")
            sheets += g.mode == .duplexA4 ? max(1, g.pages.count / 2) : g.pages.count
        }
        L.append(String(repeating: "=", count: 72))
        L.append("Итого листов в одном экземпляре: \(sheets)")
        L.append(String(repeating: "=", count: 72))
        try L.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeCommands(groups: [PrintGroup], copies: Int, printer: String, to url: URL) throws {
        var L = ["#!/bin/bash",
                 "# Команды печати (CUPS: macOS / Linux). Запуск: bash print_commands.sh",
                 ""]
        let dest = printer.isEmpty
            ? "-d \"$(lpstat -d | awk '{print $NF}')\""
            : "-d \"\(printer)\""
        for g in groups {
            let opts: String
            switch g.mode {
            case .simplexA4: opts = "-o sides=one-sided -o media=A4"
            case .duplexA4:  opts = "-o sides=two-sided-long-edge -o media=A4"
            case .simplexA3: opts = "-o sides=one-sided -o media=A3"
            }
            L.append(String(format: "# Пакет %02d — %@", g.index, g.label))
            L.append("lp \(dest) -n \(copies) -o collate=true \(opts) \"\(g.file)\"")
            L.append("")
        }
        try L.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func writeJSON(groups: [PrintGroup], copies: Int, to url: URL,
                           pdfURL: URL, outDir: URL) throws {
        let groupsJSON: [[String: Any]] = groups.map { g in
            ["index": g.index, "pages": g.pages, "print_mode": g.mode.rawValue,
             "label": g.label, "file": g.file]
        }
        let payload: [String: Any] = [
            "copies": copies,
            "groups": groupsJSON,
            "file": pdfURL.lastPathComponent,
            "out_dir": outDir.path,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload,
                                              options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url)
    }
}
