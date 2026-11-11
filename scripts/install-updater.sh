#!/bin/zsh
# Sets up automatic updates on this Mac.
# usage: scripts/install-updater.sh <trusted-signing-key.pub>...
#
# Each argument is an SSH public key whose signatures on release tags this Mac will trust. They are
# written to ~/.config/sops-vault/allowed_signers (kept outside the repository on purpose). A LaunchAgent
# then runs the updater at login and every hour. Run again to change the trusted keys.
set -euo pipefail
cd "${0:A:h}/.."
(( $# > 0 )) || { print -u2 "usage: scripts/install-updater.sh <trusted-signing-key.pub>..."; exit 2 }

CONFIG="$HOME/.config/sops-vault"
LABEL="io.github.jsred.sops-vault.updater"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/sops-vault-updater.log"
mkdir -p "$CONFIG" "${PLIST:h}" "${LOG:h}"
chmod 700 "$CONFIG"

signers="$CONFIG/allowed_signers.new"
: >"$signers"
for key in "$@"; do
  read -r type blob _ <"$key"
  [[ $type == ssh-* || $type == ecdsa-* ]] || { print -u2 "$key is not an SSH public key"; exit 2 }
  print -r -- "sops-vault-release namespaces=\"git\" $type $blob" >>"$signers"
  print "Trusting $(ssh-keygen -lf "$key")"
done
chmod 600 "$signers" && mv "$signers" "$CONFIG/allowed_signers"

cp scripts/update.sh "$CONFIG/updater.sh.new" && chmod 755 "$CONFIG/updater.sh.new" && mv "$CONFIG/updater.sh.new" "$CONFIG/updater.sh"

cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$CONFIG/updater.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>3600</integer>
  <key>ProcessType</key><string>Background</string>
  <key>LowPriorityIO</key><true/>
  <key>Nice</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
print "Updater installed. It runs now, at login and every hour. Log: $LOG"
