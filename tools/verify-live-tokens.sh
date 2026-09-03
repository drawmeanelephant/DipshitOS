#!/usr/bin/env bash
#
# verify-live-tokens.sh — M37 DQ4 design-token live proof (issue #838)
#
# Proves, in TWELVE headless VZ boots (6 apps × dark/light):
#   1. Each DQ4 app (NOTEPAD, CALC, EDIT, FILE, SYSMON, DEVCONS) follows
#      the desktop theme: it prints `<app>: tokens theme=<name>
#      bg=0x… surface=… border=… accent=…` with the exact token hex for the
#      boot's theme (via ui.sync_theme_from_host reading /host/SETTINGS.TXT,
#      which the boot script sets with `settings set theme <name>` before
#      the exec).
#   2. One kind-4 snapshot per boot shows unified chrome: bg/surface fills,
#      accent buttons, the EDIT gutter, and the compositor title bar in the
#      theme's token colors.
#   3. The DQ4 drop-shadow bands (`settings set shadow on`) in shadow-color
#      pixels right + below the window (each boot holds exactly one app
#      window, so the bands fall on the bare desktop).
#
# One app per boot because the compositor caps concurrent user windows at
# four (user_windows_max) and back-to-back snapshot requests coalesce on
# the INPUT queue (observed: a 6-exec burst streamed only the last
# snapshot). Per-boot share reset (gate_reset_share_state) keeps WINDOWS.SAV
# restore from drifting window ids across the twelve boots.
#
# Cursor-kind mapping is pinned by host tests (ui `dq4: cursor region
# mapping`); the `cursor=` serial markers fire on real pointer moves and
# are asserted only opportunistically here (headless boots send no
# pointer traffic).
#
# Class B -- Apple silicon + VZ, headless (custom-virtio, no view). CI=yes.
#
# Usage:  bash tools/verify-live-tokens.sh
# Evidence: artifacts/live-tokens-{run.txt,serial.log,snap},
#           artifacts/live-tokens-report.txt

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source "$ROOT/tools/lib/gate-run.sh"

art() { echo "$ROOT/artifacts/$1"; }

GATE_LOG="$(art live-tokens-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT
REPORT="$(art live-tokens-report.txt)"

echo "=== verify-live-tokens: M37 DQ4 design tokens + cohesion (issue #838) ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig user/src/lib/ui.zig user/src/notepad.zig user/src/calc.zig user/src/edit.zig user/src/file_browser.zig user/src/sysmon.zig user/src/devcons.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-tokens
gate_seed_share
echo "run dir: $RUN_DIR"

run_boot() {
    local tag="$1"; shift
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$RUN_DIR"/snap-$tag-*.raw
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        --snapshot-out "$RUN_DIR/snap-$tag" \
        "$@" \
        > "$(art live-tokens-run-$tag.txt)" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-tokens-serial-$tag.log)" || true
    local f
    f="$(ls "$RUN_DIR"/snap-$tag-*.raw 2>/dev/null | head -1 || true)"
    [ -n "$f" ] && cp "$f" "$(art live-tokens-snap-$tag.raw)" || true
    echo "$tag: runner rc=$RC snap=${f:-none}"
    return "$RC"
}

# --- twelve boots: one app × dark/light --------------------------------------
idx=0
RESULTS=""
for spec in NOTEPAD:notepad CALC:calc EDIT:edit FILE:file SYSMON:sysmon DEVCONS:devcons; do
    bin="${spec%%:*}"; low="${spec##*:}"
    for theme in dark light; do
        if [ "$theme" = dark ]; then tag="A$idx"; else tag="B$idx"; fi
        gate_reset_share_state
        {
            echo "settings set theme $theme"
            echo "settings set shadow on"
            echo "exec $bin.BIN"
        } > "$RUN_DIR/script-$tag.txt"
        set +e
        run_boot "$tag" \
            --script "$RUN_DIR/script-$tag.txt" \
            --snapshot-after "$low: settled" \
            --script-expect "$low: settled" --timeout 150
        RC=$?
        set -e
        RESULTS="$RESULTS $tag=$RC"
    done
    idx=$((idx + 1))
done

