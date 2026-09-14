#!/usr/bin/env bash
#
# test-gate-run.sh -- class-A self-test for the VZ preflight in
# tools/lib/gate-run.sh (claim #1259).
#
# Why this exists: the preflight's whole job is to FAIL LOUDLY in two cases
# that used to surface at VM boot as something else. A checker whose negative
# path is never exercised is the same class of bug it was written to catch --
# it can be wired backwards, or stop matching, and still report green. So the
# negative paths are asserted here, on a CI runner, with no VM anywhere.
#
# Hermetic by construction: `codesign` and `sysctl` are stubbed on PATH, so the
# real signature of any binary and the real capability of any host are
# irrelevant to the result. Class A -- runs in CI, needs no Apple silicon.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

# gate-run.sh sets -euo pipefail for its callers; every negative case below is
# an EXPECTED non-zero exit, so turn -e back off after sourcing.
# shellcheck source=tools/lib/gate-run.sh
source tools/lib/gate-run.sh
set +e

PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/virelai-test-gate-run.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# --- stubs ------------------------------------------------------------------
STUB_BIN="$TMP/bin"
mkdir -p "$STUB_BIN"

# codesign stub: prints $STUB_CODESIGN_OUT and exits $STUB_CODESIGN_RC.
cat > "$STUB_BIN/codesign" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${STUB_CODESIGN_OUT:-}"
exit "${STUB_CODESIGN_RC:-0}"
SH

# sysctl stub: answers the two keys the preflight reads.
# NOTE ${VAR-default}, not ${VAR:-default}: an explicitly empty value must
# stay empty, or the "capability unreadable" case cannot be expressed.
cat > "$STUB_BIN/sysctl" <<'SH'
#!/usr/bin/env bash
# usage: sysctl -n <key>
# STUB_SYSCTL_RC simulates an absent key / non-Darwin (sysctl exits non-zero).
[ -z "${STUB_SYSCTL_RC:-}" ] || exit "$STUB_SYSCTL_RC"
case "${2:-}" in
    kern.hv_support)     printf '%s\n' "${STUB_HV_SUPPORT-1}" ;;
    kern.hv_vmm_present) printf '%s\n' "${STUB_HV_VMM_PRESENT-0}" ;;
    *) exit 1 ;;
esac
SH
chmod +x "$STUB_BIN/codesign" "$STUB_BIN/sysctl"
PATH="$STUB_BIN:$PATH"

# --- fixtures ---------------------------------------------------------------
BIN="$TMP/VMRunner"
: > "$BIN"                                   # any file; the stub answers
MISSING="$TMP/definitely-not-built"

ENTITLED_OUT="Executable=$BIN
[Dict]
	[Key] com.apple.security.virtualization
	[Value]
		[Bool] true"
BARE_OUT="code object is not signed at all
In subcomponent: $BIN"

CASE_OUT=""
run() { CASE_OUT="$("$@" 2>&1)"; return $?; }

echo "=== test-gate-run: the VZ preflight fails loudly, and passes when it should ==="

# --- gate_assert_runner_entitled --------------------------------------------
echo
echo "── gate_assert_runner_entitled ──"

STUB_CODESIGN_OUT="$ENTITLED_OUT" STUB_CODESIGN_RC=0
export STUB_CODESIGN_OUT STUB_CODESIGN_RC
run gate_assert_runner_entitled "$BIN"; rc=$?
[ "$rc" = 0 ] && ok "entitled binary passes (rc=0)" \
              || bad "entitled binary should pass, got rc=$rc: $CASE_OUT"

STUB_CODESIGN_OUT="$BARE_OUT" STUB_CODESIGN_RC=1
export STUB_CODESIGN_OUT STUB_CODESIGN_RC
run gate_assert_runner_entitled "$BIN"; rc=$?
if [ "$rc" = 0 ]; then
    bad "UN-ENTITLED binary must fail, got rc=0"
else
    ok "un-entitled binary fails (rc=$rc)"
fi
case "$CASE_OUT" in
    *"$VZ_RUNNER_ENTITLEMENT"*) ok "the failure names the missing entitlement" ;;
    *) bad "the failure should name $VZ_RUNNER_ENTITLEMENT: $CASE_OUT" ;;
esac
case "$CASE_OUT" in
    *"--entitlements host/vm-runner/entitlements.plist"*) ok "the failure names the codesign fix" ;;
    *) bad "the failure should name the codesign command: $CASE_OUT" ;;
esac
case "$CASE_OUT" in
    *"swift build"*) ok "the failure names the bare-swift-build cause" ;;
    *) bad "the failure should mention the bare 'swift build' cause: $CASE_OUT" ;;
esac

run gate_assert_runner_entitled "$MISSING"; rc=$?
[ "$rc" != 0 ] && ok "a missing runner binary fails (rc=$rc)" \
               || bad "a missing runner binary must fail"

# Default argument must be the real runner path, not something else.
[ "$VZ_RUNNER_BIN" = "host/vm-runner/.build/release/VMRunner" ] \
    && ok "VZ_RUNNER_BIN is the release VMRunner path" \
    || bad "VZ_RUNNER_BIN is '$VZ_RUNNER_BIN'"

# --- gate_report_hv_capability ----------------------------------------------
echo
echo "── gate_report_hv_capability ──"

STUB_HV_SUPPORT=1 STUB_HV_VMM_PRESENT=0
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT
run gate_report_hv_capability; rc=$?
[ "$rc" = 0 ] && ok "hv_support=1 passes (rc=0)" || bad "hv_support=1 should pass, got rc=$rc: $CASE_OUT"
case "$CASE_OUT" in
    *"kern.hv_support=1"*) ok "the verdict line prints kern.hv_support=1" ;;
    *) bad "the verdict line should print the capability: $CASE_OUT" ;;
