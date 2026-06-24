#!/bin/bash
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
SDK=$(xcrun --show-sdk-path)
ARCH=arm64
MIN=13.0
BUILD="$PROJ/.build"
APP="$BUILD/EpocCamViewer.app"
MACOS="$APP/Contents/MacOS"
FW="$APP/Contents/Frameworks"
RES="$APP/Contents/Resources"

echo "==> Cleaning build dir"
rm -rf "$BUILD"
mkdir -p "$MACOS" "$FW" "$RES"

echo "==> Copying Syphon.framework"
cp -R "$PROJ/Frameworks/Syphon.framework" "$FW/"
# Fix the install name in the copy to use @rpath
install_name_tool -id \
  "@rpath/Syphon.framework/Versions/A/Syphon" \
  "$FW/Syphon.framework/Versions/A/Syphon"

echo "==> Compiling SyphonBridge.m"
OBJDIR="$BUILD/obj"
mkdir -p "$OBJDIR"
clang \
  -arch $ARCH \
  -isysroot "$SDK" \
  -mmacosx-version-min=$MIN \
  -fobjc-arc \
  -fmodules \
  -F"$PROJ/Frameworks" \
  -I"$PROJ/Sources" \
  -c "$PROJ/Sources/SyphonBridge.m" \
  -o "$OBJDIR/SyphonBridge.o"

echo "==> Compiling Swift sources"
swiftc \
  -target $ARCH-apple-macos$MIN \
  -sdk "$SDK" \
  -import-objc-header "$PROJ/BridgingHeader.h" \
  -F"$PROJ/Frameworks" \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  "$PROJ/Sources/main.swift" \
  "$PROJ/Sources/Protocol.swift" \
  "$PROJ/Sources/VideoDecoder.swift" \
  "$PROJ/Sources/Connection.swift" \
  "$PROJ/Sources/Browser.swift" \
  "$PROJ/Sources/VideoView.swift" \
  "$PROJ/Sources/AppDelegate.swift" \
  "$OBJDIR/SyphonBridge.o" \
  -framework Cocoa \
  -framework AVFoundation \
  -framework CoreVideo \
  -framework CoreMedia \
  -framework VideoToolbox \
  -framework OpenGL \
  -framework IOSurface \
  -framework Network \
  -framework Syphon \
  -o "$MACOS/EpocCamViewer"

echo "==> Copying Info.plist"
cp "$PROJ/Resources/Info.plist" "$APP/Contents/Info.plist"

echo ""
echo "✓  Built: $APP"
echo "   Run:   open \"$APP\""
