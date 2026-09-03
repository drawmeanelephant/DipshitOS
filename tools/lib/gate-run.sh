#!/usr/bin/env bash
#
# gate-run.sh -- per-run isolation for live (class-B) gates.
# Issue #523 item 2, claim 6637. Source this from a verify-live-* script:
#
#   source "$(dirname "${BASH_SOURCE[0]}")/../lib/gate-run.sh"   # from tools/
#   gate_begin live-net-tcp
#   ... run VMRunner with "${GATE_RUNNER_ARGS[@]}", --serial "$RUN_DIR/vm-serial.log",
#       scratch files under "$RUN_DIR", evidence copied back to artifacts/ ... (optionally
#       gate_seed_share to arm the host file channel seeded with the app bundle) ...
#   gate_end
#
# gate_begin NAME:
#   - creates a private RUN_DIR (mktemp -d); two concurrent runs of the same
#     or different gates never share writable state;
#   - fills GATE_RUNNER_ARGS: --overlay-base artifacts/disk.img --vars <vars>
#     (macOS 27 DiskImageKit stacked image — M34 HF6 issue #740: the ONE
#     shared read-only boot image; every gate attaches the same canonical
#     artifacts/disk.img opened READ-ONLY as the base; the loader's own
#     pre-exit writes (BOOTED.TXT / MEMMAP.TXT / LOADER.TXT) plus all guest
#     writes land in a throwaway per-run ASIF overlay the runner deletes at
#     exit). No per-gate disk copy, no gate_shared_disk_lock: the base is
#     never written, so concurrent gates cannot collide on it. The image
#     build is atomic (make-image.sh writes IMAGE.tmp then renames), so a
#     gate that rebuilds artifacts/disk.img while another attaches it always
#     sees a complete image.
# gate_seed_share:
#   - arms the guest host file channel for this gate: creates $RUN_DIR/share,
#     copies the app bundle (zig-out/bin) into it, generates the ELF/.SO
#     fixtures (HELLO.ELF, CRASH.ELF, LD.SO, LIBUI.SO, ...) fresh, drops the
#     APPS.TXT manifest in, and appends --cvc-file "$SHARE" to
#     GATE_RUNNER_ARGS. A gate that execs an app or boots the desktop MUST
#     call this; gates that only read the serial port can skip it.
# gate_end:
#   - removes RUN_DIR unless VIRELAI_KEEP_RUN=1 (post-mortem escape hatch).
#
# Evidence policy: copy what you need back into artifacts/ BEFORE gate_end
# using the gate's canonical names. Two concurrent instances of the SAME
# gate may race on those canonical copies (last writer wins) but can no
# longer corrupt each other's runs.

set -euo pipefail

RUN_DIR=""
GATE_NAME=""
GATE_RUNNER_ARGS=()
SHARE=""

gate_begin() {
    GATE_NAME="$1"
    # Base directory is overridable for experiments/debugging:
    #   VIRELAI_RUN_DIR_BASE=<dir>  (default: ${TMPDIR:-/tmp})
    local base="${VIRELAI_RUN_DIR_BASE:-${TMPDIR:-/tmp}}"
    mkdir -p "$base"
    RUN_DIR="$(mktemp -d "$base/virelai-${GATE_NAME}.XXXXXX")"
    # M34 HF6 (issue #740): attach the CANONICAL artifacts/disk.img as the
    # read-only overlay base — no private copy (the boot volume is never
    # written by the guest; the loader's pre-exit evidence writes land in
    # the per-run ASIF overlay).
    local repo_root
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    [ -f "$repo_root/artifacts/disk.img" ] || { echo "gate-run: ERROR — artifacts/disk.img missing (run 'zig build image' first)" >&2; exit 1; }
    if [ -f "$repo_root/artifacts/efi-vars.bin" ]; then
        cp "$repo_root/artifacts/efi-vars.bin" "$RUN_DIR/efi-vars.bin"
    else
        : > "$RUN_DIR/efi-vars.bin"
    fi
    GATE_RUNNER_ARGS=(--overlay-base "$repo_root/artifacts/disk.img" --vars "$RUN_DIR/efi-vars.bin")
}

# gate_arm_share -- arm the host file channel with an EMPTY private share
# (for gates that only need the channel, not the app bundle — e.g. shell
# history persistence).
gate_arm_share() {
    [ -n "$RUN_DIR" ] || { echo "gate-run: gate_arm_share called before gate_begin" >&2; exit 1; }
    SHARE="$RUN_DIR/share"
    mkdir -p "$SHARE"
    GATE_RUNNER_ARGS+=(--cvc-file "$SHARE")
    echo "gate-run: share armed (empty) at $SHARE"
}

