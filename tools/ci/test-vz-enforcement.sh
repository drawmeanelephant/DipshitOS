#!/usr/bin/env bash
#
# test-vz-enforcement.sh -- class-A self-test for the class-B CI verdict
# (tools/ci/vz-enforcement.sh; cards #1256, #1344, issue #1340).
#
# Why this exists: the verdict IS the merge gate for Apple-silicon VZ gates, so
# its refusal paths have to be exercised somewhere that is not a merge. The two
# states that used to be indistinguishable both conclude `success` at the job
# level -- "the shards ran the whole discovered fleet" and "the shards ran
# nothing" -- and the check was green in the second one, twice over: a skipped
# shard, and a shard whose gate loop never iterated because it read a file no
# step wrote (a failed input redirect runs zero iterations and exits 0 even
# under `set -e`). The skip (no-runner / fork-pr) is NOT ENFORCED (warning,
# exit 0): failing it blocked every PR while no Apple-silicon runner exists
# (card #1353). A shard whose gate loop never iterated is still REFUSED.
# OK requires that the receipts account for the discovered fleet exactly.
#
# Hermetic: no runner, no VM, no network. Receipts are synthetic, and the fleet
# count is either a fixture or the real `tools/gate/fleet.sh count`.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

VERDICT="tools/ci/vz-enforcement.sh"
PASS=0 FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL  $1"; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/virelai-test-vz-enforcement.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# run <args...> -- capture stdout+stderr of the verdict script and its rc, so
# every assertion below can be about the verdict, not about the console.
run() { CASE_OUT="$("$@" 2>&1)"; return $?; }

# mk_receipt DIR NAME SHARD OF RAN FAILED REASON -- one shard's receipt, laid
# out exactly as the workflow uploads it (one artifact directory per shard).
mk_receipt() {
    mkdir -p "$1/$2"
    {
        echo "shard=$3"
        echo "of=$4"
        echo "ran=$5"
        echo "failed=$6"
        echo "reason=$7"
    } > "$1/$2/receipt.env"
}

# expect_rc RC WANT LABEL -- the verdict's exit status, named.
expect_rc() {
    if [ "$1" = "$2" ]; then ok "$3 (rc=$1)"; else bad "$3: expected rc=$2, got rc=$1 -- $CASE_OUT"; fi
}
expect_word() {
    case "$CASE_OUT" in
        *"$2"*) ok "$1" ;;
        *) bad "$1: output does not mention '$2': $CASE_OUT" ;;
    esac
}

echo "=== test-vz-enforcement: green means the fleet ran, or no runner exists ==="

# --- the verdict tokens are the contract the workflow and tests share --------
echo
echo "── the contract (reason tokens) ──"

R="$TMP/empty"; mkdir -p "$R"
run bash "$VERDICT" --fleet 0 --shards 4 --shard-result success; rc=$?
expect_rc "$rc" 1 "an empty discovered fleet is refused"
expect_word "it names the empty fleet" "reason=fleet-empty"

run bash "$VERDICT" --fleet 235 --shards 4 --shard-result failure; rc=$?
expect_rc "$rc" 1 "a failed shard is refused"
expect_word "it names the shard failure" "reason=shard-failed"

run bash "$VERDICT" --fleet 235 --shards 4 --shard-result cancelled; rc=$?
expect_rc "$rc" 1 "a cancelled shard is refused"
expect_word "it names the shard failure" "reason=shard-failed"

run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --skip-flag 1; rc=$?
expect_rc "$rc" 0 "a shard that declared a skip is not a merge failure"
expect_word "it names non-enforcement" "verdict=unenforced reason=not-enforced"
expect_word "it says how many gates ran" "0 of 235 class-B gates ran"
expect_word "it points at the registration doc" "docs/vz-runner.md"

run bash "$VERDICT" --fleet 235 --shards 4 --shard-result skipped; rc=$?
expect_rc "$rc" 0 "a job-level skip is not a merge failure"
expect_word "it names non-enforcement" "verdict=unenforced reason=not-enforced"

# --- the state that made this necessary: green, and nothing ran --------------
echo
echo "── a shard that concluded success having run nothing ──"

