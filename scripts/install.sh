#!/bin/sh
# Builds meepo and puts it in ~/Applications — the copy the Dock opens. Xcode's DerivedData is a cache that gets
# wiped (Xcode, cleaners), and the meepo running from it went with it. Release: a Debug build (-Onone) is several
# times slower in SwiftTerm's parsing and drawing, and typing in claude's prompt lagged with it.
# MEEPO_INSTALL_NOW=1: quit meepo and swap right away, as before (from a terminal outside meepo).
set -e
cd "$(dirname "$0")/.."
xcodegen generate --quiet
xcodebuild -project Meepo.xcodeproj -scheme Meepo -configuration Release -skipPackagePluginValidation -derivedDataPath .build/install -quiet build
BUILT=.build/install/Build/Products/Release/Meepo.app
APP="$HOME/Applications/Meepo.app"
# Asked through AppleScript: pgrep can't see meepo from a sandboxed shell (Claude Code's `!`), and the files were
# replaced under the running app.
running() { [ "$(osascript -e 'application id "com.azamatfg.meepo" is running')" = true ]; }
# macOS knows every Meepo.app ever built (DerivedData, .build/*, worktrees, temp folders) under the same bundle id, and `meepo`, meepo://
# links and notifications could open one of those — gone with the next cleanup. Only the installed copy stays registered.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
only_installed_registered() {
  "$LSREGISTER" -dump | sed -n 's/^path: *\(.*\/Meepo\.app\) (0x[0-9a-f]*)$/\1/p' | sort -u | while read -r app; do
    [ "$app" = "$APP" ] || "$LSREGISTER" -u "$app" 2>/dev/null || true
  done
  "$LSREGISTER" -f "$APP"
}
# Meepo running: it swaps the build in itself at its RESTART. This script usually runs in a meepo terminal — quitting
# meepo from here ended the script halfway (2026-11-28: meepo closed, the new build not installed, nothing reopened).
if running && [ -z "$MEEPO_INSTALL_NOW" ]; then
  STAGED="$HOME/.meepo/updates/local/Meepo.app"
  rm -rf "$STAGED" && mkdir -p "$(dirname "$STAGED")"
  ditto "$BUILT" "$STAGED"
  only_installed_registered # the link below must reach the running copy, not the build or the staged one
  NOTES=$(git log -1 --format=%s | cut -c1-200)
  ENCODE='import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))'
  open "meepo://update?build=$(python3 -c "$ENCODE" "$STAGED")&notes=$(python3 -c "$ENCODE" "$NOTES")"
  echo "meepo has the new build: RESTART in its status bar — it waits for working agents, then sessions come back"
  exit 0
fi
if running; then
  osascript -e 'tell application id "com.azamatfg.meepo" to quit' >/dev/null || { echo "meepo didn't quit — nothing replaced"; exit 1; }
  while running; do sleep 1; done
fi
mkdir -p "$HOME/Applications"
# Copied next to the old one, then swapped by mv: a sandboxed shell once stopped `rm -rf` halfway (2026-11-26) and left
# a Meepo.app without its binary. Now a failed step leaves the old copy whole.
rm -rf "$APP.new" "$APP.old"
ditto "$BUILT" "$APP.new"
if [ -e "$APP" ]; then mv "$APP" "$APP.old"; fi
mv "$APP.new" "$APP"
rm -rf "$APP.old" || echo "couldn't remove $APP.old — delete it by hand"
only_installed_registered
# Without it: `open` hands meepo this shell's environment, and every session inside would install the old way.
env -u MEEPO_INSTALL_NOW open "$APP"
