#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
mkdir -p .build dist
stage=$(mktemp -d "$PWD/.build/release.XXXXXX")
mounted=0
cleanup() {
  if [[ "$mounted" == "1" ]]; then hdiutil detach "$stage/mounted" >/dev/null || return; fi
  rm -rf "$stage"
}
trap cleanup EXIT
mkdir -p "$stage/payload"
app="$stage/payload/BrowserPet.app"
BROWSERPET_RELEASE=1 BROWSERPET_APP_PATH="$app" ./scripts/build.sh
python3 scripts/verify-release.py "$app"
ln -s /Applications "$stage/payload/Applications"
cp docs/INSTALL.zh-CN.txt "$stage/payload/安装说明.txt"
cp "$app/Contents/Resources/AppIcon.icns" "$stage/payload/.VolumeIcon.icns"
dmg="$PWD/dist/BrowserPet-${version}-macOS-arm64.dmg"
hdiutil create -volname "BrowserPet $version" -srcfolder "$stage/payload" -fs HFS+ -format UDRW "$stage/writable.dmg"
mkdir "$stage/mounted"
hdiutil attach -nobrowse -mountpoint "$stage/mounted" "$stage/writable.dmg" >/dev/null
mounted=1
xcrun SetFile -a C "$stage/mounted"
hdiutil detach "$stage/mounted" >/dev/null
mounted=0
hdiutil convert "$stage/writable.dmg" -format UDZO -ov -o "$dmg" >/dev/null
hdiutil verify "$dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$stage/mounted" "$dmg" >/dev/null
mounted=1
python3 scripts/verify-release.py "$stage/mounted/BrowserPet.app"
[[ "$(readlink "$stage/mounted/Applications")" == "/Applications" ]]
cmp docs/INSTALL.zh-CN.txt "$stage/mounted/安装说明.txt"
cmp "$stage/mounted/.VolumeIcon.icns" "$stage/mounted/BrowserPet.app/Contents/Resources/AppIcon.icns"
[[ "$(xcrun GetFileInfo -a "$stage/mounted")" == *C* ]]
hdiutil detach "$stage/mounted" >/dev/null
mounted=0
(cd dist && shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")
echo "Packaged: $dmg"
