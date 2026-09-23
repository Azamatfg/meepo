#!/bin/bash
# Notification hook: macOS notification when Claude needs attention

osascript -e 'display notification "Claude ждёт твоего ввода" with title "Claude Code" sound name "Ping"'
exit 0
