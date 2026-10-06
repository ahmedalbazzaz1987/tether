#!/bin/bash
# Builds Tether.app with the Xcode Command Line Tools only (no Xcode project needed).
#   ./build.sh            build for this Mac and put Tether.app in ./build
#   ./build.sh --install  also copy it to /Applications (or ~/Applications)
#   ./build.sh --release  universal (Apple silicon + Intel) build + build/Tether-macOS.zip for GitHub
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION 2>/dev/null || echo 1.0.0)"
BUILD="$(date +%Y%m%d%H%M)"
APP="build/Tether.app"
MIN_OS="13.0"
RELEASE=0; INSTALL=0
for a in "$@"; do
  case "$a" in
    --release) RELEASE=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option $a"; exit 1 ;;
  esac
done

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Swift compiler not found. Install the Command Line Tools with:  xcode-select --install"
  exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=$(find Sources -name '*.swift' | sort)

# Recent SDKs implement SwiftUI's @State as a macro. Xcode passes the macro
# plugin paths automatically; a bare swiftc needs them spelled out.
SWIFTC_BIN="$(xcrun -f swiftc)"
TOOLCHAIN="$(dirname "$(dirname "$(dirname "$SWIFTC_BIN")")")"
PLUGIN_SERVER="$TOOLCHAIN/usr/bin/swift-plugin-server"
PLUGIN_FLAGS=()
for d in "$TOOLCHAIN/usr/lib/swift/host/plugins" "$TOOLCHAIN/usr/local/lib/swift/host/plugins"; do
  [ -d "$d" ] && PLUGIN_FLAGS+=(-plugin-path "$d")
done
if [ -x "$PLUGIN_SERVER" ]; then
  for d in "$SDK/usr/lib/swift/host/plugins" "$SDK/usr/local/lib/swift/host/plugins"; do
    [ -d "$d" ] && PLUGIN_FLAGS+=(-external-plugin-path "$d#$PLUGIN_SERVER")
  done
fi
if ! ls "$TOOLCHAIN"/usr/lib/swift/host/plugins/*SwiftUIMacros* >/dev/null 2>&1 \
   && ! ls "$SDK"/usr/lib/swift/host/plugins/*SwiftUIMacros* >/dev/null 2>&1; then
  FOUND="$(find "$TOOLCHAIN" "$SDK" -maxdepth 8 -name '*SwiftUIMacros*' 2>/dev/null | head -1 || true)"
  if [ -n "$FOUND" ]; then
    DIR="$(dirname "$FOUND")"
    if [ -x "$PLUGIN_SERVER" ]; then PLUGIN_FLAGS+=(-external-plugin-path "$DIR#$PLUGIN_SERVER")
    else PLUGIN_FLAGS+=(-plugin-path "$DIR"); fi
  fi
fi

compile() { # $1 = arch, $2 = output
  echo "• Compiling for $1…"
  swiftc -O -wmo -swift-version 5 \
    -target "$1-apple-macos$MIN_OS" -sdk "$SDK" \
    -module-name Tether ${PLUGIN_FLAGS[@]+"${PLUGIN_FLAGS[@]}"} \
    $SOURCES -o "$2"
}

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

if [ "$RELEASE" = 1 ]; then
  compile arm64 build/obj/Tether-arm64
  compile x86_64 build/obj/Tether-x86_64
  lipo -create build/obj/Tether-arm64 build/obj/Tether-x86_64 -output "$APP/Contents/MacOS/Tether"
else
  compile "$(uname -m)" "$APP/Contents/MacOS/Tether"
fi
strip -x "$APP/Contents/MacOS/Tether" 2>/dev/null || true

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature with a stable designated requirement, so macOS keeps the
# Screen Recording / Accessibility permissions across updates.
codesign --force --sign - --identifier com.novamira.tether \
  --requirements '=designated => identifier "com.novamira.tether"' \
  "$APP"
rm -rf build/obj

SIZE=$(du -sh "$APP" | cut -f1)
echo "✓ Built $APP ($SIZE, version $VERSION)"

if [ "$RELEASE" = 1 ]; then
  (cd build && ditto -c -k --keepParent Tether.app Tether-macOS.zip)
  echo "✓ Release archive: build/Tether-macOS.zip  (attach it to a GitHub release named v$VERSION)"
fi

if [ "$INSTALL" = 1 ]; then
  DEST="/Applications"
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x Tether 2>/dev/null && sleep 1 || true
  rm -rf "$DEST/Tether.app"
  cp -R "$APP" "$DEST/"
  echo "✓ Installed to $DEST/Tether.app"
  open "$DEST/Tether.app"
fi