run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$R"; rc=$?
expect_rc "$rc" 1 "success with no receipt at all is refused"
expect_word "it names the missing evidence" "reason=no-receipts"
expect_word "it names the defect class" "never iterated"

Z="$TMP/zero"
for s in 0 1 2 3; do mk_receipt "$Z" "vz-receipt-shard-$s" "$s" 4 0 0 no-runner; done
run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$Z"; rc=$?
expect_rc "$rc" 0 "receipts that all record no-runner are not a merge failure"
expect_word "it names non-enforcement" "verdict=unenforced reason=not-enforced"
expect_word "it carries the shards' own reason" "no-runner"

FORK="$TMP/fork"
for s in 0 1 2 3; do mk_receipt "$FORK" "vz-receipt-shard-$s" "$s" 4 0 0 fork-pr; done
run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$FORK"; rc=$?
expect_rc "$rc" 0 "fork-pr receipts are not a merge failure"
expect_word "it names non-enforcement for a fork" "verdict=unenforced reason=not-enforced"
expect_word "it carries the fork reason" "fork-pr"

# The real shard loop, before its fix, left a receipt with reason=ran and ran=0
# (it reached the end of the step without executing a gate). That must not be a
# pass either, and it must be distinguishable from a deliberate skip.
ZG="$TMP/zero-gates"
for s in 0 1 2 3; do mk_receipt "$ZG" "vz-receipt-shard-$s" "$s" 4 0 0 zero-gates; done
run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$ZG"; rc=$?
expect_rc "$rc" 1 "a shard that reached its gate step but ran 0 gates is refused"
expect_word "it names the zero-gate refusal" "reason=zero-gates"
expect_word "it carries the shard's own reason" "zero-gates"

# --- the happy path, and the arithmetic it must not skip --------------------
echo
echo "── OK requires the receipts to account for the whole fleet ──"

FULL="$TMP/full"
mk_receipt "$FULL" "vz-receipt-shard-0" 0 4 59 0 ran
mk_receipt "$FULL" "vz-receipt-shard-1" 1 4 59 0 ran
mk_receipt "$FULL" "vz-receipt-shard-2" 2 4 58 0 ran
mk_receipt "$FULL" "vz-receipt-shard-3" 3 4 59 0 ran
run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$FULL"; rc=$?
expect_rc "$rc" 0 "59+59+58+59 = 235 of 235 passes"
expect_word "it states the verdict token" "verdict=ok reason=enforced"
expect_word "it states the arithmetic" "235 of 235 class-B gates executed"
expect_word "it lists the per-shard counts" "#2=58"

PART="$TMP/partial"
mk_receipt "$PART" "vz-receipt-shard-0" 0 4 25 0 ran
mk_receipt "$PART" "vz-receipt-shard-1" 1 4 25 0 ran
mk_receipt "$PART" "vz-receipt-shard-2" 2 4 25 0 ran
mk_receipt "$PART" "vz-receipt-shard-3" 3 4 25 0 ran
run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$PART"; rc=$?
expect_rc "$rc" 1 "a run covering 100 of 235 gates is refused"
expect_word "it names the partial run" "reason=partial-run"
expect_word "it names what was covered" "executed 100 of 235"

MISS="$TMP/missing"
mk_receipt "$MISS" "vz-receipt-shard-0" 0 4 59 0 ran
mk_receipt "$MISS" "vz-receipt-shard-1" 1 4 59 0 ran
mk_receipt "$MISS" "vz-receipt-shard-2" 2 4 59 0 ran
run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$MISS"; rc=$?
expect_rc "$rc" 1 "three receipts for four shards is refused"
expect_word "it names the missing evidence" "reason=partial-evidence"
expect_word "it names the shard with no receipt" "No receipt from shard(s): 3"

DUP="$TMP/dup"
mk_receipt "$DUP" "vz-receipt-shard-0" 0 4 59 0 ran
mk_receipt "$DUP" "vz-receipt-shard-1" 1 4 59 0 ran
mk_receipt "$DUP" "vz-receipt-shard-2" 2 4 58 0 ran
mk_receipt "$DUP" "vz-receipt-shard-3" 3 4 59 0 ran
mk_receipt "$DUP" "vz-receipt-shard-9" 3 4 59 0 ran
run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$DUP"; rc=$?
expect_rc "$rc" 1 "two receipts claiming one shard is refused"
expect_word "it names the inconsistency" "reason=receipt-mismatch"
expect_word "it names the duplicated shard" "More than one receipt claims shard(s): 3"

