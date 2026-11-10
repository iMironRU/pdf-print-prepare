#!/bin/bash
# Проверка и установка зависимостей для PDFPrintPrepare.
set -uo pipefail

echo "=== Проверка зависимостей ==="
ok=1

# Python 3
if command -v python3 >/dev/null 2>&1; then
    echo "✓ python3: $(python3 -V 2>&1)"
else
    echo "✗ python3 не найден. Установите Xcode Command Line Tools: xcode-select --install"
    ok=0
fi

# PyMuPDF
if python3 -c "import fitz" >/dev/null 2>&1; then
    echo "✓ PyMuPDF: $(python3 -c 'import fitz; print(fitz.__doc__.split()[1])' 2>/dev/null)"
else
    echo "✗ нет PyMuPDF — устанавливаю..."
    python3 -m pip install --user --quiet pymupdf && echo "✓ PyMuPDF установлен" || { echo "✗ Не удалось установить"; ok=0; }
fi

# Pillow (для иконки при сборке)
if python3 -c "import PIL" >/dev/null 2>&1; then
    echo "✓ Pillow (нужен только для сборки .app)"
else
    echo "· Pillow нет — установите при сборке .app: pip3 install pillow"
fi

# Tesseract
if command -v tesseract >/dev/null 2>&1; then
    echo "✓ tesseract: $(tesseract --version 2>&1 | head -1)"
    if tesseract --list-langs 2>&1 | grep -qx "rus"; then
        echo "✓ язык rus установлен"
    else
        echo "✗ нет языка rus — brew install tesseract-lang"
        ok=0
    fi
else
    echo "✗ tesseract не найден — brew install tesseract tesseract-lang"
    ok=0
fi

echo
if [ "$ok" = "1" ]; then
    echo "Всё готово. Дальше: python3 pdf_print_analyzer.py файл.pdf --copies 4"
else
    echo "Устраните проблемы выше и запустите снова."
    exit 1
fi
