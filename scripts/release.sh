#!/usr/bin/env bash
# Build, sign, notarize, staple, and package Switch for distribution.
# Usage: scripts/release.sh <version> [build]
#   <version>  CFBundleShortVersionString, e.g. 0.1.5
#   [build]    CFBundleVersion. Defaults to current value in Info.plist + 1.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

VERSION="${1:-}"
BUILD_NUMBER="${2:-}"
if [[ -z "$VERSION" ]]; then
    echo "usage: $0 <version> [build]  (e.g. 0.1.5 4)"
    exit 1
fi

NOTARY_PROFILE="switch-notary"
APP_NAME="Switch"
TEAM_ID="WCAFS55H9G"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
DMG_STAGE="$BUILD_DIR/dmg-stage"
INFO_PLIST="$PROJECT_DIR/Sources/$APP_NAME/Resources/Info.plist"

if [[ -z "$BUILD_NUMBER" ]]; then
    CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")
    BUILD_NUMBER=$((CURRENT_BUILD + 1))
fi

echo "==> Stamping Info.plist: version=$VERSION build=$BUILD_NUMBER"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"

COMMIT_SHA=$(git rev-parse --short HEAD)
BUILD_DATE=$(date -u "+%Y-%m-%d %H:%MZ")
/usr/libexec/PlistBuddy -c "Delete :BuildCommit" "$INFO_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :BuildDate" "$INFO_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :BuildCommit string $COMMIT_SHA" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Add :BuildDate string $BUILD_DATE" "$INFO_PLIST"
echo "    (stamp $COMMIT_SHA · $BUILD_DATE)"

cleanup_stamps() {
    /usr/libexec/PlistBuddy -c "Delete :BuildCommit" "$INFO_PLIST" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Delete :BuildDate" "$INFO_PLIST" 2>/dev/null || true
}
trap cleanup_stamps EXIT

echo "==> Cleaning build dir"
rm -rf "$BUILD_DIR"
mkdir -p "$EXPORT_DIR"

echo "==> Regenerating Xcode project"
xcodegen generate

echo "==> Archiving Release build"
xcodebuild -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination 'platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    archive

cat > "$BUILD_DIR/exportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>teamID</key>
    <string>$TEAM_ID</string>
    <key>signingStyle</key>
    <string>manual</string>
</dict>
</plist>
EOF

echo "==> Exporting signed app"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/exportOptions.plist"

echo "==> Submitting app to notary service"
APP_ZIP="$BUILD_DIR/$APP_NAME.zip"
ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling app"
xcrun stapler staple "$APP_PATH"

echo "==> Building DMG"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

hdiutil create -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGE" \
    -ov -format UDZO \
    "$DMG_PATH"

echo "==> Submitting DMG to notary service"
xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait

echo "==> Stapling DMG"
xcrun stapler staple "$DMG_PATH"

echo ""
echo "==> Verify"
spctl --assess --type execute --verbose "$APP_PATH"
xcrun stapler validate "$DMG_PATH"

echo ""
echo "==> Signing update for Sparkle appcast"
SIGN_UPDATE=$(find "$HOME/Library/Developer/Xcode/DerivedData" -path "*Sparkle/bin/sign_update" -type f -print -quit 2>/dev/null)
APPCAST_ITEM=""
if [[ -x "$SIGN_UPDATE" ]]; then
    SIGN_OUT=$("$SIGN_UPDATE" "$DMG_PATH")
    PUB_DATE=$(date -u "+%a, %d %b %Y %H:%M:%S +0000")
    APPCAST_ITEM=$(cat <<EOF
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure url="https://github.com/Sanyam-G/switch/releases/download/v$VERSION/Switch-$VERSION.dmg"
                       type="application/octet-stream"
                       $SIGN_OUT />
        </item>
EOF
)
    echo "$APPCAST_ITEM"
else
    echo "    (sign_update not found, skipping appcast snippet — add Sparkle SPM dep first)"
fi

echo ""
echo "==> Cleaning intermediate build artifacts"
rm -rf "$DMG_STAGE" "$EXPORT_DIR" "$ARCHIVE_PATH" "$APP_ZIP"

echo ""
echo "==> Done"
ls -lh "$DMG_PATH"
echo ""
echo "Upload to GitHub Releases:"
echo "  $DMG_PATH"
if [[ -n "$APPCAST_ITEM" ]]; then
    echo ""
    echo "Paste the appcast <item> above into ~/Projects/dev/switch/appcast.xml as the newest entry."
fi