OF="$TMP/of"
mk_receipt "$OF" "vz-receipt-shard-0" 0 3 78 0 ran
mk_receipt "$OF" "vz-receipt-shard-1" 1 3 78 0 ran
mk_receipt "$OF" "vz-receipt-shard-2" 2 3 79 0 ran
run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$OF"; rc=$?
expect_rc "$rc" 1 "receipts recorded against a different shard count are refused"
expect_word "it names the inconsistency" "reason=receipt-mismatch"

FAILED="$TMP/failed"
mk_receipt "$FAILED" "vz-receipt-shard-0" 0 4 59 1 ran
mk_receipt "$FAILED" "vz-receipt-shard-1" 1 4 59 0 ran
mk_receipt "$FAILED" "vz-receipt-shard-2" 2 4 58 0 ran
mk_receipt "$FAILED" "vz-receipt-shard-3" 3 4 59 0 ran
run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$FAILED"; rc=$?
expect_rc "$rc" 1 "a receipt recording a failed gate is refused even if the job concluded success"
expect_word "it names the gate failure" "reason=gate-failed"

MALFORMED="$TMP/malformed"; mkdir -p "$MALFORMED/vz-receipt-shard-0"
printf 'shard=0 of=4 ran=235\n' > "$MALFORMED/vz-receipt-shard-0/receipt.env"
run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$MALFORMED"; rc=$?
expect_rc "$rc" 1 "a receipt with no reason field is refused"
expect_word "it names the inconsistency" "reason=receipt-mismatch"

# A missing --receipts directory is the same class of gap as a missing receipt:
# the verdict must not fall through to OK because the directory did not exist.
run bash "$VERDICT" --fleet 235 --shards 4 --shard-result success --receipts "$TMP/never-created"; rc=$?
expect_rc "$rc" 1 "a receipts directory that does not exist is refused"
expect_word "it names the missing evidence" "reason=no-receipts"

# --- against the real fleet, not a fixture ---------------------------------
echo
echo "── the real discovered fleet ──"

FLEET="$(bash tools/gate/fleet.sh count)"
if [ -n "$FLEET" ] && [ "$FLEET" -gt 0 ]; then
    ok "tools/gate/fleet.sh count = $FLEET"
else
    bad "tools/gate/fleet.sh count returned '$FLEET'"
fi

# Partition the real fleet across four shards the way the workflow does, and
# require the verdict to accept it. This is the invariant the shards must keep:
# the shard assignment (index % SHARD_COUNT) covers every member exactly once.
REAL="$TMP/real"
bash tools/gate/fleet.sh list > "$TMP/fleet.tsv"
i=0
for s in 0 1 2 3; do
    # Same assignment as the workflow: idx is 1-based NR, shard = (idx-1) % N.
    n=$(awk -v s="$s" -v c=4 '(NR - 1) % c == s' "$TMP/fleet.tsv" | wc -l | tr -d ' ')
    mk_receipt "$REAL" "vz-receipt-shard-$s" "$s" 4 "$n" 0 ran
    i=$((i + n))
done
if [ "$i" = "$FLEET" ]; then
    ok "the shard assignment (index % 4) covers all $FLEET members exactly once"
else
    bad "shard assignment covers $i of $FLEET members"
fi
run bash "$VERDICT" --fleet "$FLEET" --shards 4 --shard-result success --receipts "$REAL"; rc=$?
expect_rc "$rc" 0 "the real fleet partitioned across four shards passes"
expect_word "it states the real total" "$FLEET of $FLEET class-B gates executed"

# --- wiring: the workflow must actually use all of this ---------------------
echo
echo "── the workflow wiring ──"

WF=".github/workflows/vz-gates.yml"

grep -q 'tools/ci/vz-enforcement.sh' "$WF" \
    && ok "the aggregate calls the verdict script" \
    || bad "the aggregate does not call tools/ci/vz-enforcement.sh -- the check would still decide by flag"

