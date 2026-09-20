# js-wasm-measure — M70d #1456, the bounded-subset measurement

NOT a shipped app and NOT a fleet gate (GF6: gates live under
`tools/gate/specs/`). This directory is the reproducible host measurement
for "does an existing JS engine compiled to `wasm32-freestanding` fit
`WASM.BIN`?".

The three interpreter caps, from `docs/wasm-import-contract.md` and
`user/src/wasm.zig`:

1. module size ≤ 64 KiB (`max_module_size`)
2. linear memory ≤ 32 pages / 2 MiB
3. imports are frozen `env.*` only (no WASI, no wasm exception-handling)

`python3 tests/wasm-spike/wasm-inspect.py <module.wasm>` is the inspector.

## Reproduce Elk (the only engine that produced a contract-clean module)

Elk is AGPL; this tree is proprietary (`LICENSE`). Do not vendor it. Clone
it into the gitignored `artifacts/` tree and compile:

```bash
git clone --depth 1 https://github.com/cesanta/elk.git artifacts/js-wasm-measure/elk
# observed SHA: 71a86fa2fef146696be9ae66715bf3f91d0a5f2c
bash tests/js-wasm-measure/measure.sh
python3 tests/wasm-spike/wasm-inspect.py artifacts/js-wasm-measure/build/elk.wasm
```

Observed 2026-09-19 on this host (`zig` 0.16.0 from Homebrew): **22763 B**,
`env.write` + `env.exit` only, memory min=2 / max=32 pages. Inspector PASS.

A one-shot guest run (not in the fleet) is
`tests/js-wasm-measure/run-under-wasm.spec`. Observed on VZ the same day:
the module loads and validates, then **traps / exit 3**. `max_frames = 32`
was the initial inference for the cause; M70d #1518 then put the class on
the serial and corrected it — the observed line is
`wasm: trap during exec kind=stack_overflow module=ELK.WASM offset=0x1980`.
The binding cap is the **control stack** (`max_ctl = 64`, with 16 live
frames at the trap), not `max_frames`; see ADR 0028 amendment A1. That is
the negative result this card records; the spec asserts the named trap.

```bash
# after measure.sh has produced elk.wasm and `zig build` has WASM.BIN
VGATE_NO_BUILD=1 bash tools/gate/vgate.sh tests/js-wasm-measure/run-under-wasm.spec
```

Control (same day): `-Wl,-z,stack-size=65536` still traps with the same
class (`kind=stack_overflow`). That flag is not a frozen cap; if the 8 KiB C
stack had been the cause, eval would have printed. It did not.
`__stack_pointer` was observed `i32.const 8192` vs `65536`. Spec:
`run-stack64k.spec`.

```bash
STACK_SIZE=65536 bash tests/js-wasm-measure/measure.sh
VGATE_NO_BUILD=1 bash tools/gate/vgate.sh tests/js-wasm-measure/run-stack64k.spec
```

## What was tried and did not produce a module under the caps

See the table in ADR 0028's M70d amendment. Short form: Duktape / MuJS /
MicroQuickJS need `setjmp` (wasm EH; `WASM.BIN` has none) and their native
`-Os` objects are already 359–666 KiB; QuickJS and mjs are not
`wasm32-freestanding`; TinyJS is C++ with exceptions.

## Files

| file | what |
|---|---|
| `measure.sh` | compile Elk against the contract line + these stubs |
| `elk_driver.c` | eval `1+2*3`, `v_write` the result, `v_exit(0)` |
| `stubs.c` + `include/` | freestanding crumbs so `-nostdlib` links |
| `run-under-wasm.spec` | optional one-shot VZ run (8 KiB stack); not in the fleet |
| `run-stack64k.spec` | 64 KiB stack control; still traps |
