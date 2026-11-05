#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build_dir="$(mktemp -d /tmp/stayput-controller-tests.XXXXXX)"
trap 'rm -rf "$task_build_dir"' EXIT

# Test-module fakes shadow framework/peripheral names. These production source
# files are compiled directly without edits or textual transformations.
swiftc -swift-version 5 -disable-sandbox \
  -module-cache-path "$task_build_dir/module-cache" \
  -framework AppKit -framework LocalAuthentication \
  "$task_root/Sources/20261103_TouchIDSession.swift" \
  "$task_root/Sources/GuardController.swift" \
  "$task_root/Tests/20261103_GuardAuthenticationTests.swift" \
  -o "$task_build_dir/GuardAuthenticationTests"

"$task_build_dir/GuardAuthenticationTests"
