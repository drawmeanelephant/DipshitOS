#!/usr/bin/env bash
#
# charmhello-tape.sh -- record M72c's actual guest scanout as a host-side
# PNG sequence. This is a demonstrator, not a verification gate: its output
# belongs in gitignored artifacts/ and it never reconstructs ANSI on the host.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${CHARMHELLO_TAPE_OUT:-$ROOT/artifacts/charmhello-tape/$(date -u +%Y%m%dT%H%M%SZ)}"
DRY_RUN=0

usage() {
    cat <<'EOF'
usage: bash tools/charmhello-tape.sh [--dry-run]

Records the M72c Bubble Tea window's real 2560x1440 scanout frames under
artifacts/charmhello-tape/<timestamp>/. Set CHARMHELLO_TAPE_OUT to choose a
different output directory. When ImageMagick `magick` is installed, the PNG
sequence is additionally encoded as a host-side GIF.
EOF
}

case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

if [ "$DRY_RUN" -eq 1 ]; then
    cat <<EOF
Would build disk, VMRunner, GOTABWM.ELF, and CHARMHELLO.ELF.
Would seed $OUT/share and record $OUT/charmhello-{5s,10s,15s,after}.png.
EOF
    exit 0
fi

[ "$(uname -s)" = "Darwin" ] || {
    echo "charmhello-tape: requires macOS Virtualization.framework (this is a host scanout recorder)" >&2
    exit 1
}

cd "$ROOT"
mkdir -p "$OUT"

zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist \
    host/vm-runner/.build/release/VMRunner
bash tools/go/build-gotabwm.sh
bash tools/go/build-charmhello.sh

SHARE="$OUT/share"
mkdir -p "$SHARE"
cp -R zig-out/bin/. "$SHARE/"
cp .build/go/GOTABWM.ELF .build/go/CHARMHELLO.ELF "$SHARE/"
cp image/apps.txt "$SHARE/APPS.TXT"
cp image/WALLPAPER.QOI "$SHARE/"
cp image/fonts/Inter-Regular.ttf "$SHARE/INTER.TTF"
cp image/fonts/Inter-Bold.ttf "$SHARE/INTERB.TTF"
cp image/fonts/Inter-Italic.ttf "$SHARE/INTERI.TTF"
cp image/fonts/FiraCode-Regular.ttf "$SHARE/FIRACODE.TTF"

cat >"$OUT/boot.txt" <<'EOF'
exec CHARMHELLO.ELF
EOF
cat >"$OUT/settle.txt" <<'EOF'
echo tape-settled
EOF
cat >"$OUT/close.txt" <<'EOF'
dui close 2
EOF

# The input chord is real HID. It flips the Tea model to PAUSED. The app's
# repaint marker releases the settle script; only that delayed host marker
# releases --screenshot-after (M69b: an app marker itself is pre-relayout).
# Keeping the guest alive past 15 seconds yields the runner's 5/10/15-second
# scanout frames as a re-runnable tape sequence.
rm -f "$OUT/vars.bin"
host/vm-runner/.build/release/VMRunner \
    --overlay-base artifacts/disk.img --vars "$OUT/vars.bin" \
    --cvc-file "$SHARE" --serial "$OUT/serial.log" \
    --screen "$OUT/charmhello.png" --screenshot-after tape-settled \
    --input --via-virtio \
    --script "$OUT/boot.txt" \
    --input-chords space --input-chords-after 'charmhello: ready' \
    --script2 "$OUT/settle.txt" --script2-after 'charmhello: repainted' --script2-delay 12 \
    --script3 "$OUT/close.txt" --script3-after tape-settled --script3-delay 4 \
    --script-expect 'charmhello: close' --timeout 90

python3 - "$OUT" <<'PY'
import glob, os, struct, sys

out = sys.argv[1]
paths = [os.path.join(out, "charmhello-%ss.png" % n) for n in (5, 10, 15)]
paths.append(os.path.join(out, "charmhello-after.png"))
for path in paths:
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("not a PNG scanout: " + path)
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) != (2560, 1440):
        raise SystemExit("unexpected scanout dimensions %dx%d: %s" % (width, height, path))
    print("scanout", os.path.basename(path), width, "x", height, len(data), "bytes")
PY

if command -v magick >/dev/null 2>&1; then
    magick -delay 50 -loop 0 \
        "$OUT/charmhello-5s.png" "$OUT/charmhello-10s.png" \
        "$OUT/charmhello-15s.png" "$OUT/charmhello-after.png" \
        "$OUT/charmhello.gif"
    echo "charmhello-tape: wrote $OUT/charmhello.gif"
else
    echo "charmhello-tape: ImageMagick not found; retained PNG sequence (not a host ANSI render)."
fi
echo "charmhello-tape: scanout evidence is in $OUT"
