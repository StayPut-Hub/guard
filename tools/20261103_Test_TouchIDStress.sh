#!/bin/bash
set -euo pipefail

task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build_dir="$(mktemp -d /tmp/stayput-touchid-stress.XXXXXX)"
trap 'rm -rf "$task_build_dir"' EXIT

swiftc -swift-version 5 \
  -module-cache-path "$task_build_dir/module-cache" \
  -framework LocalAuthentication \
  "$task_root/Sources/20261103_TouchIDSession.swift" \
  "$task_root/Tests/20261103_TouchIDStressTests.swift" \
  -o "$task_build_dir/TouchIDStressTests"

# Framework diagnostic messages are verbose during the 1,000-session stress run.
"$task_build_dir/TouchIDStressTests" 2> "$task_build_dir/session.log"
