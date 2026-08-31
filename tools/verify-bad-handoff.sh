#!/usr/bin/env bash
set -euo pipefail

zig build -Dbad-handoff=true bad-handoff
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
set +e
host/vm-runner/.build/release/VMRunner artifacts/bad-handoff.img artifacts/bad-handoff-serial.log --timeout 30 --expect "firmware has agreed to cooperate" > artifacts/m2-bad-handoff-runner.txt 2>&1
RUNNER_RC=$?
set -e
RC="$(python3 image/mkfat32.py --cat-file /RC.TXT artifacts/bad-handoff.img 2>/dev/null || true)"
printf '%s\n' "$RC"
if [ "$RUNNER_RC" -eq 0 ]; then
    echo "bad handoff unexpectedly satisfied the normal runner evidence gate" >&2
    exit 1
fi
printf '%s' "$RC" | grep -Eq 'kernel_rc=0x0*[1-9a-f]' || {
    echo "bad handoff did not produce a non-zero RC.TXT" >&2
    exit 1
}
if grep -q 'VirelaiOS kernel has seized control.' artifacts/bad-handoff-serial.log 2>/dev/null; then
    echo "bad handoff unexpectedly produced the takeover banner" >&2
    exit 1
fi
