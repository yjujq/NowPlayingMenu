#!/bin/bash
# Собирает NowPlayingMenu.app и, если попросили, ставит его в /Applications.
#
# Бандл собирается во временной папке вне ~/Documents: эта папка синхронизируется
# с iCloud, а файловый провайдер помечает файлы атрибутами com.apple.FinderInfo
# и com.apple.fileprovider, которые codesign отвергает и которые возвращаются
# после очистки на месте.
set -euo pipefail
cd "$(dirname "$0")"
PROJECT="$(pwd)"

APP="NowPlayingMenu.app"
STAGE="$(mktemp -d /tmp/nowplayingmenu-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

echo "==> сборка"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> сборка бандла во временной папке"
mkdir -p "$STAGE/$APP/Contents/MacOS" "$STAGE/$APP/Contents/Resources"
cp "$PROJECT/AppBundle/Info.plist" "$STAGE/$APP/Contents/Info.plist"
cp "$BIN_DIR/NowPlayingMenu" "$STAGE/$APP/Contents/MacOS/NowPlayingMenu"

# Ресурсный пакет только в Contents/Resources: копия рядом с исполняемым
# файлом это нестандартное место для вложенного кода, подпись её отвергает.
# Иконка: пересобираем из набора размеров, если он на месте.
if [ -d "$PROJECT/AppIcon.iconset" ]; then
    iconutil -c icns "$PROJECT/AppIcon.iconset" -o "$PROJECT/AppIcon.icns"
fi
[ -f "$PROJECT/AppIcon.icns" ] && cp "$PROJECT/AppIcon.icns" "$STAGE/$APP/Contents/Resources/AppIcon.icns"

RES="NowPlayingMenu_NowPlayingMenu.bundle"
[ -d "$BIN_DIR/$RES" ] && cp -R "$BIN_DIR/$RES" "$STAGE/$APP/Contents/Resources/$RES"

xattr -cr "$STAGE/$APP" 2>/dev/null || true

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1 && /\)/ {print $2}')
if [ -n "${IDENTITY:-}" ]; then
    echo "==> подпись ($IDENTITY)"
    codesign --force --deep --sign "$IDENTITY" "$STAGE/$APP"
else
    echo "==> подпись ad-hoc"
    codesign --force --deep --sign - "$STAGE/$APP"
fi

if codesign --verify --strict --deep "$STAGE/$APP" 2>/tmp/nowplaying-codesign.txt; then
    echo "==> подпись действительна"
else
    echo "ОШИБКА: подпись не прошла проверку" >&2
    cat /tmp/nowplaying-codesign.txt >&2
    exit 1
fi

if [ "${1:-}" = "--install" ]; then
    echo "==> установка в /Applications"
    rm -rf "/Applications/$APP"
    ditto "$STAGE/$APP" "/Applications/$APP"
    echo "    /Applications/$APP"
else
    rm -rf "$PROJECT/$APP"
    ditto "$STAGE/$APP" "$PROJECT/$APP"
    echo "Готово: $PROJECT/$APP (для установки: ./make-app.sh --install)"
fi
