#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
pdf_print_analyzer.py — подготовка сканированного PDF (исполнительная документация)
к печати в нескольких экземплярах.

Что делает:
  1. Прогоняет OCR по страницам (tesseract, rus).
  2. Находит пары «Акт освидетельствования скрытых работ» (лицо + оборот).
  3. Определяет формат листов (A4 / A3) по геометрии страницы.
  4. Режет исходный PDF на пакеты с одинаковыми настройками печати,
     сохраняя исходный порядок страниц.
  5. Пишет план печати для оператора и готовые команды `lp`.

Использование:
    python3 pdf_print_analyzer.py <файл.pdf> [--copies N] [--printer ИМЯ]
                                  [--ocr-cache file.json] [--dpi 100]
                                  [--lang rus] [--json]

Результат — папка «<имя>_print» рядом с исходником:
    batch_NN_<mode>_pX-Y.pdf   пакеты по типу печати
    print_plan.txt             инструкция оператору принтера
    print_commands.sh          готовые команды lp (macOS/Linux)
    print_plan.json            то же в машинночитаемом виде
    ocr_cache.json             кэш OCR (повторный запуск — секунды)

Требования: pymupdf, tesseract с языком rus.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

try:
    import fitz  # PyMuPDF
except ImportError:
    sys.exit("ОШИБКА: нет PyMuPDF. Установите: pip3 install pymupdf")

# Порог «длинной стороны» для A3: A4 = 842 pt, A3 = 1191 pt
A3_THRESHOLD = 1000


# ─────────────────────────────── OCR ────────────────────────────────────────
def ocr_page(page, dpi=100, lang="rus"):
    """Рендерит страницу в оттенках серого и распознаёт текст."""
    mat = fitz.Matrix(dpi / 72, dpi / 72)
    pix = page.get_pixmap(matrix=mat, colorspace=fitz.csGRAY)
    fd, tmp = tempfile.mkstemp(suffix=".png")
    os.close(fd)
    try:
        pix.save(tmp)
        res = subprocess.run(
            ["tesseract", tmp, "stdout", "-l", lang, "--psm", "3",
             "-c", "tessedit_do_invert=0"],
            capture_output=True, text=True, timeout=60,
        )
        if res.returncode != 0:
            return ""
        return res.stdout.strip()
    except FileNotFoundError:
        sys.exit("ОШИБКА: tesseract не найден. macOS: brew install tesseract tesseract-lang")
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def page_format(page):
    r = page.rect
    return "A3" if max(r.width, r.height) > A3_THRESHOLD else "A4"


# ─────────────────────────── классификация ──────────────────────────────────
def classify(text, fmt):
    """ACT_FRONT | ACT_BACK | A3 | A4"""
    if fmt == "A3":
        return "A3"
    t = " ".join(text.lower().split())

    front = ("объект капитальн" in t
             and any(k in t for k in ("застройщик", "технический заказчик",
                                      "лицо, осуществляющ", "заказчик")))
    back = ("составили настоящий акт" in t
            or ("освидетельствован" in t and "предъявлен" in t))

    if front:
        return "ACT_FRONT"
    if back:
        return "ACT_BACK"
    return "A4"


def repair_pairs(page_types, ocr):
    """
    Если оборот акта найден, а лицо — нет (OCR не распознал шапку),
    повышаем предыдущую A4-страницу до ACT_FRONT.
    """
    texts = {i + 1: ocr[i]["text"].lower() for i in range(len(ocr))}
    fixed = 0
    for idx, p in enumerate(page_types):
        if p["type"] != "ACT_BACK":
            continue
        prev = page_types[idx - 1] if idx > 0 else None
        if prev and prev["type"] == "A4" and prev["page"] == p["page"] - 1:
            if "объект капитальн" in texts.get(prev["page"], ""):
                prev["type"] = "ACT_FRONT"
                fixed += 1
    return fixed


