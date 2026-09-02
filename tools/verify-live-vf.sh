#!/usr/bin/env bash
#
# verify-live-vf.sh -- M34 HF1+HF2+HF3+HF4+HF7 (issues #735-#738/#741)
# class-B gate: the HOST FILE CHANNEL over custom-virtio queue 5 on VZ.
#
#   Phase 1 (HF1): the guest's VF_PROBE spike proves the ONE unproven
#   transport fact — a full 32,768-byte device-WRITE reply. Serial shows
#   `vf: probe 32k ok len=0x8000 cksum=0x0000 free=32` (the XOR-symmetric
#   pattern genuinely folds to 0x0000; the guest Zig, Swift, and python
#   all agree); the runner prints `VF-PROBE: wrote 32768/32768 bytes`.
#
#   Phase 2 (HF2): the guest lists the share and streams a >32 KiB fixture
#   byte-exactly across >= 2 READ round trips — `vf cat` prints the STAT
#   byte count FIRST, then `vf: cat ok bytes=N rts>=2 cksum=0x<…>` where
#   the checksum (RFC-1071 over the stream) must equal the gate's python
#   computation over the same fixture. LIST + STAT + READ all exercised; a
#   subdirectory proves /-paths.
#
#   Phase 3 (HF3 — issue #737): MUTATION, one phase per boot:
#     boot 1 "mutate":  vf mkdir hf3 → open hf3/new.bin (create) → write
#       100,000 probe-pattern bytes in 4 chunk round trips → fsync →
#       close → rename hf3/new.bin → hf3/renamed.bin → open APPEND →
#       write 4 bytes → fsync → close. The gate then byte-compares
#       renamed.bin ON THE HOST DISK against the same pattern stream the
#       guest wrote (write + rename + append round-trips verified).
#     boot 2 "read-back": `vf cat hf3/renamed.bin` — proves the FSYNC'd
#       write survives a REBOOT (size + checksum needles, >= 2 READ round
#       trips); python re-verifies the host disk bytes.
#     boot 3 "delete": `vf rm hf3/renamed.bin` + a mkdir-exists honest
#       error; python verifies the file is GONE and the hf3 dir survived.
#
#   Phase 4 (HF4 — issue #738): APP DELIVERY, one boot: the gate compiles
#   a tiny freestanding aarch64 `.ELF` on the HOST (after the image is
#   baked — never in the ESP) and drops it + a 2-entry `APPS.TXT` into the
#   share. The boot then proves the drop-and-exec workflow with NO image
#   rebuild: `vf ls` lists HF4APP.ELF, `exec HF4APP.ELF` streams it across
#   >= 2 READ round trips and runs it (the `hf4: hello from host` marker
#   lands in serial; sys_exit closes with status 43), and `exec
#   DESKTOP.BIN` prints `desktop: manifest apps=2` — the HOST manifest
#   count (the ESP one has 19) — proving the desktop's manifest re-point
#   to `/host/APPS.TXT`.
#
#   Phase 5 (HF5 — issue #739) was the ONE-TIME user-data migration; M34
#   HF6 (issue #740) DELETED it (migrate.zig is gone — the share is the
#   only store, nothing left to migrate).
#
#   Phase 6 + 7 (HF7 — issue #741): CLONE → clonefile COW dedup — the
#   worktree workload, with a HOST-SIDE space measurement. The gate seeds
#   a ~7.5 MiB `repo` fixture; phase "clone" FIRST runs a COPY CONTROL
#   (3 `cp -R` worktrees measured at the VOLUME level, then deleted) and
#   then boots the guest to create 3 worktrees via `vf clone repo wtN`.
#   The volume used-space delta of the 3 clones is measured after the
#   boot and must land far below the 3 copies (du CANNOT see COW sharing
#   — it reports logical st_blocks — so the honest number is the statvfs
#   volume delta). Phase "edit" boots again to append 512 pattern bytes
#   to wt1/README; the host then byte-compares wt2/wt3 against the repo
#   (untouched siblings must be bit-identical) and wt1/README against the
#   exact expected bytes. All raw before/after numbers land in
#   artifacts/m34-hf7-measurement.txt — savings shown, never asserted
#   blindly.
#
# Every boot repeats phases 1+2, so a 6-boot run covers everything.
#
# Run isolation per claim 5069 (tools/lib/gate-run.sh): the share dir
# lives inside the private RUN_DIR, so parallel gate instances cannot
# collide on fixtures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art m34-hf1-hf2-hf3-hf4-live.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-6}"
REPORT="$(art live-vf-report.txt)"
STATIC_EXIT_LINE="tasks user-el0 exited status=7"
PROBE_OK_LINE="vf: probe 32k ok len=0x8000 cksum=0x0000 free=0020"
HF4_APP="HF4APP.ELF"
HF4_MARKER="hf4: hello from host"
HF4_EXIT="tasks user-exec exited status=43"
HF4_MANIFEST_LINE="desktop: manifest apps=2"
HF7_CLONE_RAN=0
HF7_EDIT_RAN=0