# --- serial assertions: exact token hex per app per theme --------------------
S_OK=0; S_TOTAL=0
check_markers() {
    local tag="$1" app="$2" theme="$3" bg="$4" surface="$5" border="$6" accent="$7"
    local ser="$(art live-tokens-serial-$tag.log)"
    S_TOTAL=$((S_TOTAL + 1))
    if [ -f "$ser" ] && grep -a -qF -- "$app: tokens theme=$theme bg=$bg surface=$surface border=$border accent=$accent" "$ser"; then
        S_OK=$((S_OK + 1))
    else
        echo "$tag: MISSING tokens marker for $app ($theme)"
        grep -a -- "$app: tokens" "$ser" | head -2 || true
    fi
}

D_BG="0x182026"; D_SURFACE="0x222d35"; D_BORDER="0x334155"; D_ACCENT="0x3b82f6"
L_BG="0xf1f5f9"; L_SURFACE="0xffffff"; L_BORDER="0xcbd5e1"; L_ACCENT="0x2563eb"
check_markers A0 notepad dark "$D_BG" "$D_SURFACE" "$D_BORDER" "$D_ACCENT"
check_markers A1 calc dark "$D_BG" "$D_SURFACE" "$D_BORDER" "$D_ACCENT"
check_markers A2 edit dark "$D_BG" "$D_SURFACE" "$D_BORDER" "$D_ACCENT"
check_markers A3 file dark "$D_BG" "$D_SURFACE" "$D_BORDER" "$D_ACCENT"
check_markers A4 sysmon dark "$D_BG" "$D_SURFACE" "$D_BORDER" "$D_ACCENT"
check_markers A5 devcons dark "$D_BG" "$D_SURFACE" "$D_BORDER" "$D_ACCENT"
check_markers B0 notepad light "$L_BG" "$L_SURFACE" "$L_BORDER" "$L_ACCENT"
check_markers B1 calc light "$L_BG" "$L_SURFACE" "$L_BORDER" "$L_ACCENT"
check_markers B2 edit light "$L_BG" "$L_SURFACE" "$L_BORDER" "$L_ACCENT"
check_markers B3 file light "$L_BG" "$L_SURFACE" "$L_BORDER" "$L_ACCENT"
check_markers B4 sysmon light "$L_BG" "$L_SURFACE" "$L_BORDER" "$L_ACCENT"
check_markers B5 devcons light "$L_BG" "$L_SURFACE" "$L_BORDER" "$L_ACCENT"
echo "tokens markers $S_OK/$S_TOTAL"

