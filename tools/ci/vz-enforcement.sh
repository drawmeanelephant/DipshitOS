#!/usr/bin/env bash
#
# vz-enforcement.sh -- the verdict for the required "VZ hardware gates" check.
#
# WHY THIS IS NOT INLINE YAML. The check is a merge gate, so its verdict has to
# be testable without a runner, a fork or a VM -- the same reason
# tools/gate/test-gate-run.sh exists for the gate harness. Everything that
# decides OK-vs-refused lives here, and tools/ci/test-vz-enforcement.sh drives
# every state on a laptop.
#
# WHY IT IS EVIDENCE-BASED. The aggregate used to decide from a self-declared
# skip flag, and a flag cannot tell "the shards ran the whole discovered fleet"
# from "the shards concluded success without executing anything". The second is
# not hypothetical: the shard loop reads /tmp/shard-gates.txt, a file NO step
# writes (GF5 renamed it to fleet.tsv and missed the redirect at the loop), and
# a failed input redirect runs zero iterations and exits 0 even under `set -e`
# -- so with a runner registered every shard would have printed PASS having run
# nothing and the aggregate would have printed OK (issue #1340; cards #1256,
# #1344). A green check has to mean measured execution, so each shard leaves a
# receipt and this script requires the receipts to account for the discovered
# fleet exactly.
#
# Usage:
#   bash tools/ci/vz-enforcement.sh --fleet <n> --shards <n> \
#       --shard-result <success|failure|cancelled|skipped> \
#       [--skip-flag <0|1|''>] [--receipts <dir>]
#
#   --fleet        the discovered class-B fleet size (tools/gate/fleet.sh count)
#   --shards       the number of shards that were supposed to run
#   --shard-result the collapsed matrix result (needs.<job>.result)
#   --skip-flag    a shard's vz_skipped output; context only, never a pass
#   --receipts     a directory holding <artifact>/receipt.env per shard, with
#                  key=value lines: shard= of= ran= failed= reason=
#
# Exit status: 0 only when the receipts account for the whole fleet and nothing
# failed. 1 otherwise, with a report on stdout suitable for a run summary and a
# "verdict=<...> reason=<...>" token line for tests and logs.

set -uo pipefail

FLEET="" SHARDS="" SHARD_RESULT="" SKIP_FLAG="" RECEIPTS=""

usage() {
    sed -n 's/^#   //p' "$0" | sed -n '/^Usage:/,/^# Exit/p'
    exit "${1:-2}"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --fleet)        FLEET="${2:-}"; shift 2 ;;
        --shards)       SHARDS="${2:-}"; shift 2 ;;
        --shard-result) SHARD_RESULT="${2:-}"; shift 2 ;;
        --skip-flag)    SKIP_FLAG="${2:-}"; shift 2 ;;
        --receipts)     RECEIPTS="${2:-}"; shift 2 ;;
        -h|--help)      usage 0 ;;
        *) echo "vz-enforcement: unknown argument: $1" >&2; usage 2 ;;
    esac
done

is_uint() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

if ! is_uint "$FLEET" || ! is_uint "$SHARDS"; then
    echo "vz-enforcement: --fleet and --shards must be non-negative integers (got fleet='$FLEET' shards='$SHARDS')" >&2
    usage 2
fi

# receipt_field FILE KEY -- the first value recorded for KEY, or empty.
receipt_field() { sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1; }

# The failure mode this whole script exists for: say REFUSED, explain, exit 1.
# The report is markdown because the aggregate appends it to the run summary; the
# annotation is a separate trailing line so the reason also lands on the PR
# rather than only in a log nobody opens (the workflow filters `::` lines out of
# the summary).
refuse() {
    reason="$1"; headline="$2"; shift 2
    echo "### VZ hardware gates — **REFUSED: $headline**"
    echo
    for line in "$@"; do echo "$line"; done
    echo
    if [ "$reason" = not-enforced ]; then
        echo "Register a runner per \`docs/vz-runner.md\`, then set the repository variable"
        echo "\`VZ_RUNNER_LABEL\` to its label — or merge with the explicit bypass this ruleset"
        echo "is configured to require. Either way the absence is on the record."
        echo
    fi
    echo "This check is the merge gate for the Apple-silicon Virtualization.framework gates,"
    echo "so it reports nothing it cannot evidence (issue #1256, card #1344)."
    echo
    echo "verdict=refused reason=$reason"
    echo "::error title=VZ hardware gates REFUSED ($reason)::$headline"
    exit 1
}

if [ "$FLEET" -eq 0 ]; then
    refuse fleet-empty "the discovered class-B fleet is empty" \
        "The fleet is discovered from \`tools/gate/specs/\` (\`tools/gate/fleet.sh count\`" \
        "returned 0), so this run could not have enforced anything. A checkout or" \
        "discovery problem is not a pass."
fi

case " $SHARD_RESULT " in
    *" failure "*|*" cancelled "*)
        refuse shard-failed "a class-B shard failed" \
            "The collapsed matrix result is \`$SHARD_RESULT\`, so at least one shard did" \
            "not finish its gates. See that shard's log and the \`vz-gate-logs-*\` artifact." ;;
esac

skipped=0
case " $SHARD_RESULT " in *" skipped "*) skipped=1 ;; esac
[ "$SKIP_FLAG" = "1" ] && skipped=1