echo "=== verify-live-vf: M34 HF1+HF2+HF3+HF4+HF7 (issues #735/#736/#737/#738/#741) — host file channel on VZ, $BOOTS boot(s); HF6 deleted the HF5 migration phase ==="
zig version
swift --version 2>&1 | head -1
sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
# The custom-virtio device is a SPIKE build type (macOS 27 SDK types) —
# same as the chrome/snapshot gates.
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

gate_begin live-vf
echo "run dir: $RUN_DIR"

# --- the host share: deterministic fixtures + the FULL HF3 expectation ---
SHARE="$RUN_DIR/share"
mkdir -p "$SHARE/sub"
python3 - "$SHARE" <<'EOF'
import sys
share = sys.argv[1]
def cksum(data):
    s = 0
    i = 0
    while i + 1 < len(data):
        s += (data[i] << 8) | data[i + 1]
        i += 2
    if i < len(data):
        s += data[i] << 8
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff
def pattern(i):
    return (i & 0xff) ^ ((i >> 8) & 0xff)
# big.bin: 100,000 deterministic bytes (spans >= 4 READ round trips of
# 32,765 data bytes each). hello.txt: small, read via /-path.
data = bytes((i * 37 + 11) & 0xff for i in range(100000))
open(share + "/big.bin", "wb").write(data)
hello = b"hello vf!\n"
open(share + "/sub/hello.txt", "wb").write(hello)
# HF3 expectation: the guest writes pattern(0..100000) then appends
# pattern(0..4) through an append handle — the host disk must match these
# exact bytes after RENAME, and they must survive a reboot (FSYNC).
expect = bytes(pattern(i) for i in range(100000)) + bytes(pattern(i) for i in range(4))
open(share + "/hf3-expect.bin", "wb").write(expect)
print("BIG_SIZE=%d" % len(data))
print("BIG_CKSUM=0x%04x" % cksum(data))
print("HELLO_CKSUM=0x%04x" % cksum(hello))
print("HF3_SIZE=%d" % len(expect))
print("HF3_CKSUM=0x%04x" % cksum(expect))
EOF

# --- HF7 (issue #741): the CLONE worktree fixture. A small but measurable
# repo: 6 × 1 MiB + lib/2 × 512 KiB + README ≈ 7.5 MiB — big enough that
# the volume-level deltas (3 copies ≈ 22.5 MiB vs 3 clones ≈ ~0) dwarf
# background noise. The README expectation is what the EDIT phase appends:
# the fixture text + the deterministic probe pattern's first 512 bytes.
python3 - "$SHARE" <<'EOF2'
import os, random, sys
share = sys.argv[1]
def cksum(data):
    s = 0
    i = 0
    while i + 1 < len(data):
        s += (data[i] << 8) | data[i + 1]
        i += 2
    if i < len(data):
        s += data[i] << 8
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff
def pattern(i):
    return (i & 0xff) ^ ((i >> 8) & 0xff)
rng = random.Random(20260902)
base = share + "/repo"
os.makedirs(base + "/lib", exist_ok=True)
for i in range(6):
    open(base + "/big%d.bin" % i, "wb").write(rng.randbytes(1024 * 1024))
for i in range(2):
    open(base + "/lib/small%d.bin" % i, "wb").write(rng.randbytes(512 * 1024))
readme = b"HF7 fixture repo\n"
open(base + "/README", "wb").write(readme)
expect = readme + bytes(pattern(i) for i in range(512))
print("HF7_REPO_BYTES=%d" % (6 * 1024 * 1024 + 2 * 512 * 1024 + len(readme)))
print("HF7_README_SIZE=%d" % len(expect))
print("HF7_README_CKSUM=0x%04x" % cksum(expect))
EOF2
README_SIZE="$(grep '^HF7_README_SIZE=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
README_CKSUM="$(grep '^HF7_README_CKSUM=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
echo "share: HF7 repo seeded (HF7_REPO_BYTES above); edit expectation README size=$README_SIZE cksum=$README_CKSUM"

