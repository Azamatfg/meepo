#!/bin/sh
# Builds meepo and puts it in ~/Applications — the copy the Dock opens. Xcode's DerivedData is a cache that gets
# wiped (Xcode, cleaners), and the meepo running from it went with it. Release: a Debug build (-Onone) is several
# times slower in SwiftTerm's parsing and drawing, and typing in claude's prompt lagged with it.
set -e
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Meepo.xcodeproj -scheme Meepo -configuration Release -skipPackagePluginValidation -derivedDataPath .build/install -quiet build
# Asked through AppleScript: pgrep can't see meepo from a sandboxed shell (Claude Code's `!`), and the files were
# replaced under the running app.
running() { [ "$(osascript -e 'application id "com.azamatfg.meepo" is running')" = true ]; }
if running; then
  osascript -e 'tell application id "com.azamatfg.meepo" to quit' >/dev/null || { echo "meepo didn't quit — nothing replaced"; exit 1; }
  while running; do sleep 1; done
fi
mkdir -p "$HOME/Applications"
# Copied next to the old one, then swapped by mv: a sandboxed shell once stopped `rm -rf` halfway (2026-11-26) and left
# a Meepo.app without its binary. Now a failed step leaves the old copy whole.
APP="$HOME/Applications/Meepo.app"
rm -rf "$APP.new" "$APP.old"
ditto .build/install/Build/Products/Release/Meepo.app "$APP.new"
if [ -e "$APP" ]; then mv "$APP" "$APP.old"; fi
mv "$APP.new" "$APP"
rm -rf "$APP.old" || echo "couldn't remove $APP.old — delete it by hand"
# macOS knows every Meepo.app ever built (DerivedData, .build/*, worktrees, temp folders) under the same bundle id, and `meepo`, meepo://
# links and notifications could open one of those — gone with the next cleanup. Only this copy stays registered.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -dump | sed -n 's/^path: *\(.*\/Meepo\.app\) (0x[0-9a-f]*)$/\1/p' | sort -u | while read -r app; do
  [ "$app" = "$HOME/Applications/Meepo.app" ] || "$LSREGISTER" -u "$app" 2>/dev/null || true
done
"$LSREGISTER" -f "$HOME/Applications/Meepo.app"
open "$HOME/Applications/Meepo.app"
