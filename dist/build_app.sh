#!/bin/zsh
# SwiftPM 릴리스 빌드 + .app 번들 조립 + ad-hoc 서명 (src/ 옆에서 실행)
set -e
# $0 may be relative: resolve the two directories once, before any cd.
DIST="${0:A:h}"
SRC="$DIST/../src"
cd "$SRC"
swift build -c release
APP="$DIST/ClaudeAPISwitch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/claude-switch "$APP/Contents/MacOS/claude-switch"
xattr -cs "$APP" 2>/dev/null || true   # codesign refuses bundles with Finder detritus
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>claude-switch</string>
  <key>CFBundleIdentifier</key><string>com.uhd.claudeapiswitch</string>
  <key>CFBundleName</key><string>ClaudeAPISwitch</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>local utility</string>
</dict>
</plist>
PLIST
# com.apple.provenance cannot be stripped, so --force signing warns; the bundle is
# still ad-hoc signed (linker does it), which is what install.sh relies on.
codesign --force -s - "$APP" || echo "note: codesign warned (provenance xattr); bundle is linker ad-hoc signed"
cd "$DIST"
rm -f ClaudeAPISwitch.app.zip
zip -qry ClaudeAPISwitch.app.zip ClaudeAPISwitch.app
echo "built: $APP (+ zip)"