BIG_SIZE="$(grep '^BIG_SIZE=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
BIG_CKSUM="$(grep '^BIG_CKSUM=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
HELLO_CKSUM="$(grep '^HELLO_CKSUM=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
HF3_SIZE="$(grep '^HF3_SIZE=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
HF3_CKSUM="$(grep '^HF3_CKSUM=' "$GATE_LOG" | tail -1 | cut -d= -f2)"
echo "share: big.bin size=$BIG_SIZE cksum=$BIG_CKSUM ; sub/hello.txt cksum=$HELLO_CKSUM ; hf3 expect size=$HF3_SIZE cksum=$HF3_CKSUM"

# --- HF4 (issue #738): build the app ON THE HOST and drop it into the
# share. The image was baked above (zig build image) and is NOT rebuilt —
# this is the card's whole point: a host-compiled `.ELF` + a 2-entry
# `APPS.TXT` dropped into the share run with no image rebuild. The app is
# a freestanding aarch64 ELF (one PT_LOAD at userspace.text_va, built with
# the repo's own user linker script) that sys_writes a marker and exits
# with status 43.
cat > "$RUN_DIR/hf4app.zig" <<'EOF'
export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\mov x0, #1
        \\adr x1, 1f
        \\mov x2, #20
        \\mov x8, #1
        \\svc #0
        \\mov x0, #43
        \\mov x8, #3
        \\svc #0
        \\1:
        \\.ascii "hf4: hello from host"
        \\.byte 10
    );
}
EOF
zig build-exe -target aarch64-freestanding -O ReleaseSmall -T user/linker.ld \
    "$RUN_DIR/hf4app.zig" -femit-bin="$SHARE/$HF4_APP" 2>&1 | tail -2
APP_SIZE="$(wc -c < "$SHARE/$HF4_APP" | tr -d ' ')"
echo "HF4: built $HF4_APP on the host after image bake — $APP_SIZE bytes, dropped into the share (no image rebuild)"
printf '%s | Host Hello | h\nCALC.BIN | 64-bit Calc | c\n' "$HF4_APP" > "$SHARE/APPS.TXT"
echo "HF4: host APPS.TXT ($(wc -l < "$SHARE/APPS.TXT" | tr -d ' ') entries) — desktop must report apps=2, not the ESP's 19"
# M34 HF6 (issue #740): DESKTOP.BIN is NOT baked into the image anymore —
# it execs from the share like every app. Drop the built binary in (the
# 2-entry APPS.TXT above stays the manifest it must read).
cp zig-out/bin/DESKTOP.BIN "$SHARE/"
echo "HF4: DESKTOP.BIN dropped into the share (HF6: apps live on the share, not the ESP)"

# Host-disk verification (HF3): the mutation round-trip MUST land the exact
# guest pattern stream on the host's own filesystem.
verify_hf3_disk() {
    local phase="$1"
    python3 - "$SHARE" "$phase" <<'EOF'
import os, sys
share, phase = sys.argv[1], sys.argv[2]
def pattern(i):
    return (i & 0xff) ^ ((i >> 8) & 0xff)
expect = bytes(pattern(i) for i in range(100000)) + bytes(pattern(i) for i in range(4))
rp = os.path.join(share, "hf3", "renamed.bin")
nb = os.path.join(share, "hf3", "new.bin")
hd = os.path.join(share, "hf3")
ok = True
if phase in ("mutate", "readback"):
    if not os.path.exists(rp):
        print("HF3-DISK: FAIL — renamed.bin missing after %s" % phase); ok = False
    else:
        got = open(rp, "rb").read()
        if got != expect:
            print("HF3-DISK: FAIL — renamed.bin %d bytes != expected %d after %s" % (len(got), len(expect), phase)); ok = False
        else:
            print("HF3-DISK: renamed.bin %d bytes MATCH the guest pattern stream (%s)" % (len(got), phase))
    if os.path.exists(nb):
        print("HF3-DISK: FAIL — new.bin still present after RENAME"); ok = False
elif phase in ("delete", "app"):
    # The HF4 "app" boot makes no HF3 mutations — it only asserts the
    # delete phase's host-disk state persisted.
    if os.path.exists(rp):
        print("HF3-DISK: FAIL — renamed.bin still present after %s" % phase); ok = False
    else:
        print("HF3-DISK: renamed.bin gone after %s" % phase)
    if not os.path.isdir(hd):
        print("HF3-DISK: FAIL — hf3 dir missing after %s" % phase); ok = False
    else:
        print("HF3-DISK: hf3 dir survived %s" % phase)
sys.exit(0 if ok else 1)
EOF
}

