# oliver-spike — a real Zig HTML tool as a native ELF app

`oliver` (a Markdown → HTML tool, <https://github.com/drawmeanelephant/oliver>)
built for **VirelaiOS as a native AArch64 ELF app** and run with
`exec OLIVER.ELF`. Proof: `tools/gate/specs/live-oliver.spec` (class-B, live VZ).

| file | what it is | sha256 |
|---|---|---|
| `OLIVER.ELF` | the pinned app image (253,160 B, 1 PT_LOAD R+X) | `246c2a533f625d44f338706b7782bca618e80511bb9b4329d1c5f768bda4afc1` |
| `oliver-native.zig` | the slice source: `_start(argc, argv)` + oliver's real `parse`/`html.render` | — |
| `md-fixture.txt` | the input document staged as `/host/MD.TXT` | `acbdb682ac243f4a9d2adf6111f1cd64ca99e7c86e7631755d01637c8a8011f7` |
| `expect.html` | the reference tool's own output for that fixture | `540f240054ad929c7311f29d83e0432b01551300ab97f01cf2aaac82f76a390e` |
| `sizeprobe-*.zig` | library-floor size probes (see the gap report) | — |

The app reads `/host/MD.TXT` through the ADR 0010 file table (2048-byte
reads), parses and renders it with oliver's library, and writes
`/host/OLIVER.HTML` back through the M34 HF host share; the gate asserts the
written file **host-side, byte-exact** against `expect.html` and keeps the
serial lines as the order-of-events proof.

## Rebuilding

The reference project is never modified in place. Vendor a copy of its `src/`
as untracked build input, then run the repo's host link recipe with the
library wired in as a module:

```bash
git -C /path/to/oliver rev-parse HEAD   # 3f05bacb188ab28ad797430c82d9ee20080c5ed6
mkdir -p tests/oliver-spike/vendor/oliver
cp -R /path/to/oliver/src tests/oliver-spike/vendor/oliver/src

zig build-exe -target aarch64-freestanding -O ReleaseSmall -fstrip \
    -fno-PIE -fno-entry -z max-page-size=4096 -T tools/zc-host-link.ld \
    --dep zc --dep oliver \
    -Mroot=tests/oliver-spike/oliver-native.zig \
    -Mzc=user/src/lib/zc.zig \
    -Moliver=tests/oliver-spike/vendor/oliver/src/oliver.zig \
    -femit-bin=tests/oliver-spike/OLIVER.ELF

python3 tools/check-zc-host-contract.py tests/oliver-spike/OLIVER.ELF   # CONTRACT OK
```

Regenerating `expect.html` (the host-side ground truth):

```bash
zig build --build-file /path/to/oliver/build.zig   # or build in a copy of the project
/path/to/oliver/zig-out/bin/oliver render --from markdown < tests/oliver-spike/md-fixture.txt
```

Neither path emits a timestamp or version stamp, so the compare is
byte-exact rather than normalized (recorded in the spec's setup hook).

## Known limits (measured — see `artifacts/oliver-spike/gap-report.md`)

* `exec` hands argv to **DSK1/DSK3 images only**; a raw ELF gets
  `kernel/src/exec.zig`'s `.no_args_room`, so the app always arrives with
  `argc == 0` and uses its documented defaults (`MD.TXT` → `OLIVER.HTML`).
  Argument support for the tool therefore waits on the loader work in #1163.
* The image uses **no static writable buffers** (every buffer is anonymous
  `sys_mmap`): that keeps it a single R+X PT_LOAD and avoids the
  `data == text_base + p_memsz[0]` alignment trap the size probes hit.
* Headroom is thin: 248,776 B of memory against the 256 KiB
  (`exec_program_max`) cap — 13,368 B (5%). A larger tool needs #1163.
