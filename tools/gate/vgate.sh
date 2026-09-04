#!/usr/bin/env bash
#
# vgate.sh -- the single runner for declarative class-B gate specs
# (M40 GF2, issue #937, claim #944). A spec DECLARES (meta, files, runs,
# asserts); this harness EXECUTES (one shared build preamble, gate-run.sh
# isolation, runner invoke, assert eval, report + evidence).
#
# Usage:
#   bash tools/gate/vgate.sh tools/gate/specs/<name>.spec
#
# Spec format: tools/gate/SPEC.md (frozen at GF2 close -- extend it there,
# never with one-off shell).
#
# Environment:
#   VGATE_NO_BUILD=1   skip the build preamble (dev iteration; the caller
#                      vouches the tree is already built + imaged).
#   BOOTS / VIRELAI_GATE_SUFFIX / VIRELAI_KEEP_RUN / VIRELAI_RUN_DIR_BASE
#                      honored exactly like the legacy scripts.
#
set -euo pipefail

VGATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$VGATE_DIR/../.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

[ $# -eq 1 ] || { echo "vgate: usage: bash tools/gate/vgate.sh <spec>" >&2; exit 2; }
SPEC="$1"
[ -f "$SPEC" ] || { echo "vgate: spec not found: $SPEC" >&2; exit 2; }

# --- plan state (filled by the spec via the DSL below) -----------------------
VGATE_NAME="" VGATE_DESC="(no description)" VGATE_SHARE="none"
VGATE_FMT="boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig"
VGATE_RUNNER_FLAGS="" VGATE_REPEAT=1 VGATE_REPEAT_ENV=""
VGATE_NOTES=() VGATE_FILE_NAMES=() VGATE_FILE_BODIES=()
VGATE_SETUP_PY=() VGATE_RUN_TAGS=() VGATE_RUN_FLAGS=() VGATE_ALLOW_RC=() VGATE_ASSERTS=()

# --- DSL (the only commands a spec may use) ----------------------------------
vgate_name() { VGATE_NAME="$1"; VGATE_DESC="${2:-$VGATE_DESC}"; }
vgate_share() { case "$1" in none|arm|seed) VGATE_SHARE="$1";; *) echo "vgate: bad share mode: $1" >&2; exit 2;; esac; }
vgate_fmt() { VGATE_FMT="$*"; }
vgate_runner_flags() { VGATE_RUNNER_FLAGS="$*"; }
vgate_repeat() { VGATE_REPEAT="$1"; VGATE_REPEAT_ENV="${2:-}"; }
vgate_note() { VGATE_NOTES+=("$1"); }
vgate_file() {
    # NOTE: $(cat) strips ALL trailing newlines, which glues the last
    # script line to the next forwarded chunk (observed: `echo
    # arp-phase1-ready` + `net recv` executed as one line). Re-append
    # exactly one: bodies are newline-terminated files by contract.
    local b; b="$(cat; echo x)"; b="${b%x}"
    VGATE_FILE_NAMES+=("$1"); VGATE_FILE_BODIES+=("$b");
}
vgate_setup_python() { local b; b="$(cat; echo x)"; b="${b%x}"; VGATE_SETUP_PY+=("$b"); }
vgate_run() {
    # vgate_run TAG -- <runner flags...>
    local tag="$1"; shift
    [ "${1:-}" = "--" ] || { echo "vgate: vgate_run $tag missing -- separator" >&2; exit 2; }
    shift
    VGATE_RUN_TAGS+=("$tag")
    VGATE_RUN_FLAGS+=("$(printf '%q ' "$@")")
}
vgate_allow_rc() {
    # vgate_allow_rc TAG RC... -- allow specific runner exit code(s) for a tag (default: 0)
    local tag="$1"; shift
    VGATE_ALLOW_RC+=("${tag}"$'\x1f'"$*")
}
vgate_assert() {
    # vgate_assert TAG KIND [args...] -- kinds: serial-contains STR
    # serial-contains-file FILE | serial-count STR MIN | serial-exact STR N
    # serial-absent STR | serial-echo CMD | output-contains STR |
    # capture-equals FILE FIXTURE | capture-empty FILE | snapshot GLOB
    # (python body on stdin) | python (body on stdin, RUN_DIR/VG_SER/VG_TAG env)
    local tag="$1" kind="$2"; shift 2
    local body=""
    case "$kind" in snapshot|python) body="$(cat; echo x)"; body="${body%x}" ;; esac
    VGATE_ASSERTS+=("${tag}"$'\x1f'"${kind}"$'\x1f'"${1:-}"$'\x1f'"${2:-}"$'\x1f'"${body}")
}

