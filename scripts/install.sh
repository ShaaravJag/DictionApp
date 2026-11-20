#!/bin/bash
# Build DictionApp (Release) and install it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null && xcodegen generate --quiet

xcodebuild -project DictionApp.xcodeproj -scheme DictionMac -configuration Release \
  -derivedDataPath build/DerivedData -destination 'platform=macOS' -allowProvisioningUpdates build -quiet

APP=build/DerivedData/Build/Products/Release/DictionApp.app
pkill -x DictionApp 2>/dev/null || true
rm -rf /Applications/DictionApp.app
cp -R "$APP" /Applications/
echo "Installed /Applications/DictionApp.app"
open /Applications/DictionApp.app
