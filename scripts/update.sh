#!/bin/zsh
# SOPS Vault updater. Installs the newest release tag (vX.Y.Z) that is signed by a key listed in
# ~/.config/sops-vault/allowed_signers on this Mac. Run hourly by a LaunchAgent (see install-updater.sh).
#
# - The trusted keys live only on this Mac, never in the repository, so a pushed commit or tag cannot
#   add itself as trusted. Unsigned or wrongly signed tags are skipped.
# - Builds from source in a private clone, runs the test suite and installs only if it passes.
# - If SOPS Vault is open, the new version waits until it quits.
# - This script replaces itself only with the copy inside a verified tag.
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export GIT_TERMINAL_PROMPT=0

CONFIG="$HOME/.config/sops-vault"
SIGNERS="$CONFIG/allowed_signers"
CACHE="$HOME/Library/Caches/io.github.jsred.sops-vault"
SRC="$CACHE/source"
PENDING="$CACHE/pending/SOPS Vault.app"
BUILD_LOG="$HOME/Library/Logs/sops-vault-build.log"
REPO="${SOPS_VAULT_REPO:-https://github.com/jsred/sops-vault.git}"
APP="/Applications/SOPS Vault.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
TEST_PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" }
running() { pgrep -f "$APP/Contents/MacOS/SOPSVault" >/dev/null }
installed_version() { plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist" 2>/dev/null || print 0 }
# True when version $1 is strictly newer than $2.
newer() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]] }

install_pending() {
  [[ -d "$PENDING" ]] || return 0
  if running; then log "Update ready; it installs after SOPS Vault quits."; return 0; fi
  rm -rf "$APP.new"
  ditto "$PENDING" "$APP.new"
  rm -rf "$APP"
  mv "$APP.new" "$APP"
  rm -rf "$PENDING"
  "$LSREGISTER" -f "$APP" || true
  log "Installed SOPS Vault $(installed_version)."
}

mkdir -p "$CACHE" "${BUILD_LOG:h}"
if ! mkdir "$CACHE/lock" 2>/dev/null; then
  # A crashed run can leave the lock behind; ignore it after two hours.
  if [[ -n $(find "$CACHE/lock" -maxdepth 0 -mmin +120 2>/dev/null) ]]; then rmdir "$CACHE/lock"; mkdir "$CACHE/lock"
  else exit 0; fi
fi
trap 'rmdir "$CACHE/lock" 2>/dev/null || true' EXIT

[[ -s "$SIGNERS" ]] || { log "Missing $SIGNERS; refusing to update."; exit 1 }

install_pending
[[ -d "$PENDING" ]] && exit 0

if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "${SRC:h}"
  git clone --quiet --no-checkout "$REPO" "$SRC"
fi
cd "$SRC"
if ! git fetch --quiet --force --prune --prune-tags --tags origin; then
  log "Could not reach $REPO; will retry later."
  exit 0
fi

tag=""
for candidate in $(git tag -l 'v[0-9]*' --sort=-v:refname); do
  if git -c gpg.ssh.allowedSignersFile="$SIGNERS" verify-tag "$candidate" >/dev/null 2>&1; then
    tag=$candidate; break
  fi
  log "Skipping $candidate: not signed by a trusted key."
done
[[ -n "$tag" ]] || { log "No signed release found."; exit 0 }

version=${tag#v}
current=$(installed_version)
newer "$version" "$current" || exit 0

log "Building $tag (installed: $current). Details in $BUILD_LOG."
print -r -- "===== $(date '+%Y-%m-%d %H:%M:%S') $tag" >>"$BUILD_LOG"
git -c advice.detachedHead=false checkout --quiet --force --detach "$tag^{commit}"
git clean -fdxq -e .build

test_flags=()
if [[ -d "$TEST_PLUGINS" && "$(xcode-select -p 2>/dev/null)" != *.app/* ]]; then
  test_flags=(--disable-xctest -Xswiftc -plugin-path -Xswiftc "$TEST_PLUGINS")
fi
if ! swift test "${test_flags[@]}" >>"$BUILD_LOG" 2>&1; then
  log "Tests failed for $tag; nothing was installed."
  exit 1
fi
if ! VERSION="$version" ./scripts/package.sh >>"$BUILD_LOG" 2>&1; then
  log "Packaging failed for $tag; nothing was installed."
  exit 1
fi

# Take the updater from the verified tag. rename keeps this running copy intact.
cp scripts/update.sh "$CONFIG/updater.sh.new" && chmod 755 "$CONFIG/updater.sh.new" && mv "$CONFIG/updater.sh.new" "$CONFIG/updater.sh"

mkdir -p "${PENDING:h}"
rm -rf "$PENDING"
ditto "dist/SOPS Vault.app" "$PENDING"
install_pending