# ─────────────────────────── группировка ────────────────────────────────────
def build_groups(page_types):
    groups, i, n = [], 0, len(page_types)
    while i < n:
        t, p = page_types[i]["type"], page_types[i]["page"]

        if t == "ACT_FRONT":
            if i + 1 < n and page_types[i + 1]["type"] == "ACT_BACK":
                groups.append({
                    "pages": [p, page_types[i + 1]["page"]],
                    "print_mode": "duplex_A4",
                    "label": "Акт освидетельствования скрытых работ (двусторонний, длинная сторона)",
                })
                i += 2
            else:
                groups.append({"pages": [p], "print_mode": "simplex_A4",
                               "label": "A4 односторонний (акт без оборота)"})
                i += 1
        elif t == "ACT_BACK":
            groups.append({"pages": [p], "print_mode": "simplex_A4",
                           "label": "A4 односторонний (оборот без лица)"})
            i += 1
        elif t == "A3":
            pages = [p]
            i += 1
            while i < n and page_types[i]["type"] == "A3":
                pages.append(page_types[i]["page"])
                i += 1
            groups.append({"pages": pages, "print_mode": "simplex_A3",
                           "label": "A3 односторонний"})
        else:
            pages = [p]
            i += 1
            while i < n and page_types[i]["type"] == "A4":
                pages.append(page_types[i]["page"])
                i += 1
            groups.append({"pages": pages, "print_mode": "simplex_A4",
                           "label": "A4 односторонний"})
    return groups


# ─────────────────────────── нарезка PDF ────────────────────────────────────
def split_pdf(src, groups, out_dir):
    doc = fitz.open(src)
    for idx, g in enumerate(groups, start=1):
        pages = g["pages"]
        nd = fitz.open()
        for p in pages:
            nd.insert_pdf(doc, from_page=p - 1, to_page=p - 1)
        name = f"batch_{idx:02d}_{g['print_mode']}_p{pages[0]}"
        name += f"-{pages[-1]}.pdf" if len(pages) > 1 else ".pdf"
        nd.save(os.path.join(out_dir, name))
        nd.close()
        g["file"] = name
        g["index"] = idx
    doc.close()


# ─────────────────────────── план печати ────────────────────────────────────
MODE_INFO = {
    "simplex_A4": ("А4", "НЕТ — односторонний"),
    "duplex_A4": ("А4", "ДА — двусторонний по ДЛИННОЙ стороне"),
    "simplex_A3": ("А3", "НЕТ — односторонний"),
}


def write_plan(groups, copies, path):
    L = []
    L.append("=" * 72)
    L.append(f"  ПЛАН ПЕЧАТИ — {copies} экз.")
    L.append("=" * 72)
    L.append("")
    L.append("Печатайте пакеты СТРОГО по порядку номеров: так сохраняется")
    L.append("последовательность листов. После печати разложите по экземплярам.")
    L.append("")
    for g in groups:
        pages = g["pages"]
        rng = f"стр. {pages[0]}" + (f"–{pages[-1]}" if len(pages) > 1 else "")
        media, sides = MODE_INFO[g["print_mode"]]
        L.append(f"Пакет {g['index']:02d}: {g['file']}")
        L.append(f"   Страницы документа : {rng}  ({len(pages)} л.)")
        L.append(f"   Тип                : {g['label']}")
        L.append(f"   Бумага             : {media}")
        L.append(f"   Дуплекс            : {sides}")
        L.append(f"   Экземпляров        : {copies}")
        L.append("")
    L.append("=" * 72)
    L.append(f"Итого листов в одном экземпляре: "
             f"{sum(len(g['pages']) if g['print_mode'] != 'duplex_A4' else len(g['pages']) // 2 for g in groups)}")
    L.append("=" * 72)
    Path(path).write_text("\n".join(L), encoding="utf-8")