# --- load the spec (unknown commands fail under set -e) ----------------------
# shellcheck disable=SC1090
source "$SPEC"
[ -n "$VGATE_NAME" ] || { echo "vgate: spec sets no vgate_name" >&2; exit 2; }
[ "${#VGATE_RUN_TAGS[@]}" -gt 0 ] || { echo "vgate: spec declares no vgate_run" >&2; exit 2; }

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }
GATE_LOG="$(art "$VGATE_NAME-gate.txt")"
REPORT="$(art "$VGATE_NAME-report.txt")"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "=== vgate $VGATE_NAME: $VGATE_DESC ==="
echo "spec: $SPEC"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- one shared build preamble (never per gate) ------------------------------
if [ "${VGATE_NO_BUILD:-0}" = "1" ]; then
    echo "vgate: skipping build preamble (VGATE_NO_BUILD=1)"
else
    # shellcheck disable=SC2086
    gate_fmt_check $VGATE_FMT
    zig build
    zig build image
    # shellcheck disable=SC2086
    gate_build_runner $VGATE_RUNNER_FLAGS
fi

gate_begin "$VGATE_NAME"
case "$VGATE_SHARE" in
    arm) gate_arm_share ;;
    seed) gate_seed_share ;;
esac
echo "run dir: $RUN_DIR"

# --- setup: files + setup-python hooks, in declaration order -----------------
for i in "${!VGATE_FILE_NAMES[@]}"; do
    printf '%s' "${VGATE_FILE_BODIES[$i]}" > "$RUN_DIR/${VGATE_FILE_NAMES[$i]}"
done
for i in "${!VGATE_SETUP_PY[@]}"; do
    printf '%s' "${VGATE_SETUP_PY[$i]}" > "$RUN_DIR/setup-$i.py"
    RUN_DIR="$RUN_DIR" python3 "$RUN_DIR/setup-$i.py"
done

