#!/bin/bash
set -e

cd "$(dirname "$0")"

APP_DIR="/Applications/MacExplorer.app"
ENTITLEMENTS="MacExplorer/MacExplorer.entitlements"

# If the source lives on a non-native filesystem (e.g. an ExFAT USB drive),
# SwiftPM's .build tree — symlinks + codesigned bundles — can't be written
# there. Build into a local scratch dir in that case.
FSTYPE="$(stat -f%T . 2>/dev/null || echo unknown)"
SCRATCH_ARGS=""
if [ "$FSTYPE" != "apfs" ] && [ "$FSTYPE" != "hfs" ]; then
    SCRATCH_DIR="${TMPDIR:-/tmp}/macexplorer-build"
    mkdir -p "$SCRATCH_DIR"
    SCRATCH_ARGS="--scratch-path $SCRATCH_DIR"
    echo "(source on '$FSTYPE' filesystem — building into $SCRATCH_DIR)"
fi

echo "Building..."
swift build --disable-sandbox $SCRATCH_ARGS 2>&1 | tail -3
BIN_DIR="$(swift build --disable-sandbox $SCRATCH_ARGS --show-bin-path 2>/dev/null)"

echo "Deploying to /Applications..."
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/MacExplorer" "$APP_DIR/Contents/MacOS/MacExplorer"
cp MacExplorer/Resources/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null || true

# Write Info.plist (only if missing or needs update)
cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MacExplorer</string>
    <key>CFBundleIdentifier</key>
    <string>com.macexplorer.app</string>
    <key>CFBundleName</key>
    <string>MacExplorer</string>
    <key>CFBundleDisplayName</key>
    <string>MacExplorer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Folder</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.folder</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "Code signing with entitlements..."
xattr -cr "$APP_DIR" 2>/dev/null
# Prefer a stable local identity so Full Disk Access persists across rebuilds.
# (An ad-hoc signature changes every build, so macOS re-prompts for FDA each time.)
# Create the cert once with setup-signing.sh; falls back to ad-hoc if absent.
if security find-certificate -c "MacExplorer Local" >/dev/null 2>&1; then
    SIGN_ID="MacExplorer Local"
else
    echo "  (no 'MacExplorer Local' cert found — using ad-hoc; FDA will re-prompt each build. Run ./setup-signing.sh once to fix.)"
    SIGN_ID="-"
fi
codesign --force --sign "$SIGN_ID" --entitlements "$ENTITLEMENTS" --identifier "com.macexplorer.app" "$APP_DIR"

echo "Registering with Launch Services..."
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$APP_DIR"

echo "Launching..."
# Kill any existing instance first so the new binary is loaded
pkill -x MacExplorer 2>/dev/null || true
sleep 0.5
open "$APP_DIR"
echo "Done!"