# --- pixel assertions: one snapshot per boot ----------------------------------
pix_ok() {
    local tag="$1" app="$2" theme="$3"
    python3 - "$tag" "$app" "$theme" <<'PYEOF'
import sys
tag, app, theme = sys.argv[1], sys.argv[2], sys.argv[3]
T = {
 'dark':  dict(bg=(0x18,0x20,0x26), surface=(0x22,0x2d,0x35), accent=(0x3b,0x82,0xf6),
               pressed=(0x1a,0x20,0x2c), muted=(0x94,0xa3,0xb8), title=(0x1a,0x2b,0x3c),
               shadow=(0x00,0x00,0x00), edit_surface=(0x1a,0x20,0x26), gutter=(0x0b,0x0e,0x11),
               idle=(0x2d,0x37,0x48)),
 'light': dict(bg=(0xf1,0xf5,0xf9), surface=(0xff,0xff,0xff), accent=(0x25,0x63,0xeb),
               pressed=(0x94,0xa3,0xb8), muted=(0x64,0x74,0x8b), title=(0xe2,0xe8,0xf0),
               shadow=(0x94,0xa3,0xb8), edit_surface=(0xff,0xff,0xff), gutter=(0xe5,0xe7,0xeb),
               idle=(0xe2,0xe8,0xf0)),
}[theme]
path = f"artifacts/live-tokens-snap-{tag}.raw"
W, H = 1280, 720
try:
    data = open(path, "rb").read()
except FileNotFoundError:
    print(f"{tag}/{app}: NO SNAPSHOT"); sys.exit(1)
assert len(data) == W * H * 4, f"{tag} size {len(data)}"
ok = True
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    global ok
    got = px(x, y)
    good = got == want
    ok &= good
    print(f"  {label}: {'ok' if good else f'GOT {got} WANT {want}'}")
def majority(cx, cy, want, label, r=2):
    global ok
    n = sum(1 for dx in range(-r, r + 1) for dy in range(-r, r + 1)
            if px(cx + dx, cy + dy) == want)
    good = n >= 9
    ok &= good
    print(f"  {label}: {'ok' if good else f'only {n}/25'}")
# Per-app window geometry + chrome probes (all interior, clear of the
# compositor's 16px title bar and 2px border; title sampled at the left
# end, clear of the centered label and the right-side buttons; shadow
# bands are [x+w, x+w+4) × [y+4, y+h) and [x+4, x+w-4) × [y+h, y+h+4)).
if app == "notepad":  # (56,56,512x384)
    check(76, 60, T['title'], "title")
    check(450, 78, T['bg'], "bg")
    check(100, 120, T['surface'], "text surface")
    check(570, 200, T['shadow'], "shadow right")
    check(300, 442, T['shadow'], "shadow bottom")
elif app == "calc":  # (48,48,512x424)
    check(68, 52, T['title'], "title")
    check(100, 70, T['surface'], "history surface")
    check(60, 130, T['surface'], "display surface")
    majority(255, 286, T['accent'], "= accent", r=1)
    check(562, 200, T['shadow'], "shadow right")
elif app == "edit":  # (64,48,512x384)
    check(84, 52, T['title'], "title")
    check(80, 100, T['gutter'], "gutter")
    check(200, 150, T['edit_surface'], "surface")
    check(578, 200, T['shadow'], "shadow right")
elif app == "file":  # (40,40,512x384)
    check(60, 44, T['title'], "title")
    check(50, 78, T['idle'], "header")
    check(60, 87, T['accent'], "row0 selected")
    majority(52, 366, T['accent'], "open accent", r=1)
    check(554, 200, T['shadow'], "shadow right")
elif app == "sysmon":  # (60,60,512x380)
    check(80, 64, T['title'], "title")
    check(430, 80, T['surface'], "header surface")
    check(117, 90, T['pressed'], "active tab")
    check(500, 200, T['surface'], "content surface")
    check(300, 435, T['bg'], "bg margin")
    check(574, 200, T['shadow'], "shadow right")
elif app == "devcons":  # (260,24,400x300)
    check(280, 28, T['title'], "title")
    check(300, 100, T['surface'], "log surface")
    check(400, 272, T['muted'], "separator")
    check(500, 300, T['bg'], "prompt bg")
    check(662, 150, T['shadow'], "shadow right")
print("PIX_OK" if ok else "PIX_MISSING")
sys.exit(0 if ok else 1)
PYEOF
}

P_OK=0; P_TOTAL=0
for spec in "A0:notepad:dark" "A1:calc:dark" "A2:edit:dark" "A3:file:dark" "A4:sysmon:dark" "A5:devcons:dark" "B0:notepad:light" "B1:calc:light" "B2:edit:light" "B3:file:light" "B4:sysmon:light" "B5:devcons:light"; do
    tag="${spec%%:*}"; rest="${spec#*:}"; app="${rest%%:*}"; theme="${rest##*:}"
    P_TOTAL=$((P_TOTAL + 1))
    if pix_ok "$tag" "$app" "$theme"; then P_OK=$((P_OK + 1)); fi
done
echo "pixel probes $P_OK/$P_TOTAL"

# --- report ------------------------------------------------------------------
{
    echo "--- M37 DQ4 tokens report ---"
    echo "  boots:$RESULTS"
    echo "  markers=$S_OK/$S_TOTAL pixels=$P_OK/$P_TOTAL"
    if [ "$S_OK" = "$S_TOTAL" ] && [ "$P_OK" = "$P_TOTAL" ]; then
        echo "  RESULT: PASS"
    else
        echo "  RESULT: FAIL"
    fi
    echo "---"
} | tee "$REPORT"

if [ "$S_OK" = "$S_TOTAL" ] && [ "$P_OK" = "$P_TOTAL" ]; then
    echo "verify-live-tokens: PASS — 6 apps follow desktop tokens on dark+light, chrome pixels + shadow bands live on VZ"
    exit 0
else
    echo "verify-live-tokens: FAIL"
    exit 1
fi
