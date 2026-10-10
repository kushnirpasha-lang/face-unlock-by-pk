#!/bin/bash
# Face ID for Mac (by PK) — full removal. Run as the owner (no sudo needed):
#   bash uninstall.sh
# Removes: the running app, its LaunchAgent, the app, its data (encrypted password, face data, vault key handle),
# its log, its settings, and resets the macOS permissions it was given. Touch ID and the password were never touched.
set -u
LABEL=com.pavel.faceidformac
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -f "Face ID for Mac.app/Contents/MacOS/" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "/Applications/Face ID for Mac.app"
rm -rf "$HOME/Library/Application Support/FaceIDforMac"
rm -rf "$HOME/Library/Logs/FaceIDforMac"
defaults delete "$LABEL" 2>/dev/null
security delete-generic-password -s "$LABEL" -a session-key >/dev/null 2>&1
for s in Camera Accessibility ListenEvent; do tccutil reset "$s" "$LABEL" >/dev/null 2>&1; done
echo "Проверка (всё должно быть пусто):"
launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && echo "  ! агент ещё загружен" || echo "  агент: нет"
ls "$HOME/Library/LaunchAgents/$LABEL.plist" 2>/dev/null || echo "  plist: нет"
ls -d "/Applications/Face ID for Mac.app" 2>/dev/null || echo "  программа: нет"
ls -d "$HOME/Library/Application Support/FaceIDforMac" 2>/dev/null || echo "  данные: нет"
pgrep -f "Face ID for Mac.app/Contents/MacOS/" >/dev/null && echo "  ! процесс ещё жив" || echo "  процесс: нет"