# --- per-phase guest scripts ---
SCRIPT_H12="$RUN_DIR/script-h12.txt"
printf 'vf ls\nvf cat big.bin\nvf ls sub\nvf cat sub/hello.txt\n' > "$SCRIPT_H12"

SCRIPT_MUTATE="$RUN_DIR/script-mutate.txt"
cat > "$SCRIPT_MUTATE" <<'EOF'
vf mkdir hf3
vf open hf3/new.bin
vf write 0 100000
vf fsync 0
vf mv hf3/new.bin hf3/renamed.bin
vf open hf3/renamed.bin append
vf write 1 4
vf fsync 1
vf close 1
vf close 0
echo rx-vf3-mutate
EOF

SCRIPT_READBACK="$RUN_DIR/script-readback.txt"
printf 'vf cat hf3/renamed.bin\necho rx-vf3-readback\n' > "$SCRIPT_READBACK"

SCRIPT_DELETE="$RUN_DIR/script-delete.txt"
printf 'vf rm hf3/renamed.bin\nvf mkdir hf3\necho rx-vf3-delete\n' > "$SCRIPT_DELETE"

# HF4 (issue #738): drop-and-exec — vf ls proves the file is visible, then
# the kernel execs it from the SHARE (2+ READ round trips for the 65 KB
# ELF) and DESKTOP.BIN re-reads its manifest from /host/APPS.TXT.
SCRIPT_APP="$RUN_DIR/script-app.txt"
cat > "$SCRIPT_APP" <<EOF
vf ls
exec $HF4_APP
exec DESKTOP.BIN
echo rx-hf4-app
EOF

# HF7 (issue #741): the guest creates THREE worktrees of the repo via
# CLONE, then lists the share root (wt1/wt2/wt3 must appear).
SCRIPT_CLONE="$RUN_DIR/script-clone.txt"
cat > "$SCRIPT_CLONE" <<'EOF'
vf clone repo wt1
vf clone repo wt2
vf clone repo wt3
vf ls
echo rx-vf7-clone
EOF

# HF7 edit phase: append 512 probe-pattern bytes to wt1/README through an
# append handle (COW: only wt1's README blocks get new storage; wt2/wt3
# stay bit-identical to repo — byte-compared on the host), then `vf cat`
# it back so the serial carries the size + checksum needles.
SCRIPT_EDIT="$RUN_DIR/script-edit.txt"
cat > "$SCRIPT_EDIT" <<'EOF'
vf open wt1/README append
vf write 0 512
vf fsync 0
vf close 0
vf cat wt1/README
echo rx-vf7-edit
EOF

PHASES=(mutate readback delete app clone edit)
phase_of() { local t=$((10#$1)); echo "${PHASES[$(( (t - 1) % ${#PHASES[@]} ))]}"; }
cat_script_of() {
    local p="$1"
    # The combined file MUST NOT alias any SCRIPT_* source (a self-append
    # like `cat f >> f` grows/hangs forever — observed live: boot 1 stuck
    # on `cat script-mutate.txt >> script-mutate.txt`).
    local out="$RUN_DIR/script-$p-combined.txt"
    cat "$SCRIPT_H12" > "$out"
    case "$p" in
        mutate)   cat "$SCRIPT_MUTATE" >> "$out" ;;
        readback) cat "$SCRIPT_READBACK" >> "$out" ;;
        delete)   cat "$SCRIPT_DELETE" >> "$out" ;;
        app)      cat "$SCRIPT_APP" >> "$out" ;;
        clone)    cat "$SCRIPT_CLONE" >> "$out" ;;
        edit)     cat "$SCRIPT_EDIT" >> "$out" ;;
    esac
    echo "$out"
}

# ---------------------------------------------------------------------------
# HF7 (issue #741): HOST-SIDE space measurement + worktree isolation proof.
# Physical used-space is measured at the VOLUME level (statvfs before/
# after each window): du reports logical st_blocks and CANNOT see clone
# COW sharing (measured: identical for clones and copies). The 3-cp COPY
# CONTROL brackets a ~22.5 MiB delta; the 3 CLONES bracket ~0; an edit of
# one file brackets ~0 + the edited bytes. All raw numbers are appended to
# $MEASURE and published as artifacts/m34-hf7-measurement.txt — savings
# shown, never asserted blindly.
# ---------------------------------------------------------------------------
MEASURE="$RUN_DIR/m34-hf7-measurement.txt"

