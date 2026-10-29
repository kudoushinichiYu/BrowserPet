#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
[[ "$#" == "1" ]] || { echo 'Usage: build-icon.sh /path/to/AppIcon.icns' >&2; exit 1; }
destination="$1"
mkdir -p .build "${destination:h}"
stage=$(mktemp -d "$PWD/.build/icon.XXXXXX")
trap 'rm -rf "$stage"' EXIT
iconset="$stage/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  retina=$((size*2))
  sips -z "$retina" "$retina" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns --output "$destination" "$iconset"
