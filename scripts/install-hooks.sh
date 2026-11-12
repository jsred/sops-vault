#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
existing=$(git config --get core.hooksPath || true)
if [[ -n "$existing" && "$existing" != .githooks ]]; then
    echo "Refusing to replace existing core.hooksPath: $existing" >&2
    exit 1
fi
if [[ -z "$existing" ]]; then
    legacy_dir=$(git rev-parse --git-path hooks)
    for legacy in "$legacy_dir"/*; do
        [[ -f "$legacy" && -x "$legacy" && "$legacy" != *.sample ]] || continue
        echo "Existing active hook at $legacy; integrate it before installing." >&2
        exit 1
    done
fi
git config --local core.hooksPath .githooks
echo 'Installed pre-push hook: origin requires >=100% VaultCore line coverage.'