# gate_seed_share -- arm the host file channel with the app bundle.
# M34 HF6 (issue #740): apps are NOT in the image anymore; a gate that
# execs an app or boots the desktop seeds its private share from the
# compiled bundle (zig-out/bin) + freshly generated ELF/.SO fixtures +
# image/apps.txt, then arms --cvc-file.
gate_seed_share() {
    [ -n "$RUN_DIR" ] || { echo "gate-run: gate_seed_share called before gate_begin" >&2; exit 1; }
    gate_arm_share
    # 1. The compiled app bundle (USER.BIN, CALC.BIN, DESKTOP.BIN, ...).
    if [ -d zig-out/bin ]; then
        cp -R zig-out/bin/. "$SHARE/" 2>/dev/null || true
    fi
    # 2. Freshly generated fixtures (HELLO.ELF / CRASH.ELF via mkhello-elf,
    #    the M30/M31 dynamic-linking set via mkdyn-elf) — generated into
    #    the share so they exist even if the last `zig build image` ran
    #    before they were produced.
    if [ -f tools/mkhello-elf.py ]; then
        python3 tools/mkhello-elf.py "$SHARE/HELLO.ELF" 2>/dev/null || true
        python3 tools/mkhello-elf.py --crash "$SHARE/CRASH.ELF" 2>/dev/null || true
    fi
    if [ -f tools/mkdyn-elf.py ]; then
        python3 tools/mkdyn-elf.py "$SHARE" 2>/dev/null || true
    fi
    # 3. The desktop manifest (the guest reads /host/APPS.TXT).
    if [ -f image/apps.txt ]; then
        cp image/apps.txt "$SHARE/APPS.TXT"
    fi
    # 4. The default desktop wallpaper (the guest reads /host/WALLPAPER.QOI).
    if [ -f image/WALLPAPER.QOI ]; then
        cp image/WALLPAPER.QOI "$SHARE/WALLPAPER.QOI"
    fi
    # 5. TrueType fonts (Inter for UI, Fira Code for Monospace / terminal).
    if [ -f image/fonts/Inter-Regular.ttf ]; then
        cp image/fonts/Inter-Regular.ttf "$SHARE/INTER.TTF"
    elif [ -f FONTS-CHOOSE/Inter-4.1/extras/ttf/Inter-Regular.ttf ]; then
        cp FONTS-CHOOSE/Inter-4.1/extras/ttf/Inter-Regular.ttf "$SHARE/INTER.TTF"
    fi
    if [ -f image/fonts/FiraCode-Regular.ttf ]; then
        cp image/fonts/FiraCode-Regular.ttf "$SHARE/FIRACODE.TTF"
    elif [ -f FONTS-CHOOSE/Fira_Code_v6.2/ttf/FiraCode-Regular.ttf ]; then
        cp FONTS-CHOOSE/Fira_Code_v6.2/ttf/FiraCode-Regular.ttf "$SHARE/FIRACODE.TTF"
    fi
    echo "gate-run: share seeded at $SHARE ($(find "$SHARE" -maxdepth 1 -type f | wc -l | tr -d ' ') files, $(grep -cE '^[A-Z]' "$SHARE/APPS.TXT" 2>/dev/null || echo 0) APPS.TXT entries)"
}

# gate_reset_share_state -- delete per-boot guest persistence from the
# private share so each boot of a multi-boot gate starts from a clean
# slate. M37 DQ3 (issue #839, claim 6392): M21 W11 saves WINDOWS.SAV to
# the host share ~1/s on change and restores it at shell init, so boots
# B/C sharing one $RUN_DIR/share resurrect prior-boot windows (TABHOLD
# id drift → slot ENOSPC). HISTORY.TXT is deliberately kept —
# append-ordered shell history, benign across boots.
gate_reset_share_state() {
    [ -n "$RUN_DIR" ] || { echo "gate-run: gate_reset_share_state called before gate_begin" >&2; exit 1; }
    rm -f "$SHARE/WINDOWS.SAV"
}

gate_end() {
    [ -n "$RUN_DIR" ] || return 0
    if [ "${VIRELAI_KEEP_RUN:-0}" = "1" ]; then
        echo "gate-run: keeping $RUN_DIR (VIRELAI_KEEP_RUN=1)"
    else
        rm -rf "$RUN_DIR"
    fi
    RUN_DIR=""
    SHARE=""
}

# --- shared build bootstrap + serial-echo conventions ------------------------
# Every class-B gate used to carry its own copy of the fmt/swift/codesign
# preamble and the colored-prompt echo pattern; a toolchain or prompt change
# had to land in 167 files and silently drifted (issues #895/#896 — the first
# real CI run caught two gates whose echo expectations no longer matched the
# boot transcript). Centralize the parts that are truly identical; gates keep
# their per-gate differences (fmt file lists, -DSPIKE, special images) as
# ordinary calls around these helpers.

# gate_fmt_check -- zig fmt --check the given paths (one canonical invocation).
gate_fmt_check() {
    zig fmt --check "$@"
}

# gate_build_runner -- build + ad-hoc-codesign the release VMRunner with the
# VZ entitlements. Optional extra swift flags pass through (e.g.
# -Xswiftc -DSPIKE for the custom-virtio spike build).
gate_build_runner() {
    swift build --package-path host/vm-runner --configuration release "$@"
    codesign --force --sign - --entitlements host/vm-runner/entitlements.plist \
        host/vm-runner/.build/release/VMRunner
}

# gate_serial_has_echo -- did the guest console echo the given command in the
# serial log? Accepts BOTH observed echo forms:
#   colored (interactive shell):  \x1b[32mvirelai> \x1b[0m<cmd>\r
#   plain (pre-prompt race):      <cmd>\r on its own line
# The plain form is what the scripted first keystroke produces when it lands
# while the boot-log tail is still colliding with the first prompt render
# (first CI census, issues #895/#896): the guest executed the command, but the
# shell never redrew the colored prompt for it. The machine-level effect is
# the gate's real evidence; this matcher only proves the keystrokes reached
# the console.
gate_serial_has_echo() {
    local ser="$1" cmd="$2"
    grep -a -qF -- $'\x1b[32mvirelai> \x1b[0m'"$cmd" "$ser" 2>/dev/null && return 0
    # Plain form: the command at the START of a serial line (the guest echoed
    # it before the shell redrew the prompt). Line-based via awk (literal
    # index(), not a regex) so \n, \r and \r\n endings all work.
    awk -v c="$cmd" 'index($0, c) == 1 { f = 1 } END { exit !f }' "$ser" 2>/dev/null && return 0
    return 1
}