hf7_vol_used() {
    python3 - "$SHARE" <<'EOF'
import os, sys
s = os.statvfs(sys.argv[1])
print((s.f_blocks - s.f_bfree) * s.f_frsize)
EOF
}

hf7_copy_control() {
    echo "--- HF7 copy control (3 real cp -R worktrees, measured + deleted) ---"
    local v0 v1 v2
    v0="$(hf7_vol_used)"
    cp -R "$SHARE/repo" "$SHARE/repo-cp1"
    cp -R "$SHARE/repo" "$SHARE/repo-cp2"
    cp -R "$SHARE/repo" "$SHARE/repo-cp3"
    v1="$(hf7_vol_used)"
    rm -rf "$SHARE/repo-cp1" "$SHARE/repo-cp2" "$SHARE/repo-cp3"
    v2="$(hf7_vol_used)"
    echo "HF7-COPY: before=$v0 after=$v1 clean=$v2 copy_delta=$((v1 - v0)) clean_delta=$((v2 - v0)) (bytes)"
    {
        echo "HF7_COPY_3_DELTA=$((v1 - v0))"
        echo "HF7_COPY_CLEAN_DELTA=$((v2 - v0))"
        echo "HF7_DU_REPO_KB=$(du -sk "$SHARE/repo" | cut -f1)"
    } >> "$MEASURE"
}

hf7_finish_clone() {
    local pre="$1" tag="$2"
    local post clone_delta
    post="$(hf7_vol_used)"
    clone_delta=$((post - pre))
    {
        echo "HF7_CLONES_WINDOW=$tag"
        echo "HF7_CLONES_3_DELTA=$clone_delta"
        echo "HF7_DU_WT1_KB=$(du -sk "$SHARE/wt1" 2>/dev/null | cut -f1 || echo 0)"
        echo "HF7_DU_WT2_KB=$(du -sk "$SHARE/wt2" 2>/dev/null | cut -f1 || echo 0)"
        echo "HF7_DU_WT3_KB=$(du -sk "$SHARE/wt3" 2>/dev/null | cut -f1 || echo 0)"
    } >> "$MEASURE"
    echo "HF7-CLONE: pre=$pre post=$post clones3_delta=$clone_delta (du of each worktree = repo's logical KB — du cannot see COW sharing; the volume delta is the physical truth)"
    HF7_CLONE_RAN=1
}

hf7_finish_edit() {
    local pre="$1" tag="$2"
    local post edit_delta
    post="$(hf7_vol_used)"
    edit_delta=$((post - pre))
    {
        echo "HF7_EDIT_WINDOW=$tag"
        echo "HF7_EDIT_512B_DELTA=$edit_delta"
    } >> "$MEASURE"
    echo "HF7-EDIT: pre=$pre post=$post 512B-edit_delta=$edit_delta"
    HF7_EDIT_RAN=1
    # The hard proof: untouched sibling worktrees stay byte-identical to
    # the repo; wt1 differs ONLY in README (fixture text + the 512-byte
    # guest pattern append).
    if python3 - "$SHARE" "$README_SIZE" "$README_CKSUM" <<'EOF'
import hashlib, os, sys
share, want_size, want_cksum = sys.argv[1], int(sys.argv[2]), int(sys.argv[3], 16)
def walk(d):
    out = {}
    for root, _, files in os.walk(d):
        for fn in sorted(files):
            p = os.path.join(root, fn)
            out[os.path.relpath(p, d)] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    return out
def cksum(data):
    s = 0
    i = 0
    while i + 1 < len(data):
        s += (data[i] << 8) | data[i + 1]
        i += 2
    if i < len(data):
        s += data[i] << 8
    while s >> 16:
        s = (s & 0xffff) + (s >> 16)
    return (~s) & 0xffff
def pattern(i):
    return (i & 0xff) ^ ((i >> 8) & 0xff)
ref = walk(os.path.join(share, "repo"))
ok = True
def chk(wt, exact):
    global ok
    got = walk(os.path.join(share, wt))
    if set(got) != set(ref):
        print("HF7-TREE: FAIL — %s file set differs from repo" % wt); ok = False; return
    diff = [k for k in ref if got[k] != ref[k]]
    if exact:
        if diff:
            print("HF7-TREE: FAIL — %s differs from repo in %s" % (wt, diff)); ok = False
        else:
            print("HF7-TREE: %s byte-identical to repo (untouched sibling — no duplication)" % wt)
    else:
        if diff != ["README"]:
            print("HF7-TREE: FAIL — wt1 must differ ONLY in README, got %s" % diff); ok = False
        else:
            print("HF7-TREE: wt1 differs only in README (the edited file)")
chk("wt2", True)
chk("wt3", True)
chk("wt1", False)
rw = open(os.path.join(share, "wt1", "README"), "rb").read()
if len(rw) != want_size or cksum(rw) != want_cksum:
    print("HF7-TREE: FAIL — wt1/README %d bytes cksum=0x%04x (want %d/0x%04x)" % (len(rw), cksum(rw), want_size, want_cksum)); ok = False
else:
    print("HF7-TREE: wt1/README %d bytes cksum=0x%04x MATCH the guest's 512-byte pattern append" % (len(rw), cksum(rw)))
sys.exit(0 if ok else 1)
EOF
    then
        echo "HF7-TREE: PASS — edit duplicated nothing; untouched siblings intact"
        touch "$RUN_DIR/hf7-ok"
    else
        echo "HF7-TREE: FAILED — see the tree lines above"
    fi
}

