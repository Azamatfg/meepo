#!/bin/sh
# Meepo's check before done and before push: the mod's tests and the tests on the paths that hurt most when they
# break — sessions starting, hook events and statuses, the bridge, quitting, updates, git push/pull, setup fixes.
# The whole suite (CLAUDE.md, Тесты) is for releases.
set -e
cd "$(dirname "$0")/.."
claude plugin test Meepo/Resources/MeepoMod
# Every time: a project generated before a test file existed would skip its class and still pass.
xcodegen generate --quiet
only=""
for class in HookPayloadTests HookHandlingTests BackgroundStopTests BridgeInstallerTests BridgeEndToEndTests BridgeReplyTests \
  BridgeCommandTests AttachedBridgeTests ClaudeLauncherTests LoginTimeoutTests QuitTests UpdaterSafetyTests \
  PullRebaseTests GitServiceTests GitPanelDiscardTests NonASCIIPathTests ImportantProjectTests SetupCheckTests \
  ReleaseNotesTests ProcessWaitTests ChangeLogTests ReplayTests; do
  only="$only -only-testing:MeepoTests/$class"
done
# Its own build folder: building into Xcode's would replace the Debug meepo that's running.
xcodebuild -project Meepo.xcodeproj -scheme Meepo -destination 'platform=macOS,arch=arm64' -skipPackagePluginValidation \
  -derivedDataPath .build/check -quiet test $only
