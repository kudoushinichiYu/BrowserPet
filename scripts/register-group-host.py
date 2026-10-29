#!/usr/bin/env python3
"""Prepare a reviewable registration; write the user-level host only with --install."""
import argparse
import json
from pathlib import Path

root = Path(__file__).resolve().parent.parent
config = json.loads((root/'Resources/group-bridge-config.json').read_text())
host_path = root/'build/BrowserPet.app/Contents/Resources/group-native-host'
manifest = {'name':config['hostName'],'description':'BrowserPet local read-only tab-group bridge',
            'path':str(host_path),'type':'stdio','allowed_origins':[config['extensionOrigin']]}
destination = Path.home()/'Library/Application Support/Google/Chrome/NativeMessagingHosts'/f"{config['hostName']}.json"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--install',action='store_true',help='Register the helper after approving the extension and permissions.')
args = parser.parse_args()
review = root/'output/extension-install-review'
review.mkdir(parents=True,exist_ok=True)
(review/'native-host-manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
if args.install:
    if not host_path.is_file(): parser.error('Build BrowserPet.app before registration.')
    destination.parent.mkdir(parents=True,exist_ok=True)
    if destination.exists():
        current=json.loads(destination.read_text())
        if current.get('name') != config['hostName'] or current.get('allowed_origins') != manifest['allowed_origins']:
            parser.error('An unrelated registration exists; refusing to replace it.')
    destination.write_text(json.dumps(manifest,ensure_ascii=False,indent=2)+'\n')
    destination.chmod(0o600)
    print('Registered:',destination)
else:
    print('Review only; no Chrome settings or registrations were changed.')
print('Extension folder:',root/'extensions/chrome-groups')
print('Extension ID:',config['extensionID'])
print('Host destination:',destination)
