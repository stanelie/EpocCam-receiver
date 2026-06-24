#!/bin/bash
set -e
PROJ="$(cd "$(dirname "$0")" && pwd)"
SDK=$(xcrun --show-sdk-path)
MIN=11.0
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
install_name_tool -id \
  "@rpath/Syphon.framework/Versions/A/Syphon" \
  "$FW/Syphon.framework/Versions/A/Syphon"

echo "==> Compiling SyphonBridge.m (arm64 + x86_64)"
OBJDIR="$BUILD/obj"
mkdir -p "$OBJDIR/arm64" "$OBJDIR/x86_64"

for ARCH in arm64 x86_64; do
  clang \
    -arch $ARCH \
    -isysroot "$SDK" \
    -mmacosx-version-min=$MIN \
    -fobjc-arc \
    -fmodules \
    -F"$PROJ/Frameworks" \
    -I"$PROJ/Sources" \
    -c "$PROJ/Sources/SyphonBridge.m" \
    -o "$OBJDIR/$ARCH/SyphonBridge.o"
done

echo "==> Compiling Swift sources (arm64 + x86_64)"
SWIFT_SRCS=(
  "$PROJ/Sources/main.swift"
  "$PROJ/Sources/Protocol.swift"
  "$PROJ/Sources/VideoDecoder.swift"
  "$PROJ/Sources/Connection.swift"
  "$PROJ/Sources/Browser.swift"
  "$PROJ/Sources/VideoView.swift"
  "$PROJ/Sources/AppDelegate.swift"
)

for ARCH in arm64 x86_64; do
  swiftc \
    -target $ARCH-apple-macos$MIN \
    -sdk "$SDK" \
    -import-objc-header "$PROJ/BridgingHeader.h" \
    -F"$PROJ/Frameworks" \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "${SWIFT_SRCS[@]}" \
    "$OBJDIR/$ARCH/SyphonBridge.o" \
    -framework Cocoa \
    -framework AVFoundation \
    -framework CoreVideo \
    -framework CoreMedia \
    -framework VideoToolbox \
    -framework OpenGL \
    -framework IOSurface \
    -framework Network \
    -framework Syphon \
    -o "$OBJDIR/$ARCH/EpocCamViewer"
done

echo "==> Creating universal binary"
lipo -create \
  "$OBJDIR/arm64/EpocCamViewer" \
  "$OBJDIR/x86_64/EpocCamViewer" \
  -output "$MACOS/EpocCamViewer"

echo "==> Copying Info.plist"
cp "$PROJ/Resources/Info.plist" "$APP/Contents/Info.plist"

echo ""
lipo -info "$MACOS/EpocCamViewer"
echo "✓  Built: $APP"
echo "   Run:   open \"$APP\""
