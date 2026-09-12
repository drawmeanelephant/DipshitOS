# oliver-spike — a real Zig HTML tool as a native app on VirelaiOS

`oliver` (a Markdown → HTML tool, <https://github.com/drawmeanelephant/oliver>)
running on VirelaiOS as **two images from one source**: a native AArch64 ELF
(`exec OLIVER.ELF`) and a DSK1 flat image (`exec OLIVER.BIN`) that carries real
arguments. Proof: `tools/gate/specs/live-oliver.spec` (class-B, live VZ, 4/4).

| file | what it is | size | sha256 |
|---|---|---|---|
| `OLIVER.ELF` | the pinned native image (1 PT_LOAD R+X @0x0040_0000) | 253,576 B | `4d79d76ad725e2017cef49eaab4c006027a2e3c93897a8103636d44cd264ccb5` |
| `OLIVER.BIN` | the DSK1 flat image (`elf2bin.py`), the argv carrier | 249,220 B | `83b6549c853f5cf1e32ceb10ea966190bc3c2fac8ebe5915806d8ee0f4084743` |
| `oliver-native.zig` | the slice source: `_start(argc, argv)` + oliver's real `parse`/`html.render` | — | — |
| `md-fixture.txt` | the input document staged as `/host/MD.TXT` | 415 B | `acbdb682ac243f4a9d2adf6111f1cd64ca99e7c86e7631755d01637c8a8011f7` |
| `expect.html` | the reference tool's own output for that fixture | 754 B | `540f240054ad929c7311f29d83e0432b01551300ab97f01cf2aaac82f76a390e` |
| `sizeprobe-*.zig` | library-floor size probes (see the gap report) | — | — |

## Arguments

`OLIVER.BIN <in> <out>` — each argument falls back to its default (`MD.TXT`,
`OLIVER.HTML`) when absent, so the no-argument invocation is the documented
default path. A name starting with `/` is a full guest path; a bare name gets
the `/host/` prefix. The app prints what it received before touching any file:

```
oliver: argc=2 in=MD.TXT out=OUT2.HTML
oliver: wrote 754 bytes
```

That line is the difference between argv reaching the app and argv being
silently dropped, so the gate asserts it rather than only the output file. The
exit status is the number of HTML bytes written (the `wc`/filerocks discipline).

| exit | meaning | | exit | meaning |
|---|---|---|---|---|
| 2 | bad path | | 35 | output write failed |
| 31 | input open failed | | 36 | mmap (populate) failed |
| 32 | input read failed | | 37 | mmap (demand) failed |
| 33 | input larger than the cap | | 38 | write made no progress |
| 34 | output open failed | | 41/42 | parse / render failed |

The input buffer holds 128 KiB and the output buffer 64 KiB; a file that
*exactly* fills a cap is legal (only a file with bytes left over exits 33).

## Why two shapes

`kernel/src/exec.zig` packs the argv block only for DSK1/DSK3 images; a raw ELF
returns `.no_args_room`, so `exec OLIVER.ELF` always arrives with `argc == 0`.
The DSK1 flat image is the argv carrier today: the loader places the block at
`align8(content_len)` inside the program's own text page.

That budget is measured, not assumed: content 249,196 B, block at
249,200 + 256 = 249,456, `page_limit` 249,856 → **400 B of slack** before the
block would need a 62nd text page. The gate reproduces this arithmetic from the
image header on the host side and fails if it ever stops fitting. A larger app
needs the loader work in #1163 (or the DSK3 shape, which reserves a data tail).

## Rebuilding

The reference project is never modified in place. Vendor a copy of its `src/`
as untracked build input (`tests/oliver-spike/.gitignore` ignores `vendor/`),
then run the repo's host link recipe:

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

Then convert the SAME image to the flat argv-carrying form (a DSK1 image is
mapped read-only, so it must have no writable segment — oliver has none, and
`elf2bin.py` refuses otherwise):

```bash
python3 tools/elf2bin.py tests/oliver-spike/OLIVER.ELF tests/oliver-spike/OLIVER.BIN
python3 tools/elf2bin.py --info tests/oliver-spike/OLIVER.BIN
# elf2bin: ... entry_offset=0x2b38 image_size=249220 (content 249196 bytes from 1 PT_LOAD segment)
shasum -a 256 tests/oliver-spike/OLIVER.BIN   # keep this pin in step with the spec
```

Regenerating `expect.html` (the host-side ground truth):

```bash
zig build --build-file /path/to/oliver/build.zig   # or build in a copy of the project
/path/to/oliver/bin/oliver render --from markdown < tests/oliver-spike/md-fixture.txt
```

Neither path emits a timestamp or version stamp, so the compare is byte-exact
rather than normalized (recorded in the spec's setup hook).

## Known limits (measured — see `artifacts/oliver-spike/gap-report.md`)

* Raw-ELF `exec` still delivers **no argv** (`.no_args_room`), so argument-driven
  CLI use of `OLIVER.ELF` waits on the loader work in #1163. Until then ship the
  DSK1 image when arguments matter.
* The flat image's argv headroom is **400 B** of text growth (above); the size
  cap itself is not the binding constraint — 249,196 B is 47.6% of the real
  512 KiB (`exec_program_max` / `elf.load_max`).
* The image uses **no static writable buffers** (every buffer is anonymous
  `sys_mmap`): that keeps it a single R+X PT_LOAD and avoids the
  `data == text_base + p_memsz[0]` alignment trap the size probes hit.
* `exec` spawns a task and returns immediately, so a script cannot issue two
  invocations back to back and expect them ordered — the gate gives each one its
  own boot and ends it on `procs <name> exited status=754`.
