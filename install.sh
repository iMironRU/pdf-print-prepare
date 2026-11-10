#!/bin/bash
# Установка «PDF к печати» одной командой.
#
#   curl -fsSL https://raw.githubusercontent.com/iMironRU/pdf-print-prepare/main/install.sh | bash
#
# Что делает: скачивает последнюю версию приложения, кладёт в /Applications,
# снимает карантин (приложение не нотаризовано) и запускает.
# Никаких паролей, Python, Homebrew и Xcode не требуется — OCR встроен в macOS.

set -euo pipefail

REPO="iMironRU/pdf-print-prepare"
ASSET_URL="https://github.com/${REPO}/releases/latest/download/PDFPrintPrepare.zip"
APP_NAME="PDFPrintPrepare.app"
DISPLAY_NAME="PDF к печати"

say()  { printf '%s\n' "$*"; }
fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }

say "── PDF к печати · установка ──────────────────────────"

# 1. Проверка системы
os_version=$(sw_vers -productVersion 2>/dev/null || echo "0")
major=${os_version%%.*}
if [ "${major:-0}" -lt 11 ]; then
    fail "нужен macOS 11 или новее (у вас ${os_version})"
fi
say "macOS ${os_version} — подходит"

# 2. Куда ставить
if [ -w /Applications ]; then
    DEST="/Applications"
else
    DEST="$HOME/Applications"
    mkdir -p "$DEST"
fi
say "Папка установки: ${DEST}"

# 3. Скачивание
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

say "Скачиваю приложение…"
if ! curl -fL --progress-bar "$ASSET_URL" -o "$TMP_DIR/app.zip"; then
    fail "не удалось скачать ${ASSET_URL}
Проверьте интернет или скачайте вручную: https://github.com/${REPO}/releases/latest"
fi

# 4. Распаковка
say "Распаковываю…"
/usr/bin/ditto -x -k "$TMP_DIR/app.zip" "$TMP_DIR/unpacked" || fail "архив повреждён"
[ -d "$TMP_DIR/unpacked/${APP_NAME}" ] || fail "в архиве нет ${APP_NAME}"

# 5. Установка (старая копия заменяется)
if [ -d "${DEST}/${APP_NAME}" ]; then
    say "Обновляю предыдущую версию…"
    rm -rf "${DEST:?}/${APP_NAME}"
fi
/usr/bin/ditto "$TMP_DIR/unpacked/${APP_NAME}" "${DEST}/${APP_NAME}"

# 6. Карантин и регистрация
xattr -dr com.apple.quarantine "${DEST}/${APP_NAME}" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "${DEST}/${APP_NAME}" >/dev/null 2>&1 || true

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
          "${DEST}/${APP_NAME}/Contents/Info.plist" 2>/dev/null || echo "?")
say "Установлено: ${DEST}/${APP_NAME} (версия ${VERSION})"

# 7. Запуск
open "${DEST}/${APP_NAME}" 2>/dev/null || true

say ""
say "Готово. Дальше: перетащите PDF в окно «${DISPLAY_NAME}» —"
say "приложение разложит документ на пакеты и откроет папку с результатом."
say ""
say "Удалить приложение: rm -rf \"${DEST}/${APP_NAME}\""