grep -q 'REFUSED' "$WF" && ok "the aggregate expects a refusal state" \
    || bad "the aggregate has no refusal path"

# The regression that motivated this card: the shard loop was fed from a file no
# step writes. Assert the redirect names a file the same step creates.
awk '/done < \/tmp\//{print; exit}' "$WF" > "$TMP/redirect"
if [ -s "$TMP/redirect" ]; then
    target="$(sed -e 's/.*< //' "$TMP/redirect")"
    if grep -q "> $target" "$WF"; then
        ok "the shard loop is fed from a file the workflow writes ($target)"
    else
        bad "the shard loop reads $target, which no step writes -- it would run 0 gates and exit 0"
    fi
else
    bad "could not find the shard loop's input redirect in $WF"
fi

grep -q 'receipt.env' "$WF" \
    && ok "the shards write an execution receipt" \
    || bad "no shard writes a receipt, so the verdict can never be enforced"

# A shard that executes nothing must fail, not warn: a ::warning:: is invisible
# on a green check, which is the whole defect class.
if grep -q 'Shard had zero gates' "$WF"; then
    bad "a zero-gate shard still only warns; it must exit non-zero"
else
    ok "a zero-gate shard no longer warns-and-passes"
fi

# --- the shard step, EXECUTED ----------------------------------------------
# Greps cannot tell a receipt from a receipt-shaped comment, and the defect that
# made this card necessary was a wrong filename inside the loop. So run the real
# step body here: extract it from the workflow, substitute the matrix shard, and
# give it a sandbox whose fleet is two trivial "gates". No VM, no runner, and it
# is the same text CI will run.
echo
echo "── the shard step, executed on a sandbox fleet ──"

awk '
    /- name: Run this shard.s class-B gates/ { inseg = 1; next }
    inseg && /^        run: \|/ { inrun = 1; next }
    inrun {
        if ($0 ~ /^          /) { sub(/^          /, ""); print; next }
        if ($0 ~ /^[[:space:]]*$/) { print; next }
        exit
    }
' "$WF" > "$TMP/shard-step.raw"
sed 's/\${{ matrix\.shard }}/0/g' "$TMP/shard-step.raw" > "$TMP/shard-step.sh"
if [ -s "$TMP/shard-step.sh" ] && grep -q 'fleet.tsv' "$TMP/shard-step.sh"; then
    ok "extracted the shard step body from the workflow ($(wc -l < "$TMP/shard-step.sh" | tr -d ' ') lines)"
else
    bad "could not extract the shard step body from $WF"
fi

# sandbox_case MEMBERS -- build a sandbox whose discovered fleet is the given
# TSV lines, run the step body with SHARD_COUNT=1 (so one shard owns the whole
# fake fleet), and leave the receipt in $TMP/sbx/artifacts/vz-ci/ plus the
# step's combined output in $CASE_OUT.
sandbox_case() {
    rm -rf "$TMP/sbx"
    mkdir -p "$TMP/sbx/tools/gate" "$TMP/sbx/artifacts"
    if [ -n "$1" ]; then printf '%s\n' "$1" > "$TMP/sbx/fleet.tsv"; else : > "$TMP/sbx/fleet.tsv"; fi
    cat > "$TMP/sbx/tools/gate/fleet.sh" <<'SH'
#!/usr/bin/env bash
# stand-in for the discovered class-B fleet (one kind<TAB>id line per member)
case "${1:-}" in
    list) cat "$(dirname "$0")/../../fleet.tsv" ;;
    count) wc -l < "$(dirname "$0")/../../fleet.tsv" | tr -d ' ' ;;
    *) echo "fleet.sh: unknown subcommand" >&2; exit 2 ;;
esac
SH
    for g in zz-fake-pass zz-fake-pass2; do
        cat > "$TMP/sbx/tools/$g.sh" <<'SH'
#!/usr/bin/env bash
echo "fake gate: ok"
exit 0
SH
    done
    cat > "$TMP/sbx/tools/zz-fake-fail.sh" <<'SH'
