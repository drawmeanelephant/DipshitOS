#!/usr/bin/env bash
# Run the VirelaiOS unit test suites.
#
# M41 cutover: Runs the unified parallel `zig build test` pipeline across all
# kernel modules, decoupled test suites (syscall, scheduler, monitor, shell,
# alloc, net, driving_award, ui), and shared test mocks. Also supports legacy
# individual module testing if arguments are passed.
set -euo pipefail

# Run from the repo root no matter where the script is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "$#" -gt 0 ]; then
  # Compatibility mode: run specific test targets
  echo "== zig test $@ =="
  zig test "$@"
  exit 0
fi

echo "=== verify-unit-tests: running unified parallel test suite (zig build test) ==="
zig build test --summary all

echo "verify-unit-tests: all unit tests passed"
exit 0
