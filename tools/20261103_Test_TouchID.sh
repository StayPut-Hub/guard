#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build_dir="$(mktemp -d /tmp/stayput-touchid-tests.XXXXXX)"
trap 'rm -rf "$task_build_dir"' EXIT

swiftc -swift-version 5 \
  -module-cache-path "$task_build_dir/module-cache" \
  -framework LocalAuthentication \
  "$task_root/Sources/20261103_TouchIDSession.swift" \
  "$task_root/Tests/20261103_TouchIDSessionTests.swift" \
  -o "$task_build_dir/TouchIDSessionTests"

"$task_build_dir/TouchIDSessionTests"
