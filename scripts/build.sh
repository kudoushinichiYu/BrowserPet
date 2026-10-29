#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_bundle="${BROWSERPET_APP_PATH:-$PWD/build/BrowserPet.app}"
mkdir -p .build/module-cache "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
if [[ "${BROWSERPET_RELEASE:-0}" != "1" ]]; then python3 scripts/prepare-safari-helper.py; fi
diagnostic_flags=()
if [[ "${BROWSERPET_DIAGNOSTICS:-0}" == "1" ]]; then diagnostic_flags=(-D BP_DIAGNOSTICS); fi
xcrun swiftc "${diagnostic_flags[@]}" -swift-version 5 -O -target arm64-apple-macosx13.0 \
  -file-prefix-map "$PWD"=. \
  -module-cache-path "$PWD/.build/module-cache" Sources/BrowserPet/*.swift \
  -o "$app_bundle/Contents/MacOS/BrowserPet"
cp Resources/Info.plist "$app_bundle/Contents/Info.plist"
./scripts/build-icon.sh "$app_bundle/Contents/Resources/AppIcon.icns"
cp Resources/*.js Resources/pet-atlas.png "$app_bundle/Contents/Resources/"
cp Resources/group-bridge-config.json Resources/pet-atlas-frames.json "$app_bundle/Contents/Resources/"
mkdir -p "$app_bundle/Contents/Resources/safari-tabs"
if [[ "${BROWSERPET_RELEASE:-0}" == "1" ]]; then
  rm -f "$app_bundle/Contents/Resources/safari-bridge-config.json" "$app_bundle/Contents/Resources/safari-tabs/config.js"
  cp extensions/safari-tabs/* "$app_bundle/Contents/Resources/safari-tabs/"
else
  cp .build/safari-pairing.json "$app_bundle/Contents/Resources/safari-bridge-config.json"
  cp build/safari-extension/* "$app_bundle/Contents/Resources/safari-tabs/"
fi
cp Resources/group-native-host "$app_bundle/Contents/Resources/"
chmod +x "$app_bundle/Contents/Resources/group-native-host"
mkdir -p "$app_bundle/Contents/Resources/chrome-groups"
cp extensions/chrome-groups/* "$app_bundle/Contents/Resources/chrome-groups/"
codesign --force --sign - --options runtime --entitlements Resources/Entitlements.plist "$app_bundle"
codesign --verify --strict "$app_bundle"
echo "Built: $app_bundle"