: > "$REPORT"
{
    echo "VIRELAIOS vgate $VGATE_NAME -- $VGATE_DESC"
    echo "spec: $SPEC"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    for n in "${VGATE_NOTES[@]}"; do echo "note: $n"; done
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

# --- assert engine ------------------------------------------------------------
VG_SER="" VG_TAG="" VG_OUT="" VG_KEEP_FILES=()
vg_note_evidence() { VG_KEEP_FILES+=("$1"); }

vg_assert_one() {
    # $1=kind $2=a1 $3=a2 $4=body -> returns 0 on hold, prints one detail line
    local kind="$1" a1="$2" a2="$3" body="$4" ok=0 detail=""
    case "$kind" in
        serial-contains)
            grep -a -qF -- "$a1" "$VG_SER" 2>/dev/null && ok=1
            detail="serial-contains [$a1]=$ok" ;;
        serial-contains-file)
            if [ -f "$RUN_DIR/$a1" ]; then
                grep -a -qF -- "$(cat "$RUN_DIR/$a1")" "$VG_SER" 2>/dev/null && ok=1
            fi
            detail="serial-contains-file [$a1]=$ok" ;;
        serial-count)
            local n; n="$(grep -a -cF -- "$a1" "$VG_SER" 2>/dev/null || true)"
            [ -n "$n" ] || n=0
            [ "$n" -ge "$a2" ] && ok=1
            detail="serial-count [$a1]=$n (min $a2) ok=$ok" ;;
        serial-exact)
            # Whole-line match, mirroring grep -aFxc in the legacy scripts:
            # a command echo (prompt prefix) and its output are different
            # lines, so substring counting would double-count typed markers.
            local n; n="$(grep -a -cFx -- "$a1" "$VG_SER" 2>/dev/null || true)"
            [ -n "$n" ] || n=0
            [ "$n" = "$a2" ] && ok=1
            detail="serial-exact [$a1]=$n (want $a2) ok=$ok" ;;
        serial-absent)
            grep -a -qF -- "$a1" "$VG_SER" 2>/dev/null || ok=1
            detail="serial-absent [$a1] ok=$ok" ;;
        serial-echo)
            gate_serial_has_echo "$VG_SER" "$a1" && ok=1
            detail="serial-echo [$a1]=$ok" ;;
        output-contains)
            grep -a -qF -- "$a1" "$VG_OUT" 2>/dev/null && ok=1
            detail="output-contains [$a1]=$ok" ;;
        capture-equals)
            local cap="$RUN_DIR/$a1" fix="$RUN_DIR/$a2" tries=0
            vg_note_evidence "$a1"
            while [ "$tries" -lt 5 ]; do
                if [ -f "$cap" ] && [ -f "$fix" ] && cmp -s "$cap" "$fix"; then ok=1; break; fi
                tries=$((tries+1)); sleep 0.5
            done
            detail="capture-equals [$a1]==[$a2]=$ok" ;;
        capture-empty)
            vg_note_evidence "$a1"
            { [ ! -f "$RUN_DIR/$a1" ] || [ ! -s "$RUN_DIR/$a1" ]; } && ok=1
            detail="capture-empty [$a1]=$ok" ;;
        snapshot)
            local snap; snap="$(ls -t "$RUN_DIR"/$a1 2>/dev/null | head -1 || true)"
            if [ -n "$snap" ] && [ -f "$snap" ]; then
                vg_note_evidence "$(basename "$snap")"
                printf '%s' "$body" > "$RUN_DIR/snap-check.py"
                if python3 - "$snap" < "$RUN_DIR/snap-check.py" > "$RUN_DIR/snap-check.out" 2>&1; then
                    ok=1; detail="snapshot [$a1] PASS ($(basename "$snap"))"
                else
                    detail="snapshot [$a1] FAIL ($(basename "$snap"); see $VGATE_NAME run $VG_TAG)"
                    tail -5 "$RUN_DIR/snap-check.out" || true
                fi
                cat "$RUN_DIR/snap-check.out" || true
            else
                detail="snapshot [$a1] FAIL (no file)"
            fi ;;
        python)
            printf '%s' "$body" > "$RUN_DIR/check-$VG_TAG.py"
            if RUN_DIR="$RUN_DIR" VG_SER="$VG_SER" VG_TAG="$VG_TAG" VG_SHARE="$SHARE" \
                    python3 "$RUN_DIR/check-$VG_TAG.py" > "$RUN_DIR/check-$VG_TAG.out" 2>&1; then
                ok=1; detail="python [$VG_TAG] PASS"
            else
                detail="python [$VG_TAG] FAIL"; tail -5 "$RUN_DIR/check-$VG_TAG.out" || true
            fi
            cat "$RUN_DIR/check-$VG_TAG.out" || true ;;
        *) detail="UNKNOWN-ASSERT [$kind]"; ok=0 ;;
    esac
    echo "  $detail"
    echo "  $detail" >> "$REPORT"
    [ "$ok" = 1 ]
}