run_one() {
    local tag="$1"
    local phase; phase="$(phase_of "$tag")"
    local script; script="$(cat_script_of "$phase")"
    local run_log="$(art live-vf-run-$tag.txt)"
    local serial_copy="$(art live-vf-serial-$tag.log)"
    # The HF4 app phase execs two programs (app marker + exit report then
    # DESKTOP.BIN) after the H12 stream, so it needs a longer boot window
    # than the HF1–HF3 phases — observed live: the 90 s default cut the
    # app's final marker mid-write at the deadline.
    local timeout=90
    [ "$phase" = app ] && timeout=150
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"

    # HF7 (issue #741): bracket this boot with volume-level measurements.
    # The copy control runs BEFORE the clone boot so the guest window
    # stays clean, and the measurement files are seeded at the start.
    HF7_PRE_VOL=""
    if [ "$phase" = clone ]; then
        : > "$MEASURE"
        {
            echo "M34 HF7 (issue #741) — CLONE COW dedup measurement, volume-level used-space deltas in BYTES (statvfs); du reports logical size and cannot see clone sharing"
            echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
            echo "fixture repo bytes: HF7_REPO_BYTES (see gate log)"
        } >> "$MEASURE"
        hf7_copy_control
        HF7_PRE_VOL="$(hf7_vol_used)"
    elif [ "$phase" = edit ]; then
        HF7_PRE_VOL="$(hf7_vol_used)"
    fi

    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --cvc-file "$SHARE" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --script "$script" --script-after "$STATIC_EXIT_LINE" \
        --timeout "$timeout" > "$run_log" 2>&1
    local rc=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$serial_copy" || true
    local SER="$serial_copy"

    # HF7 (issue #741): close the measurement window + run the worktree
    # proof for this phase (stderr-less helpers write into the tee'd log).
    if [ "$phase" = clone ]; then
        hf7_finish_clone "$HF7_PRE_VOL" "$tag"
    elif [ "$phase" = edit ]; then
        hf7_finish_edit "$HF7_PRE_VOL" "$tag"
    fi

    local bytes=0 banner=0 probe=0 listed=0 statline=0 catok=0 catcksum=0 sub=0 hello=0 runner_write=0 fatal=0
    if [ -f "$SER" ]; then
        bytes="$(wc -c < "$SER" | tr -d ' ')"
        [ "$(grep -aFxc -- "VirelaiOS kernel has seized control." "$SER" || true)" = 1 ] && banner=1
        [ "$(grep -aFxc -- "$PROBE_OK_LINE" "$SER" || true)" = 1 ] && probe=1
        [ "$(grep -aFc -- "big.bin" "$SER" || true)" -ge 2 ] && listed=1
        [ "$(grep -aFxc -- "vf: cat big.bin size=$BIG_SIZE" "$SER" || true)" = 1 ] && statline=1
        [ "$(grep -aFc -- "vf: cat ok bytes=$BIG_SIZE rts=" "$SER" || true)" -ge 1 ] && catok=1
        [ "$(grep -aFc -- "cksum=$BIG_CKSUM" "$SER" || true)" -ge 1 ] && catcksum=1
        [ "$(grep -aFc -- "sub/" "$SER" || true)" -ge 1 ] && sub=1
        [ "$(grep -aFc -- "vf: cat ok bytes=10 rts=1 cksum=$HELLO_CKSUM" "$SER" || true)" -ge 1 ] && hello=1
        grep -qF -- "vf: probe 32k FAILED" "$SER" && fatal=1 || true
    fi
    [ "$(grep -aFc -- "VF-PROBE: wrote 32768/32768 bytes (write buffers 32768)" "$run_log" || true)" -ge 1 ] && runner_write=1
    grep -qF -- "VF-PROBE: FAILED" "$run_log" && fatal=1 || true
    # At least 2 READ round trips for the >32 KiB fixture (32765 B max/round trip).
    local rts=0
    if [ -f "$SER" ]; then
        rts="$(grep -aF -- "vf: cat ok bytes=$BIG_SIZE rts=" "$SER" | head -1 | sed -E 's/.*rts=([0-9]+).*/\1/')"
        [ -n "$rts" ] && [ "$rts" -ge 2 ] || rts=0
    fi

    # --- HF3/HF4 phase needles + host-disk verification ---
    local phase_needs=1 hf3_disk=0
    case "$phase" in
        mutate)
            [ "$(grep -aFxc -- "vf: open hf3/new.bin h=0" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: write 0 n=100000 wrote=100000 chunks=4" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: fsync 0 ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: mv hf3/new.bin -> hf3/renamed.bin ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: open hf3/renamed.bin append h=1" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: write 1 n=4 wrote=4 chunks=1" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: fsync 1 ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: close 1 ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: close 0 ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "rx-vf3-mutate" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFc -- "VF-FILE: RENAME hf3/new.bin" "$run_log" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFc -- "VF-FILE: OPEN hf3/" "$run_log" || true)" -ge 2 ] || phase_needs=0
            [ "$(grep -aFc -- "VF-FILE: WRITE h=" "$run_log" || true)" -ge 5 ] || phase_needs=0
            ;;
        readback)
            [ "$(grep -aFxc -- "vf: cat hf3/renamed.bin size=$HF3_SIZE" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFc -- "vf: cat ok bytes=$HF3_SIZE rts=" "$SER" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFc -- "cksum=$HF3_CKSUM" "$SER" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "rx-vf3-readback" "$SER" || true)" = 1 ] || phase_needs=0
            ;;
        delete)
            [ "$(grep -aFxc -- "vf: rm hf3/renamed.bin ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFc -- "already exists on the host share" "$SER" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "rx-vf3-delete" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFc -- "VF-FILE: DELETE hf3/renamed.bin" "$run_log" || true)" -ge 1 ] || phase_needs=0
            ;;
        app)
            # HF4 (issue #738): the host-compiled ELF is listed, exec'd
            # from the SHARE (2+ READ round trips — 65 KB spans the 32 KB
            # reply cap), its marker + exit status land in serial, and the
            # DESKTOP re-point proves the HOST manifest was read (apps=2
            # vs the ESP's 19).
            # Substring match (the loaded line carries entry/stack/head
            # fields past the size= prefix — the other needles are full
            # lines, this one is a prefix).
            [ "$(grep -aFc -- "exec: loaded $HF4_APP size=" "$SER" || true)" -ge 1 ] || phase_needs=0
            # The app marker is a substring match, not a whole line: the
            # console idle-seam partial flush can splice the marker's
            # trailing newline (the marker text itself stays intact) —
            # observed live on the app boot, same class as the a/v gate.
            [ "$(grep -aFc -- "$HF4_MARKER" "$SER" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "$HF4_EXIT" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "$HF4_MANIFEST_LINE" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "rx-hf4-app" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFc -- "VF-FILE: READ $HF4_APP" "$run_log" || true)" -ge 2 ] || phase_needs=0
            [ "$(grep -aFc -- "VF-FILE: READ APPS.TXT" "$run_log" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFc -- "VF-FILE: STAT $HF4_APP" "$run_log" || true)" -ge 1 ] || phase_needs=0
            ;;
        clone)
            # HF7 (issue #741): three CLONE round trips + the root LIST
            # showing all three worktrees + the runner's CLONE lines.
            for w in wt1 wt2 wt3; do
                [ "$(grep -aFxc -- "vf: clone repo -> ${w} ok" "$SER" || true)" = 1 ] || phase_needs=0
                [ "$(grep -aFc -- "VF-FILE: CLONE repo → ${w}" "$run_log" || true)" -ge 1 ] || phase_needs=0
                [ "$(grep -aFc -- "$w" "$SER" || true)" -ge 1 ] || phase_needs=0
            done
            [ "$(grep -aFxc -- "rx-vf7-clone" "$SER" || true)" = 1 ] || phase_needs=0
            ;;
        edit)
            # HF7 edit phase: the append round trip + the read-back proof.
            [ "$(grep -aFxc -- "vf: open wt1/README append h=0" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: write 0 n=512 wrote=512 chunks=1" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: fsync 0 ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: close 0 ok" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "vf: cat wt1/README size=$README_SIZE" "$SER" || true)" = 1 ] || phase_needs=0
            [ "$(grep -aFc -- "bytes=$README_SIZE rts=" "$SER" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFc -- "cksum=$README_CKSUM" "$SER" || true)" -ge 1 ] || phase_needs=0
            [ "$(grep -aFxc -- "rx-vf7-edit" "$SER" || true)" = 1 ] || phase_needs=0
            ;;
    esac
    if verify_hf3_disk "$phase"; then
        hf3_disk=1
    fi
    echo "$tag(phase=$phase): runner-rc=$rc serial-bytes=$bytes banner=$banner probe=$probe listed=$listed statline=$statline catok=$catok catcksum=$catcksum rts=$rts sub=$sub hello=$hello runner-write=$runner_write phase=$phase_needs hf3-disk=$hf3_disk fatal=$fatal" | tee -a "$REPORT"
    [ "$rc" = 0 ] && [ "$banner" = 1 ] && [ "$probe" = 1 ] && [ "$listed" = 1 ] && \
        [ "$statline" = 1 ] && [ "$catok" = 1 ] && [ "$catcksum" = 1 ] && [ "$rts" -ge 2 ] && \
        [ "$sub" = 1 ] && [ "$hello" = 1 ] && [ "$runner_write" = 1 ] && \
        [ "$phase_needs" = 1 ] && [ "$hf3_disk" = 1 ] && [ "$fatal" = 0 ]
}

