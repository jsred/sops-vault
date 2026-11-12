#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
set --
plugins=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
if [[ -d "$plugins" && "$(xcode-select -p)" != *.app/* ]]; then
    set -- --disable-xctest -Xswiftc -plugin-path -Xswiftc "$plugins"
fi
# Rebuild and execute tests on every invocation; never accept a cached report alone.
swift test --no-parallel --enable-code-coverage "$@"
report=$(swift test --show-codecov-path)
python3 scripts/check-coverage.py "$report" "$PWD"
