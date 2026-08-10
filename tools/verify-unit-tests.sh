#!/usr/bin/env bash
# Run the M1.5 kernel monitor module unit tests with `zig test`.
#
# The M1.5 kernel modules (kernel/src/*.zig) land across several PRs
# (agent C's commands slice, then the shell-core slice: lineedit, tokenizer,
# shell). A module that has not landed yet is skipped with a notice so this
# gate stays green on main; once a module exists it MUST pass. Keeping the
# module list here means CI (.github/workflows/ci.yml) and `just verify`
# test exactly the same set.
set -u

# Run from the repo root no matter where the script is invoked from, so a
# stray `just test` from a subdirectory cannot silently skip every module.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

MODULES=(alloc console esp exceptions fat gic handoff lineedit machine memmap monitor nvram_console shell timer tokenizer virtio_blk virtio_custom)

status=0
present=0
for name in "${MODULES[@]}"; do
  f="kernel/src/${name}.zig"
  if [ ! -f "$f" ]; then
    echo "skip $f (monitor module not yet landed)"
    continue
  fi
  present=1
  echo "== zig test $f =="
  if ! zig test "$f"; then
    status=1
  fi
done

if [ "$present" -eq 0 ]; then
  echo "verify-unit-tests: WARNING - no monitor modules present; nothing was tested (green badge here does not mean tests ran)" >&2
fi

if [ "$status" -ne 0 ]; then
  echo "verify-unit-tests: one or more module tests FAILED" >&2
  exit "$status"
fi
echo "verify-unit-tests: all present monitor modules passed"
exit 0
