#!/bin/zsh
# ClaudeAPISwitch.app 설치: zip 풀어 /Applications에 배치하고 ad-hoc 재서명 후 실행
set -e
D="${0:A:h}"
[ -d "$D/dist/ClaudeAPISwitch.app" ] || (cd "$D/dist" && unzip -q ClaudeAPISwitch.app.zip)
ditto "$D/dist/ClaudeAPISwitch.app" /Applications/ClaudeAPISwitch.app
# A Release download carries com.apple.quarantine, and an ad-hoc signature is not
# notarized, so Gatekeeper would refuse to open the bundle. A binary you built
# yourself never has that flag; you chose to run this script, so it is dropped here.
xattr -dr com.apple.quarantine /Applications/ClaudeAPISwitch.app 2>/dev/null || true
# com.apple.provenance cannot be stripped, so re-signing warns; the bundle is already
# ad-hoc signed by the linker, which is all a local LSUIElement app needs.
codesign --force -s - /Applications/ClaudeAPISwitch.app || echo "note: codesign warned (provenance xattr); ad-hoc signature from the build is kept"
open /Applications/ClaudeAPISwitch.app
echo "installed. Look for the ⇄ icon in the menu bar."
