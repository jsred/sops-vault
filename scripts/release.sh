#!/bin/zsh
# Publishes a release that the updaters will install.
# usage: scripts/release.sh <version>      e.g. scripts/release.sh 1.2.0
#
# Requires a clean checkout equal to origin/main. Runs the tests, creates an annotated tag vX.Y.Z signed
# with your SSH key (git config user.signingkey, gpg.format=ssh), verifies it against this Mac's trusted
# keys and pushes it.
set -euo pipefail
cd "${0:A:h}/.."
die() { print -u2 -- "$*"; exit 1 }
version=${1:-}
[[ $version =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || die "usage: scripts/release.sh <major.minor.patch>"
tag="v$version"
[[ "$(git config gpg.format)" == ssh && -n "$(git config user.signingkey)" ]] ||
  die "Configure signing first: git config gpg.format ssh && git config user.signingkey ~/.ssh/<key>.pub"
signers="$HOME/.config/sops-vault/allowed_signers"
[[ -s $signers ]] || die "Missing $signers. Run scripts/install-updater.sh <key.pub> first."
[[ -z "$(git status --porcelain)" ]] || die "Commit or stash your changes first."
git fetch --quiet --tags origin
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "HEAD must match origin/main. Push or pull first."
git rev-parse -q --verify "refs/tags/$tag" >/dev/null && die "$tag already exists."
latest=$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)
if [[ -n $latest && "$(printf '%s\n%s\n' "${latest#v}" "$version" | sort -V | tail -1)" != "$version" ]]; then
  die "$tag must be newer than $latest."
fi

plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
flags=()
[[ -d $plugins && "$(xcode-select -p)" != *.app/* ]] && flags=(--disable-xctest -Xswiftc -plugin-path -Xswiftc $plugins)
print "Running tests…"
swift test "${flags[@]}" >/tmp/sops-vault-release-tests.log 2>&1 || die "Tests failed; see /tmp/sops-vault-release-tests.log"

git tag -s "$tag" -m "SOPS Vault $version"
git -c gpg.ssh.allowedSignersFile="$signers" verify-tag "$tag" || { git tag -d "$tag"; die "The new tag does not verify against $signers."; }
git push --quiet origin "$tag"
print "Released $tag. Updaters install it within the hour."
