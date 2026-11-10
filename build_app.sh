#!/bin/bash
# Собирает PDFPrintPrepare.app (универсальный бинарник для Apple Silicon и Intel).
set -euo pipefail

cd "$(dirname "$0")"
ROOT="$PWD"
APP="$ROOT/build/PDFPrintPrepare.app"
BUNDLE_ID="ru.imiron.pdfprintprepare"

echo "▸ Чистим build/"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Иконка"
python3 scripts/make_icon.py

echo "▸ Компиляция Swift (arm64 + x86_64)"
mkdir -p build/tmp
swiftc -O -swift-version 5 \
    -target arm64-apple-macos12.0 \
    app/PDFPrintPrepare.swift -o build/tmp/app-arm64 \
    -framework Cocoa
swiftc -O -swift-version 5 \
    -target x86_64-apple-macos12.0 \
    app/PDFPrintPrepare.swift -o build/tmp/app-x86_64 \
    -framework Cocoa
lipo -create build/tmp/app-arm64 build/tmp/app-x86_64 \
     -output "$APP/Contents/MacOS/PDFPrintPrepare"
strip -x "$APP/Contents/MacOS/PDFPrintPrepare" || true

echo "▸ Ресурсы"
cp app/Info.plist "$APP/Contents/Info.plist"
cp app/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp pdf_print_analyzer.py "$APP/Contents/Resources/pdf_print_analyzer.py"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ Подпись (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (подпись пропущена)"

echo "▸ Регистрация в LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

rm -rf build/tmp
echo "✓ Готово: $APP"
echo "  Перетащите .app в /Applications и бросайте на него PDF."