esac

STUB_HV_SUPPORT=0 STUB_HV_VMM_PRESENT=1
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT
run gate_report_hv_capability; rc=$?
if [ "$rc" = 0 ]; then
    bad "hv_support=0 must fail, got rc=0"
else
    ok "hv_support=0 fails (rc=$rc)"
fi
case "$CASE_OUT" in
    *"itself a VM"*) ok "it names the nested-virtualization case (hosted runner)" ;;
    *) bad "it should identify the host-is-a-guest case: $CASE_OUT" ;;
esac
case "$CASE_OUT" in
    *"regardless of the code under test"*) ok "it says the gate is not at fault" ;;
    *) bad "it should say the failure is not the gate's: $CASE_OUT" ;;
esac

# An absent sysctl (non-Darwin, or a key that is not there) must be a failure,
# never a silent pass.
STUB_SYSCTL_RC=1 STUB_HV_SUPPORT="" STUB_HV_VMM_PRESENT=""
export STUB_SYSCTL_RC STUB_HV_SUPPORT STUB_HV_VMM_PRESENT
run gate_report_hv_capability; rc=$?
[ "$rc" != 0 ] && ok "an unreadable kern.hv_support fails (rc=$rc)" \
               || bad "an unreadable kern.hv_support must not pass: $CASE_OUT"
unset STUB_SYSCTL_RC
STUB_HV_SUPPORT="" STUB_HV_VMM_PRESENT=""
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT
run gate_report_hv_capability; rc=$?
[ "$rc" != 0 ] && ok "an EMPTY kern.hv_support fails (rc=$rc)" \
               || bad "an empty kern.hv_support must not pass: $CASE_OUT"

# --- gate_preflight_vz: both checks, and both must hold ---------------------
echo
echo "── gate_preflight_vz ──"

STUB_HV_SUPPORT=1 STUB_HV_VMM_PRESENT=0 STUB_CODESIGN_OUT="$ENTITLED_OUT" STUB_CODESIGN_RC=0
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT STUB_CODESIGN_OUT STUB_CODESIGN_RC
run gate_preflight_vz "$BIN"; rc=$?
[ "$rc" = 0 ] && ok "capable host + entitled binary passes" \
              || bad "preflight should pass, got rc=$rc: $CASE_OUT"

STUB_CODESIGN_OUT="$BARE_OUT" STUB_CODESIGN_RC=1
export STUB_CODESIGN_OUT STUB_CODESIGN_RC
run gate_preflight_vz "$BIN"; rc=$?
[ "$rc" != 0 ] && ok "capable host + UN-entitled binary fails" \
               || bad "preflight must fail on an un-entitled binary"

STUB_HV_SUPPORT=0 STUB_HV_VMM_PRESENT=1 STUB_CODESIGN_OUT="$ENTITLED_OUT" STUB_CODESIGN_RC=0
export STUB_HV_SUPPORT STUB_HV_VMM_PRESENT STUB_CODESIGN_OUT STUB_CODESIGN_RC
run gate_preflight_vz "$BIN"; rc=$?
[ "$rc" != 0 ] && ok "incapable host fails even with an entitled binary" \
               || bad "preflight must fail on an incapable host"

# --- wiring invariants ------------------------------------------------------
# The helpers are only worth anything if the gate path actually calls them.
# These are source-level checks on purpose: removing the call is the silent
# regression this preflight exists to prevent.
echo
echo "── wiring ──"

grep -q 'gate_assert_runner_entitled' tools/lib/gate-run.sh \
    && ok "gate-run.sh defines/uses gate_assert_runner_entitled" \
    || bad "gate-run.sh does not reference gate_assert_runner_entitled"

awk '/^gate_build_runner\(\)/,/^}/' tools/lib/gate-run.sh | grep -q 'gate_assert_runner_entitled' \
    && ok "gate_build_runner asserts the entitlement it just applied" \
    || bad "gate_build_runner does not assert the entitlement"

awk '/^gate_preflight_vz\(\)/,/^}/' tools/lib/gate-run.sh | grep -q 'gate_report_hv_capability' \
    && ok "gate_preflight_vz includes the hv capability verdict" \
    || bad "gate_preflight_vz does not check hv capability"

grep -q 'gate_preflight_vz' tools/gate/vgate.sh \
    && ok "vgate.sh runs the preflight in the VZ gate path" \
    || bad "vgate.sh never runs gate_preflight_vz"

# The preflight must run for VGATE_NO_BUILD=1 too -- that is the branch where
# nothing has signed the binary.
awk '/gate_preflight_vz/{print NR}' tools/gate/vgate.sh > "$TMP/preflight.line"
awk '/gate_begin/{print NR; exit}' tools/gate/vgate.sh > "$TMP/begin.line"
if [ -s "$TMP/preflight.line" ] && [ -s "$TMP/begin.line" ] \
        && [ "$(head -1 "$TMP/preflight.line")" -lt "$(head -1 "$TMP/begin.line")" ]; then
    ok "the preflight runs before any VM boot (ahead of gate_begin)"
else
    bad "the preflight must run before gate_begin"
fi

echo
if [ "$FAIL" = 0 ]; then
    echo "test-gate-run: PASS — $PASS case(s), both preflight failure modes verified."
    exit 0
fi
echo "test-gate-run: FAIL — $FAIL of $((PASS + FAIL)) case(s) failed."
exit 1
