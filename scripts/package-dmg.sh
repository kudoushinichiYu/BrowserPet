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
dmg="$PWD/dist/BrowserPet-${version}-macOS-arm64.dmg"
hdiutil create -volname "BrowserPet $version" -srcfolder "$stage/payload" -fs HFS+ -format UDZO -ov "$dmg"
hdiutil verify "$dmg"
mkdir "$stage/mounted"
hdiutil attach -readonly -nobrowse -mountpoint "$stage/mounted" "$dmg" >/dev/null
mounted=1
python3 scripts/verify-release.py "$stage/mounted/BrowserPet.app"
[[ "$(readlink "$stage/mounted/Applications")" == "/Applications" ]]
cmp docs/INSTALL.zh-CN.txt "$stage/mounted/安装说明.txt"
hdiutil detach "$stage/mounted" >/dev/null
mounted=0
(cd dist && shasum -a 256 "${dmg:t}" > "${dmg:t}.sha256")
echo "Packaged: $dmg"
