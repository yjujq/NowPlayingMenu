#!/bin/bash
# Собирает NowPlayingMenu.app из исполняемого файла Swift Package.
set -euo pipefail
cd "$(dirname "$0")"

APP="NowPlayingMenu.app"
echo "==> сборка"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> сборка бандла"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppBundle/Info.plist "$APP/Contents/Info.plist"
cp "$BIN_DIR/NowPlayingMenu" "$APP/Contents/MacOS/NowPlayingMenu"

# Ресурсный пакет кладём в оба места: способ его поиска зависит от того,
# как собран исполняемый файл, и так надёжнее.
RES="NowPlayingMenu_NowPlayingMenu.bundle"
if [ -d "$BIN_DIR/$RES" ]; then
    cp -R "$BIN_DIR/$RES" "$APP/Contents/Resources/$RES"
    cp -R "$BIN_DIR/$RES" "$APP/Contents/MacOS/$RES"
fi

# Расширенные атрибуты ломают подпись: codesign отказывается работать
# с "resource fork, Finder information".
xattr -cr "$APP" 2>/dev/null || true

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1 && /\)/ {print $2}')
if [ -n "${IDENTITY:-}" ]; then
    echo "==> подпись ($IDENTITY)"
    codesign --force --deep --sign "$IDENTITY" "$APP"
else
    echo "==> подпись ad-hoc"
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --verbose=1 "$APP" 2>&1 | tail -1

echo
echo "Готово: $(pwd)/$APP"