# --- run driver ---------------------------------------------------------------
REPEAT="$VGATE_REPEAT"
if [ -n "$VGATE_REPEAT_ENV" ] && [ -n "${!VGATE_REPEAT_ENV:-}" ] 2>/dev/null; then
    REPEAT="${!VGATE_REPEAT_ENV}"
fi

PASS=0 TOTAL=0 n=0
while [ "$n" -lt "$REPEAT" ]; do
    n=$((n + 1))
    for i in "${!VGATE_RUN_TAGS[@]}"; do
        base="${VGATE_RUN_TAGS[$i]}"
        if [ "$REPEAT" -gt 1 ]; then tag="${base}-$(printf '%02d' "$n")"; else tag="$base"; fi
        TOTAL=$((TOTAL + 1))
        echo; echo "=== $VGATE_NAME run $tag ==="
        rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
        set +e
        eval "set -- ${VGATE_RUN_FLAGS[$i]}"
        # Specs name $RUN_DIR files in flags; expand the literal token now
        # that RUN_DIR exists (file bodies and asserts stay literal).
        expanded=()
        for f in "$@"; do
            f="${f//\$RUN_DIR/$RUN_DIR}"
            f="${f//\$\{RUN_DIR\}/$RUN_DIR}"
            expanded+=("$f")
        done
        set -- "${expanded[@]}"
        host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
            --serial "$RUN_DIR/vm-serial-$tag.log" "$@" > "$RUN_DIR/run-$tag.out" 2>&1
        RC=$?
        set -e
        VG_TAG="$tag" VG_SER="$RUN_DIR/vm-serial-$tag.log" VG_OUT="$RUN_DIR/run-$tag.out"
        [ -f "$VG_SER" ] && cp "$VG_SER" "$(art "$VGATE_NAME-serial-$tag.log")" || true
        cp "$VG_OUT" "$(art "$VGATE_NAME-run-$tag.txt")"
        run_ok=1
        allowed_rc="0"
        for arc in "${VGATE_ALLOW_RC[@]}"; do
            [ "${arc%%$'\x1f'*}" = "$base" ] && allowed_rc="${arc#*$'\x1f'}"
        done
        rc_matched=0
        for code in $allowed_rc; do
            [ "$RC" = "$code" ] && { rc_matched=1; break; }
        done
        [ "$rc_matched" = 1 ] || { run_ok=0; echo "  runner-rc $RC not in allowed set ($allowed_rc)" | tee -a "$REPORT"; }
        echo "$tag: runner-rc=$RC" | tee -a "$REPORT"
        for a in "${VGATE_ASSERTS[@]}"; do
            atag="${a%%$'\x1f'*}"; rest="${a#*$'\x1f'}"
            [ "$atag" = "$base" ] || continue
            akind="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
            aa1="${rest%%$'\x1f'*}"; rest="${rest#*$'\x1f'}"
            aa2="${rest%%$'\x1f'*}"; abody="${rest#*$'\x1f'}"
            vg_assert_one "$akind" "$aa1" "$aa2" "$abody" || run_ok=0
        done
        echo "$tag: $([ "$run_ok" = 1 ] && echo PASS || echo FAIL)" | tee -a "$REPORT"
        [ "$run_ok" = 1 ] && PASS=$((PASS + 1))
    done
done

for f in "${VG_KEEP_FILES[@]}"; do
    [ -f "$RUN_DIR/$f" ] && cp "$RUN_DIR/$f" "$(art "$VGATE_NAME-$f")" || true
done

echo; echo "=== result ==="
if [ "$PASS" = "$TOTAL" ]; then
    echo "vgate $VGATE_NAME: PASS ($PASS/$TOTAL runs)"
    echo "PASS: $PASS/$TOTAL" >> "$REPORT"
    exit 0
fi
echo "vgate $VGATE_NAME: FAILED ($PASS/$TOTAL runs; see $REPORT)"
echo "FAIL: $PASS/$TOTAL" >> "$REPORT"
exit 1