def write_sh(groups, copies, printer, path):
    L = ["#!/bin/bash",
         "# Команды печати (CUPS: macOS / Linux). Запуск: bash print_commands.sh",
         ""]
    popt = f'-d "{printer}"' if printer else "-d \"$(lpstat -d | awk '{print $NF}')\""
    for g in groups:
        if g["print_mode"] == "simplex_A4":
            opts = "-o sides=one-sided -o media=A4"
        elif g["print_mode"] == "duplex_A4":
            opts = "-o sides=two-sided-long-edge -o media=A4"
        else:
            opts = "-o sides=one-sided -o media=A3"
        L.append(f"# Пакет {g['index']:02d} — {g['label']}")
        L.append(f"lp {popt} -n {copies} -o collate=true {opts} \"{g['file']}\"")
        L.append("")
    Path(path).write_text("\n".join(L), encoding="utf-8")
    os.chmod(path, 0o755)


def write_json(groups, copies, path, summary):
    data = {
        "copies": copies,
        "groups": [{k: g[k] for k in ("index", "pages", "print_mode", "label", "file")}
                   for g in groups],
        "summary": summary,
    }
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


# ─────────────────────────────── main ───────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="Подготовка PDF к печати в N экземплярах")
    ap.add_argument("pdf")
    ap.add_argument("--copies", type=int, default=4)
    ap.add_argument("--printer", default="")
    ap.add_argument("--ocr-cache", default="")
    ap.add_argument("--dpi", type=int, default=100)
    ap.add_argument("--lang", default="rus")
    ap.add_argument("--json", action="store_true", help="печатать итог в JSON")
    args = ap.parse_args()

    src = os.path.abspath(args.pdf)
    if not os.path.isfile(src):
        sys.exit(f"ОШИБКА: файл не найден: {src}")

    out_dir = str(Path(src).parent / (Path(src).stem + "_print"))
    os.makedirs(out_dir, exist_ok=True)
    log = (lambda *a: None) if args.json else print
    log(f"Папка результата: {out_dir}")

    cache = args.ocr_cache or os.path.join(out_dir, "ocr_cache.json")
    if os.path.exists(cache):
        log(f"Кэш OCR: {cache}")
        ocr = json.loads(Path(cache).read_text(encoding="utf-8"))
    else:
        log("OCR страниц (это займёт несколько минут)...")
        doc = fitz.open(src)
        ocr = []
        for i, page in enumerate(doc, start=1):
            fmt = page_format(page)
            text = "" if fmt == "A3" else ocr_page(page, args.dpi, args.lang)
            ocr.append({"page": i, "fmt": fmt, "text": text})
            if i % 10 == 0 or i == len(doc):
                log(f"  OCR {i}/{len(doc)}")
        doc.close()
        Path(cache).write_text(json.dumps(ocr, ensure_ascii=False), encoding="utf-8")

    page_types = [{"page": o["page"], "type": classify(o["text"], o["fmt"]), "fmt": o["fmt"]}
                  for o in ocr]
    fixed = repair_pairs(page_types, ocr)

    cnt = Counter(p["type"] for p in page_types)
    groups = build_groups(page_types)
    split_pdf(src, groups, out_dir)

    plan_txt = os.path.join(out_dir, "print_plan.txt")
    plan_sh = os.path.join(out_dir, "print_commands.sh")
    plan_json = os.path.join(out_dir, "print_plan.json")
    write_plan(groups, args.copies, plan_txt)
    write_sh(groups, args.copies, args.printer, plan_sh)

    summary = {
        "file": os.path.basename(src),
        "out_dir": out_dir,
        "pages": len(page_types),
        "acts": cnt["ACT_FRONT"] + cnt["ACT_BACK"],
        "act_pairs": cnt["ACT_FRONT"],
        "a3_sheets": cnt["A3"],
        "groups": len(groups),
        "copies": args.copies,
        "repaired_fronts": fixed,
        "plan_txt": plan_txt,
        "plan_sh": plan_sh,
    }
    write_json(groups, args.copies, plan_json, summary)

    if args.json:
        print(json.dumps(summary, ensure_ascii=False))
    else:
        print(f"\nСтраниц: {summary['pages']}  |  актов: {summary['act_pairs']}  "
              f"|  листов A3: {summary['a3_sheets']}  |  пакетов: {summary['groups']}")
        print(f"✓ Готово: {out_dir}")


if __name__ == "__main__":
    main()
