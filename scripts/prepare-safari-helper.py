#!/usr/bin/env python3
"""Create a local, paired temporary Safari helper. Pairing secrets stay in ignored build folders."""
import json
import os
import secrets
import shutil
from pathlib import Path

root = Path(__file__).resolve().parent.parent
cache = root / '.build/safari-pairing.json'
cache.parent.mkdir(parents=True, exist_ok=True)
if cache.exists():
    config = json.loads(cache.read_text())
else:
    config = {'port':49731, 'token':secrets.token_hex(32)}
assert config['port'] == 49731 and len(config['token']) == 64
cache.write_text(json.dumps(config)+'\n')
cache.chmod(0o600)
folder = root / 'build/safari-extension'
folder.mkdir(parents=True, exist_ok=True)
folder.chmod(0o700)
for source in (root / 'extensions/safari-tabs').iterdir():
    if source.is_file(): shutil.copy2(source, folder / source.name)
pairing = {'endpoint':f"http://127.0.0.1:{config['port']}/v1/safari/sync", 'token':config['token']}
script = folder / 'config.js'
script.write_text('const BROWSERPET_PAIRING = Object.freeze('+json.dumps(pairing)+');\n')
script.chmod(0o600)
print('Prepared build/safari-extension with an owner-only local pairing; no extension installed.')
