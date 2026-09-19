#!/usr/bin/env bash
# Compile Cesanta Elk to wasm32-freestanding against the M35 caps.
# Engine sources are NOT in the tree (AGPL vs LICENSE). Clone first:
#   git clone --depth 1 https://github.com/cesanta/elk.git artifacts/js-wasm-measure/elk
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ENG="${JS_WASM_ENGINE_DIR:-$ROOT/artifacts/js-wasm-measure}"
ELK="$ENG/elk"
OUT="$ENG/build"
mkdir -p "$OUT"

if [ ! -f "$ELK/elk.c" ]; then
    echo "measure.sh: missing $ELK/elk.c — clone cesanta/elk into artifacts/js-wasm-measure/elk" >&2
    exit 2
fi

# STACK_SIZE is the wasm-ld C stack, not a frozen interpreter cap.
# Default 8192 is the original measurement; 65536 is the control that
# falsifies stack exhaustion as the exec trap.
STACK_SIZE="${STACK_SIZE:-8192}"
if [ "$STACK_SIZE" = 8192 ]; then
    DEST="$OUT/elk.wasm"
else
    DEST="$OUT/elk-stack${STACK_SIZE}.wasm"
fi

zig cc -target wasm32-freestanding -nostdlib -ffreestanding \
    -fno-sanitize=undefined -g0 -Os -DNDEBUG \
    -isystem "$ROOT/tests/js-wasm-measure/include" \
    -I "$ROOT/tests" \
    -I "$ELK" \
    -Wl,--no-entry \
    -Wl,--export=_start \
    -Wl,--initial-memory=131072 \
    -Wl,--max-memory=2097152 \
    -Wl,-z,stack-size="$STACK_SIZE" \
    -Wl,--strip-all \
    "$ROOT/tests/js-wasm-measure/elk_driver.c" \
    "$ROOT/tests/js-wasm-measure/stubs.c" \
    "$ELK/elk.c" \
    -o "$DEST"

python3 "$ROOT/tests/wasm-spike/wasm-inspect.py" "$DEST"
