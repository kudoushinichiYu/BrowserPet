#!/usr/bin/env python3
"""Audit a release app without launching it or changing browser configuration."""
import json
import plistlib
import subprocess
import sys
from pathlib import Path

app = Path(sys.argv[1]).resolve()
root = Path(__file__).resolve().parent.parent
resources = app / 'Contents/Resources'
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
expected = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
assert info['CFBundleShortVersionString'] == expected['CFBundleShortVersionString']
assert info['LSMinimumSystemVersion'] == '13.0'
assert info['CFBundleIconFile'] == 'AppIcon.icns'
icon = resources / info['CFBundleIconFile']
assert icon.read_bytes()[:4] == b'icns', 'Invalid application icon'
assert subprocess.check_output(['lipo', '-archs', str(app / 'Contents/MacOS/BrowserPet')], text=True).strip() == 'arm64'
subprocess.run(['codesign', '--verify', '--strict', str(app)], check=True)
assert not (resources / 'safari-bridge-config.json').exists(), 'Bundled pairing secret'
assert not (resources / 'safari-tabs/config.js').exists(), 'Bundled paired helper'
assert set(p.name for p in (resources / 'safari-tabs').iterdir()) == {'background.js', 'protocol.js', 'manifest.json'}
for folder, names in [('safari-tabs', ['background.js', 'protocol.js', 'manifest.json']),
                      ('chrome-groups', ['background.js', 'snapshot.mjs', 'manifest.json'])]:
    for name in names:
        assert (resources / folder / name).read_bytes() == (root / 'extensions' / folder / name).read_bytes(), name
assert (resources / 'group-native-host').stat().st_mode & 0o111
for name in ['pet-atlas.png', 'pet-atlas-frames.json', 'chrome-scan.js', 'chrome-activate.js']:
    assert (resources / name).read_bytes() == (root / 'Resources' / name).read_bytes(), name
# Test secret bytes internally; never print them or place them in audit output.
forbidden = [str(root).encode(), str(Path.home()).encode()]
for config in [root / '.build/safari-pairing.json',
               Path.home() / 'Library/Application Support/BrowserPet/safari-pairing.json']:
    if config.exists():
        forbidden.append(json.loads(config.read_text())['token'].encode())
files = [p for p in app.rglob('*') if p.is_file()]
for file in files:
    data = file.read_bytes()
    assert all(value not in data for value in forbidden), f'Local path or secret in {file.relative_to(app)}'
print(f'PASS release {info["CFBundleShortVersionString"]}: arm64/macOS 13+, strict signature, exact assets, no bundled pairing or local paths ({len(files)} files).')
