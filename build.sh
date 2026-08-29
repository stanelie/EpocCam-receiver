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

# NDI: base SDK by default. The Advanced SDK adds H.264 passthrough, but its development
# license stops delivering the stream after 30 minutes on desktop (silently — the sender
# keeps reporting success while receivers get nothing), so it is opt-in and must not be
# used for shows without a commercial license.
#   ./build.sh                      -> base SDK, SpeedHQ only, no time limit
#   USE_NDI_ADVANCED=1 ./build.sh   -> Advanced SDK, adds H.264 passthrough, 30-min trial
if [ "${USE_NDI_ADVANCED:-0}" = "1" ]; then
  NDI_SDK="/Library/NDI Advanced SDK for Apple"
  NDI_LIB="libndi_advanced.dylib"
  NDI_DEFINE="-DNDI_ADVANCED=1"
  echo "==> NDI: Advanced SDK (H.264 passthrough enabled — 30-MINUTE TRIAL LIMIT)"
else
  NDI_SDK="/Library/NDI SDK for Apple"
  NDI_LIB="libndi.dylib"
  NDI_DEFINE=""
  echo "==> NDI: base SDK (SpeedHQ only, no time limit)"
fi
if [ ! -f "$NDI_SDK/lib/macOS/$NDI_LIB" ]; then
  echo "!! NDI SDK not found at $NDI_SDK — install it from ndi.video" >&2
  exit 1
fi

echo "==> Copying $NDI_LIB"
cp "$NDI_SDK/lib/macOS/$NDI_LIB" "$FW/"
# Its install name is already @rpath/libndi.dylib, and the binary below is linked with
# an @executable_path/../Frameworks rpath, so no install_name_tool fixup is needed.

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

  clang \
    -arch $ARCH \
    -isysroot "$SDK" \
    -mmacosx-version-min=$MIN \
    -fobjc-arc \
    -fmodules \
    -F"$PROJ/Frameworks" \
    -I"$PROJ/Sources" \
    -I"$NDI_SDK/include" \
    $NDI_DEFINE \
    -c "$PROJ/Sources/NDIBridge.m" \
    -o "$OBJDIR/$ARCH/NDIBridge.o"
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
    "$OBJDIR/$ARCH/NDIBridge.o" \
    "$NDI_SDK/lib/macOS/$NDI_LIB" \
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
