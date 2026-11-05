#!/bin/sh
# Builds meepo and puts it in ~/Applications — the copy the Dock opens. Xcode's DerivedData is a cache that gets
# wiped (Xcode, cleaners), and the meepo running from it went with it.
set -e
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Meepo.xcodeproj -scheme Meepo -skipPackagePluginValidation -derivedDataPath .build/install -quiet build
if pgrep -qf "$HOME/Applications/Meepo.app/"; then
  osascript -e 'tell application id "com.azamatfg.meepo" to quit' >/dev/null || { echo "meepo didn't quit — nothing replaced"; exit 1; }
  while pgrep -qf "$HOME/Applications/Meepo.app/"; do sleep 1; done
fi
mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/Meepo.app"
ditto .build/install/Build/Products/Debug/Meepo.app "$HOME/Applications/Meepo.app"
open "$HOME/Applications/Meepo.app"
