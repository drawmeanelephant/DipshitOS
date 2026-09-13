# Exercise 2 — Run your own Go program in VirelaiOS

**Goal:** take Go support for a real spin: write a tiny program yourself,
cross-compile it with the `GOOS=virelai` fork toolchain, boot the OS, and
`exec` it from the console — then find **your own output** in the VM's
serial log.

**Time:** ~10 minutes.

## Steps

From the repository root:

**1. Write the program** (or use the provided sample `fib.go` next to this
file — the commands below assume it):

```bash
mkdir -p ../virelai-go-lab
cp exercises/go-support/fib.go ../virelai-go-lab/fib.go
```

**2. Cross-compile it with the fork toolchain.** The program path must be
absolute; `GO_BUILD_NAME` fixes the output name (the guest loads it from
the share):

```bash
GO_BUILD_NAME=FIB bash tools/go/build-go.sh "$PWD/../virelai-go-lab/fib.go"
ls -l .build/go/FIB.ELF
```

**3. Stage a private run directory and host share.** Do NOT pre-create the
EFI vars file — VMRunner initializes a fresh 128 KiB NVRAM store when the
`--vars` path does not exist (a 0-byte file makes VZ fail with "Could not
open variableStore"):

```bash
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/virelai-go-lab.XXXXXX")
mkdir -p "$RUN_DIR/share"
cp .build/go/FIB.ELF "$RUN_DIR/share/"
printf 'exec FIB.ELF\n' > "$RUN_DIR/script.txt"
```

**4. Boot the OS and run it.** First time only, build the release VM
runner — the SPIKE build is required (the share channel `--cvc-file` is
compiled only behind `-DSPIKE`) **and it must be ad-hoc re-signed with the
Virtualization entitlements**, otherwise macOS refuses to start the VM —
then launch (absolute image path, the gate-fleet shape):

```bash
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist \
  host/vm-runner/.build/release/VMRunner

host/vm-runner/.build/release/VMRunner \
  --overlay-base "$PWD/artifacts/disk.img" \
  --vars "$RUN_DIR/efi-vars.bin" \
  --cvc-file "$RUN_DIR/share" \
  --serial "$RUN_DIR/vm-serial.log" \
  --script "$RUN_DIR/script.txt" \
  --script-expect 'fib-lab OK' \
  --timeout 120
echo "runner exit: $?"
```

A VM window opens; the kernel boots and the scripted console execs
`FIB.ELF` from the share. The runner exits 0 as soon as your program
prints `fib-lab OK`.

## Expected output

The runner exits 0, and the serial log contains:

```
exec: loaded FIB.ELF
fib 0 = 0
fib 1 = 1
fib 2 = 1
...
fib 10 = 55
fib-lab OK
```

## Pass/fail check

```bash
grep -n 'fib 10 = 55\|fib-lab OK' "$RUN_DIR/vm-serial.log"
```

- **PASS** if `runner exit: 0` **and** both grep lines appear.
- **FAIL** otherwise — print the tail: `tail -40 "$RUN_DIR/vm-serial.log"`.

## Cleanup

```bash
rm -rf "$RUN_DIR"
```

## What this proves

Your own Go source → `GOOS=virelai GOARCH=arm64` static ELF → gap-loader
exec at the 0x400000 text aperture → console output via the syscall seam —
the full author-compile-run loop, not just the repo's canned fixtures.

Want more? Edit `fib.go` (print primes, a recursion, a `map`… — stick to
`println` and pure computation; the phase-2 `os`/`syscall` file layer is
not ported yet, see `tools/go/README.md`), rebuild, and rerun steps 2–4.