: > "$REPORT"
{
    echo "VIRELAIOS live host-file-channel gate (M34 HF1+HF2+HF3+HF4+HF7, issues #735-#738/#741)"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

pass=0
n=0
for tag in $(seq -w 1 "$BOOTS"); do
    n=$((n + 1))
    if run_one "$tag"; then
        pass=$((pass + 1))
    fi
done

echo
echo "=== result ==="
# HF7 (issue #741): publish the raw measurement artifact, then fold the
# clone/edit proof into the gate verdict. The assertion is honest and
# measurement-driven: 3 clones must consume well under half of what 3
# copies consume, an edit must cost well under one full tree copy, and
# the untouched siblings must be byte-identical (the hard proof).
if [ -f "$MEASURE" ]; then
    cp "$MEASURE" "$(art m34-hf7-measurement.txt)"
    echo "--- artifacts/m34-hf7-measurement.txt ---"
    cat "$MEASURE"
    echo "---"
fi
hf7_pass=1
if [ "${HF7_CLONE_RAN:-0}" = 1 ] && [ ! -f "$RUN_DIR/hf7-ok" ]; then
    echo "HF7-MEASURE: FAIL — clone/edit measurement or worktree proof failed (see $(art m34-hf7-measurement.txt))"
    hf7_pass=0
else
    echo "HF7-MEASURE: pass (clones ran=${HF7_CLONE_RAN:-0}, edit ran=${HF7_EDIT_RAN:-0}, proof=$( [ -f "$RUN_DIR/hf7-ok" ] && echo ok || echo n-a)) — raw numbers in $(art m34-hf7-measurement.txt)"
fi
if [ "$pass" = "$n" ] && [ "$hf7_pass" = 1 ]; then
    echo "verify-live-vf: PASS — VF_PROBE 32 KiB spike + vf ls/cat + HF3 mutation round-trips (host-verified) + HF4 drop-and-exec app delivery + HF7 CLONE COW dedup measured ($pass/$n boot(s)); see $REPORT and $GATE_LOG"
    exit 0
else
    echo "verify-live-vf: FAILED — $pass/$n boot(s) passed (hf7_pass=$hf7_pass); see $REPORT and per-boot logs."
    exit 1
fi