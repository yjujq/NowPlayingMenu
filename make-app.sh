#!/bin/bash
# Builds NowPlayingMenu.app and, if asked, installs it into /Applications.
#
# The bundle is staged in a temporary folder outside ~/Documents: that folder
# syncs with iCloud, and the file provider stamps files with com.apple.FinderInfo
# and com.apple.fileprovider attributes, which codesign rejects and which come
# straight back if cleaned in place.
set -euo pipefail
cd "$(dirname "$0")"
PROJECT="$(pwd)"

APP="NowPlayingMenu.app"
STAGE="$(mktemp -d /tmp/nowplayingmenu-build.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

# Built outside the project for the same reason: the Desktop syncs too, and
# swift build's own signing of the resource bundle fails on the same
# attributes.
BUILD="$HOME/Library/Caches/NowPlayingMenu-build"

echo "==> building"
swift build -c release --scratch-path "$BUILD"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD" --show-bin-path)"

echo "==> staging the bundle in a temporary folder"
mkdir -p "$STAGE/$APP/Contents/MacOS" "$STAGE/$APP/Contents/Resources"
cp "$PROJECT/AppBundle/Info.plist" "$STAGE/$APP/Contents/Info.plist"
cp "$BIN_DIR/NowPlayingMenu" "$STAGE/$APP/Contents/MacOS/NowPlayingMenu"

# The resource bundle goes only into Contents/Resources: a copy beside the
# executable is a non-standard place for nested code and the signature rejects it.
# Icon: rebuild it from the size set if that set is present.
if [ -d "$PROJECT/AppIcon.iconset" ]; then
    iconutil -c icns "$PROJECT/AppIcon.iconset" -o "$PROJECT/AppIcon.icns"
fi
[ -f "$PROJECT/AppIcon.icns" ] && cp "$PROJECT/AppIcon.icns" "$STAGE/$APP/Contents/Resources/AppIcon.icns"

# The artwork helper is a library perl loads, not the app: it goes where a
# bundle keeps its libraries, and the app looks for it there.
mkdir -p "$STAGE/$APP/Contents/Frameworks"
cp "$BIN_DIR/libArtworkHelper.dylib" "$STAGE/$APP/Contents/Frameworks/libArtworkHelper.dylib"

RES="NowPlayingMenu_NowPlayingMenu.bundle"
[ -d "$BIN_DIR/$RES" ] && cp -R "$BIN_DIR/$RES" "$STAGE/$APP/Contents/Resources/$RES"

xattr -cr "$STAGE/$APP" 2>/dev/null || true

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk 'NR==1 && /\)/ {print $2}')
if [ -n "${IDENTITY:-}" ]; then
    echo "==> signing ($IDENTITY)"
    codesign --force --deep --sign "$IDENTITY" "$STAGE/$APP"
else
    echo "==> ad-hoc signing"
    codesign --force --deep --sign - "$STAGE/$APP"
fi

if codesign --verify --strict --deep "$STAGE/$APP" 2>/tmp/nowplaying-codesign.txt; then
    echo "==> signature is valid"
else
    echo "ERROR: the signature failed verification" >&2
    cat /tmp/nowplaying-codesign.txt >&2
    exit 1
fi

if [ "${1:-}" = "--install" ]; then
    echo "==> installing into /Applications"
    rm -rf "/Applications/$APP"
    ditto "$STAGE/$APP" "/Applications/$APP"
    echo "    /Applications/$APP"
else
    rm -rf "$PROJECT/$APP"
    ditto "$STAGE/$APP" "$PROJECT/$APP"
    echo "Done: $PROJECT/$APP (to install: ./make-app.sh --install)"
fi
