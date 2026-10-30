#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: This suite requires macOS because it verifies native BSD file flags." >&2
    exit 1
fi
command -v xcrun >/dev/null || {
    echo "ERROR: Install Apple's Command Line Tools before running the tests." >&2
    exit 1
}

test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/desktop-privacy-test-build.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT
cd "$project_root"

echo "Building isolated core/configuration tests for the current host architecture: $(uname -m)"
xcrun swiftc -O \
    Sources/Core.swift \
    Sources/AppConfiguration.swift \
    Tests/main.swift \
    -o "$test_build_dir/core-tests"
echo "Running synthetic fixtures in a unique temporary directory. No real Desktop or Finder is used."
"$test_build_dir/core-tests"
echo "PASS: Native architecture isolated test suite completed."
