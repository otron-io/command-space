#!/bin/zsh
# Builds "Command Space.app" (and, with --dmg, Command-Space.dmg plus a signed appcast entry).
#
#   scripts/build-app.sh            # Release build → build/Command Space.app
#   scripts/build-app.sh --dmg      # also the DMG and appcast.xml entry, for a GitHub release
#   scripts/build-app.sh --install  # also copy to /Applications and relaunch
#   SIGN_IDENTITY=- scripts/build-app.sh   # ad-hoc (Accessibility must be re-granted after each build)
#
# Uses xcodebuild on Package.swift (not `swift build`) so package resource bundles are found
# in Contents/Resources.
set -euo pipefail
REPO="${0:A:h:h}"
OUT="$REPO/build"
DERIVED="$OUT/DerivedData"
APP="$OUT/Command Space.app"
TMP=$(mktemp -d)
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ && !/REVOKED|EXPIRED/ {print $2; exit}')}"
IDENTITY="${IDENTITY:--}"

cd "$REPO"
xcodebuild -scheme CommandSpace -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO build -quiet
PRODUCTS="$DERIVED/Build/Products/Release"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$PRODUCTS/CommandSpace" "$APP/Contents/MacOS/Command Space"
cp "$REPO/Resources/Info.plist" "$APP/Contents/Info.plist"
for bundle in "$PRODUCTS"/*.bundle(N); do ditto "$bundle" "$APP/Contents/Resources/${bundle:t}"; done
SPARKLE=$(find "$PRODUCTS" "$DERIVED/SourcePackages/artifacts" -name Sparkle.framework -path '*macos*' -o -name Sparkle.framework -path '*Release*' 2>/dev/null | head -1)
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/Command Space" 2>/dev/null || true

# Icon, drawn by the app itself.
"$APP/Contents/MacOS/Command Space" --render-icon "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Sign inside out: Sparkle's helpers, the framework, then the app.
sign() { codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$@"; }
FW="$APP/Contents/Frameworks/Sparkle.framework"
for item in "$FW"/Versions/B/XPCServices/*.xpc(N) "$FW/Versions/B/Autoupdate" "$FW/Versions/B/Updater.app"; do
  [[ -e "$item" ]] && sign "$item"
done
sign "$FW"
sign --entitlements "$REPO/Resources/CommandSpace.entitlements" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (signed with ${IDENTITY})"

if [[ " $* " == *" --install "* ]]; then
  pkill -x "Command Space" 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/Command Space.app"
  ditto "$APP" "/Applications/Command Space.app"
  open "/Applications/Command Space.app"
  echo "Installed to /Applications and launched"
fi

if [[ " $* " == *" --dmg "* ]]; then
  STAGE="$TMP/dmg" && mkdir -p "$STAGE"
  ditto "$APP" "$STAGE/Command Space.app"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Command Space" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Command-Space.dmg" >/dev/null
  shasum -a 256 "$OUT/Command-Space.dmg"
  # Sparkle: EdDSA key in the login keychain (account "notch-agent", shared with Notch Agent).
  SIGN_UPDATE=$(find "$DERIVED/SourcePackages/artifacts" -path '*Sparkle/bin/sign_update' -not -path '*old_dsa*' | head -1)
  VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
  BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
  SIGNATURE=$("$SIGN_UPDATE" --account notch-agent "$OUT/Command-Space.dmg")
  python3 - "$REPO/appcast.xml" "$VERSION" "$BUILD" "$SIGNATURE" <<'PY'
import sys, re, email.utils
path, version, build, signature = sys.argv[1:5]
url = f"https://github.com/otron-io/command-space/releases/download/v{version}/Command-Space.dmg"
item = f"""    <item>
      <title>Command Space {version}</title>
      <pubDate>{email.utils.formatdate(localtime=True)}</pubDate>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="{url}" {signature} type="application/octet-stream"/>
    </item>
"""
xml = open(path).read()
xml = re.sub(r"    <item>\s*<title>Command Space " + re.escape(version) + r"</title>.*?</item>\n", "", xml, flags=re.S)
xml = xml.replace("    <title>Command Space</title>\n", "    <title>Command Space</title>\n" + item, 1)
open(path, "w").write(xml)
PY
  echo "Built $OUT/Command-Space.dmg (v$VERSION build $BUILD); appcast.xml updated"
fi
