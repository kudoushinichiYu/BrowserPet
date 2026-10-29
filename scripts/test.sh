#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/module-cache output/validation
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
  Sources/BrowserPet/Core.swift Sources/BrowserPet/GroupModel.swift Tests/CoreChecks.swift -o .build/core-checks
.build/core-checks | tee output/validation/core-checks.txt
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
  Sources/BrowserPet/Core.swift Sources/BrowserPet/GroupModel.swift Tests/FuzzySearchChecks.swift -o .build/fuzzy-search-checks
.build/fuzzy-search-checks | tee output/validation/fuzzy-search-checks.txt
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
  Sources/BrowserPet/Core.swift Sources/BrowserPet/HoverTitleView.swift Sources/BrowserPet/SearchPanel.swift \
  Tests/SearchRefreshChecks.swift -o .build/search-refresh-checks
.build/search-refresh-checks | tee output/validation/search-refresh-checks.txt
node Tests/chrome-scripts.test.js | tee output/validation/chrome-script-checks.txt
node Tests/group-extension.test.mjs | tee output/validation/group-extension-checks.txt
node Tests/safari-extension.test.js | tee output/validation/safari-extension-checks.txt
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
  Sources/BrowserPet/Core.swift Sources/BrowserPet/GroupModel.swift Sources/BrowserPet/WorkspaceStore.swift Sources/BrowserPet/ChromeAdapter.swift \
  Sources/BrowserPet/GroupBridge.swift Sources/BrowserPet/SafariAdapter.swift Sources/BrowserPet/SafariLoopback.swift Sources/BrowserPet/LocalSetup.swift \
  Sources/BrowserPet/MultiBrowserAdapter.swift Tests/MultiBrowserChecks.swift -o .build/multi-browser-checks
.build/multi-browser-checks | tee output/validation/multi-browser-checks.txt
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
  Sources/BrowserPet/PetAtlas.swift Tests/PetAtlasChecks.swift -o .build/pet-atlas-checks
.build/pet-atlas-checks | tee output/validation/pet-atlas-checks.txt
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
  Sources/BrowserPet/Core.swift Sources/BrowserPet/GroupModel.swift Sources/BrowserPet/WorkspaceStore.swift Sources/BrowserPet/ChromeAdapter.swift Sources/BrowserPet/GroupBridge.swift Tests/BridgeChecks.swift -o .build/bridge-checks
.build/bridge-checks | tee output/validation/group-bridge-checks.txt

node Tests/workspace-scripts.test.js | tee output/validation/workspace-script-checks.txt
xcrun swiftc -swift-version 5 -O -parse-as-library -module-cache-path "$PWD/.build/module-cache" \
  Sources/BrowserPet/Core.swift Sources/BrowserPet/GroupModel.swift Sources/BrowserPet/WorkspaceStore.swift \
  Sources/BrowserPet/ChromeAdapter.swift Sources/BrowserPet/GroupBridge.swift Sources/BrowserPet/SafariAdapter.swift \
  Sources/BrowserPet/WorkspaceCoordinator.swift Sources/BrowserPet/WorkspaceController.swift Tests/WorkspaceChecks.swift -o .build/workspace-checks
.build/workspace-checks | tee output/validation/workspace-checks.txt