#!/usr/bin/env bash
echo "fake gate: a deliberately failing gate"
exit 1
SH
    chmod +x "$TMP/sbx/tools/gate/fleet.sh" "$TMP/sbx/tools/zz-fake-pass.sh" \
        "$TMP/sbx/tools/zz-fake-pass2.sh" "$TMP/sbx/tools/zz-fake-fail.sh"
    CASE_OUT="$(cd "$TMP/sbx" && SHARD_COUNT=1 GATE_TIMEOUT_SECS=30 bash "$TMP/shard-step.sh" 2>&1)"
    SANDBOX_RC=$?
    RECEIPT="$TMP/sbx/artifacts/vz-ci/receipt.env"
}
receipt_has() { grep -qx "$1" "$RECEIPT" 2>/dev/null; }

sandbox_case 'script	zz-fake-pass
script	zz-fake-pass2'
rc="$SANDBOX_RC"
[ "$rc" = 0 ] && ok "a shard whose fake gates pass exits 0" \
             || bad "a passing sandbox shard exited $rc: $CASE_OUT"
if [ -f "$RECEIPT" ]; then
    ok "it wrote a receipt"
    receipt_has "ran=2" && ok "the receipt counts the 2 gates it ran" \
                        || bad "receipt does not record ran=2: $(cat "$RECEIPT")"
    receipt_has "failed=0" && ok "the receipt records zero failures" \
                          || bad "receipt does not record failed=0: $(cat "$RECEIPT")"
    receipt_has "reason=ran" && ok "the receipt's reason is 'ran'" \
                            || bad "receipt reason is not 'ran': $(cat "$RECEIPT")"
    receipt_has "of=1" && ok "the receipt records the shard count it ran under" \
                       || bad "receipt does not record of=1: $(cat "$RECEIPT")"
else
    bad "the shard step wrote no receipt -- the verdict could never be enforced"
fi

# A failing gate: the shard fails, and it STILL reports what it managed to run
# (the receipt is written before the failure exit).
sandbox_case 'script	zz-fake-pass
script	zz-fake-fail'
rc="$SANDBOX_RC"
[ "$rc" != 0 ] && ok "a shard with a failing gate exits non-zero" \
               || bad "a failing fake gate left the shard green"
receipt_has "ran=2" && ok "the failing shard still recorded ran=2" \
                    || bad "a failing shard left no usable receipt: $(cat "$RECEIPT" 2>/dev/null)"
receipt_has "failed=1" && ok "it recorded the failure it saw" \
                      || bad "receipt does not record failed=1: $(cat "$RECEIPT" 2>/dev/null)"

# THE REGRESSION: an empty discovered fleet. Before the fix this warned and
# exited 0 -- a PASS recorded for a shard that executed nothing, reachable by
# accident because the loop's input file did not exist.
sandbox_case ''
rc="$SANDBOX_RC"
[ "$rc" != 0 ] && ok "a shard that executes 0 gates exits non-zero" \
               || bad "a zero-gate shard exited 0 -- the false-PASS path is back"
receipt_has "ran=0" && ok "the zero-gate shard still recorded ran=0" \
                   || bad "a zero-gate shard left no receipt: $(cat "$RECEIPT" 2>/dev/null)"
receipt_has "reason=zero-gates" && ok "and says why it ran nothing" \
                              || bad "receipt reason is not 'zero-gates': $(cat "$RECEIPT" 2>/dev/null)"

# ... and the verdict reads that receipt as a refusal, end to end.
mkdir -p "$TMP/sbx/receipts/vz-receipt-shard-0"
cp "$RECEIPT" "$TMP/sbx/receipts/vz-receipt-shard-0/receipt.env" 2>/dev/null || true
run bash "$VERDICT" --fleet 234 --shards 1 --shard-result success --receipts "$TMP/sbx/receipts"; rc=$?
[ "$rc" = 1 ] && ok "the verdict refuses that shard's receipt (rc=1)" \
             || bad "the verdict accepted a zero-gate receipt: $CASE_OUT"
expect_word "it names the reason the shard gave" "zero-gates"

echo
if [ "$FAIL" = 0 ]; then
    echo "test-vz-enforcement: PASS — $PASS case(s): every refusal state, the receipts' arithmetic, the real fleet, and the workflow wiring."
    exit 0
fi
echo "test-vz-enforcement: FAIL — $FAIL of $((PASS + FAIL)) case(s) failed." >&2
exit 1