# --- the receipts: what the shards actually executed -------------------------
count=0 sum_ran=0 sum_failed=0 seen="" dup="" mismatch="" shard_ran="" skipped_reasons=""

if [ -n "$RECEIPTS" ] && [ -d "$RECEIPTS" ]; then
    for f in "$RECEIPTS"/*/receipt.env "$RECEIPTS"/receipt.env; do
        [ -f "$f" ] || continue
        shard="$(receipt_field "$f" shard)"
        of="$(receipt_field "$f" of)"
        ran="$(receipt_field "$f" ran)"
        failed="$(receipt_field "$f" failed)"
        reason="$(receipt_field "$f" reason)"
        if ! is_uint "$shard" || ! is_uint "$ran" || ! is_uint "$failed" || [ -z "$reason" ]; then
            mismatch="${mismatch} $f (unreadable: shard='$shard' ran='$ran' failed='$failed' reason='$reason')"
            continue
        fi
        if [ "$of" != "$SHARDS" ]; then
            mismatch="${mismatch} shard $shard (recorded of='$of', expected $SHARDS)"
        fi
        case "$seen" in
            *" $shard "*) dup="${dup} $shard" ;;
        esac
        seen="${seen}${shard} "
        count=$((count + 1))
        sum_ran=$((sum_ran + ran))
        sum_failed=$((sum_failed + failed))
        shard_ran="${shard_ran}#${shard}=${ran} "
        if [ "$ran" -eq 0 ]; then
            skipped_reasons="${skipped_reasons} ${reason}"
        fi
    done
fi

if [ -n "$mismatch" ]; then
    refuse receipt-mismatch "the execution receipts do not add up" \
        "Malformed or inconsistent receipt(s):$mismatch" \
        "A receipt that cannot be read is not evidence, so this run is not a pass."
fi

if [ -n "$dup" ]; then
    refuse receipt-mismatch "the execution receipts do not add up" \
        "More than one receipt claims shard(s):$dup — the shards would be counted twice," \
        "so their sum cannot stand for the fleet."
fi

if [ "$count" -eq 0 ]; then
    if [ "$skipped" -eq 1 ]; then
        refuse not-enforced "0 of $FLEET class-B gates ran" \
            "Every shard exited 0 behind the \`VZ_SKIPPED\` marker: no VZ-capable runner is" \
            "registered under the repository variable \`VZ_RUNNER_LABEL\`, or this is a fork" \
            "PR (which never runs on the self-hosted runner by policy)." \
            "The check was green before this change because it had nothing to fail on." \
            "GitHub-hosted runners cannot substitute ([actions/runner-images#13505]" \
            "(https://github.com/actions/runner-images/issues/13505), closed as not planned):" \
            "Hypervisor.framework is unavailable on them, so Virtualization.framework cannot" \
            "boot a guest there at any macOS version."
    fi
    refuse no-receipts "no execution receipt from any shard" \
        "All shards concluded \`$SHARD_RESULT\` yet left no receipt, so this run cannot show" \
        "that a single gate was executed. That is the signature of a shard whose gate loop" \
        "never iterated — the defect this check was rewritten to catch (the loop read a file" \
        "no step wrote) — not a pass."
fi

if [ "$sum_failed" -gt 0 ]; then
    refuse gate-failed "$sum_failed class-B gate(s) failed" \
        "The shards recorded $sum_failed failing gate(s) across $count receipt(s). A failing" \
        "class-B gate is a real regression; fix it rather than re-running."
fi

if [ "$sum_ran" -eq 0 ]; then
    refuse not-enforced "0 of $FLEET class-B gates ran" \
        "All $count shard(s) left a receipt and every one of them executed zero gates" \
        "(reason(s):${skipped_reasons:- unknown}). Nothing about guest behavior was proven." \
        "The check was green before this change because it had nothing to fail on."
fi

# Every shard that was supposed to run must show up, and their total must be the
# discovered fleet. Both are measured, not declared: a shard that is missing from
# the receipts may have been skipped by the matrix, and a total below the fleet
# means some members were never executed by anyone.
missing=""
i=0
while [ "$i" -lt "$SHARDS" ]; do
    case " $seen " in
        *" $i "*) ;;
        *) missing="${missing} $i" ;;
    esac
    i=$((i + 1))
done

if [ -n "$missing" ]; then
    refuse partial-evidence "only $count of $SHARDS shards left a receipt" \
        "No receipt from shard(s):$missing — those shards' gates were not executed by" \
        "anyone, so the fleet is not covered. (A matrix whose shard count does not match" \
        "SHARD_COUNT looks exactly like this.)"
fi

if [ "$sum_ran" -ne "$FLEET" ]; then
    refuse partial-run "the shards executed $sum_ran of $FLEET class-B gates" \
        "Receipts per shard: ${shard_ran}" \
        "Every discovered fleet member must be executed by exactly one shard; $((FLEET - sum_ran))" \
        "member(s) were not. A partial run is not enforcement."
fi

echo "### VZ hardware gates — OK"
echo
echo "$sum_ran of $FLEET class-B gates executed across $SHARDS shard(s): ${shard_ran}"
echo "0 failed."
echo
echo "verdict=ok reason=enforced ran=$sum_ran fleet=$FLEET shards=$SHARDS"
echo "::notice title=VZ hardware gates OK::$sum_ran of $FLEET class-B gates executed on VZ hardware."
exit 0
