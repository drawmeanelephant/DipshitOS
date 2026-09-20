# ADR 0028: In-guest HTML rendering (M-web slice 1)

- Status: ACCEPTED (slice 1 design); amended M70d #1456 2026-09-19; amended M69d #1531 2026-09-20
- Date: 2026-09-12
- Issue: #1200 (design card + slice 1), umbrella #1201
- Related: ADR 0009 (app events), ADR 0010 (userland storage), ADR 0011
  (desktop platform), ADR 0016 (pixel ownership), ADR 0013 D3.1 (.bss budget),
  ADR 0026 (Go runtime port — numbering note below), M40 GF6 (gate rules),
  `docs/html-renderer-scoping.md` (the design card this ADR fixes),
  M70d #1456 (JS-in-WASM measurement), `docs/wasm-import-contract.md`

## Context

Oliver (a real Zig CLI tool) runs in-guest on the native ELF path and emits
HTML byte-exactly — `tests/oliver-spike/expect.html` is pinned, and #1191
verified it against the host CLI's own output. Nothing in VirelaiOS can display
that output. The project wants the other half of the pipeline in-guest:
Markdown → oliver → HTML → pixels, with no host round trip.

The temptation is to aim at "a browser". That would import two enormous,
unbounded pieces of scope (a JS engine and a CSS cascade) into an OS whose
userland has no allocator-heavy services, no threads-to-spare, and a 512×424
user back-buffer. The project's own history is the counter-argument: every
subsystem that landed cleanly (text editor, terminal, WM, layout engine) did so
as a bounded slice with a declarative gate.

ADR numbering: **0027 is claimed by #1194** (GOOS=virelai 0b, threads/futex).
This ADR takes 0028 rather than racing it; if a future card wants a number,
check `docs/decisions/` and the open claims at push time.

## Decision

**D1 — The renderer is userland.** `DOC.BIN` (`user/src/doc.zig`) is an
ordinary EL0 app over `lib/tabapp.zig`. No new syscalls, no kernel changes;
the kernel never parses HTML. It stays inside the app's existing privileges
(file channel, window back-buffer, events).

**D2 — No JavaScript, and no CSS cascade.** Styling is a single compiled-in UA
style table (per-tag size/margins/indent/mono flags). A page cannot change its
own presentation. This is a permanent property of the arc, not a slice-1
shortcut: if pages later need styling, the answer is a rendering *hint* in the
source (as Markdown tooling already produces), not a cascade in the guest.
**Amended M70d #1456 (2026-09-19):** scripting also does not land as a
`wasm32-freestanding` guest under `WASM.BIN`. The measurement is Amendment A
below; raising interpreter caps (`max_module_size`, `max_frames`, wasm EH) to
admit an engine is a **new ADR**, not a silent follow-on.

**D3 — parse → layout → paint are separate modules, two of them pure.**
`lib/html/parse.zig` (bytes → flat node array) and `lib/html/layout.zig`
(nodes + style + width → line boxes) are framebuffer-free and host-tested under
`zig build test`; `layout` takes the text measurement as an injected function
so tests use a stub metric. Only `doc.zig` touches `ui` drawing. This is the
same shape as the repo's other testable subsystems, and it is what makes the
renderer's behaviour assertable without a VM.

**D4 — Emphasis uses real faces when they are staged, and synthesizes only as fallback.**
Share names (frozen M69d #1531 D1): `/host/INTER.TTF` Regular, `/host/INTERB.TTF`
Bold, `/host/FIRACODE.TTF` mono, optional `/host/INTERI.TTF` Italic.
**Amended M69d #1531 (2026-09-20):** Go WEB selects Inter Bold for `<strong>` /
headings when `INTERB.TTF` parsed; the 1-px second strike is dead on that path
and remains only when Bold is absent. Inter-4.1 extras ships `Inter-Italic.ttf`,
staged as `/host/INTERI.TTF`; `<em>` selects it (accent colour stays). Zig
`ui.init_fonts` and DOC.BIN consume the same four names as of M69d2 (#1536),
which is also where the 1-px strike became a fallback on that tree. Amendment B
records the observed files and both trees' measurements.

**D5 — Unknown elements degrade to their text content.** Unsupported tags
(and malformed markup) are flattened into the enclosing block in document
order — never dropped, never fatal. This is a deliberate consequence: the
pinned oliver fixture contains a `<table>`, which slice 1 does not lay out, so
the cells must still appear as readable text. "Renders nothing and looks fine"
is the failure mode this rule forbids.

**D6 — Static caps, no heap; overflow is visible.** File bytes live in an
anonymous mmap region (M29 slot 63, the `view.zig` pattern); the node and line
arrays are fixed-capacity with a documented truncation marker. A page that
exceeds a cap renders a visible truncation notice rather than panicking or
silently cutting text.

**D7 — The arc is a ladder, and each rung earns its own gate.**
S1 the tag whitelist above (local file, keyboard scroll, error path);
S2 tables and definition lists; S3 `<img>` via `lib/png.zig`/`lib/qoi.zig`;
S4 links + navigation through TabApp's nav seam; S5 `DOC.BIN <url>` over the
existing FETCH/HTTP seam — the first network rung, explicitly last among the
render features; S6 the publish workflow (batch oliver → share → DOC/HTTPD).
Each rung is a declarative `tools/gate/specs/live-doc*.spec`; no renderer
behaviour lands without a pixel probe.

## Consequences

- The markdown toolchain gains an output path in-guest, and the "my Zig runs
  on VirelaiOS" story gains a visible end product.
- Renderer quality is bounded by the UA table, so a page's look is a project
  decision rather than an authoring one. That is accepted (D2) and is why the
  table lives in one reviewable place.
- Layout correctness is testable without a VM, so regressions in wrapping or
  block stacking show up in `zig build test`, not only in a live gate.
- The gate's pixel probes depend on the fonts actually loading; a silent
  fallback to the 8×8 bitmap would change metrics. The spec asserts the
  typography markers alongside the pixel probes for that reason.
- Network, JS, and cascade stay out by rule (D2, D7), so the "browser" framing
  cannot be used to smuggle unbounded scope into a slice. M70d measured the
  "JS as a WASM module" escape hatch and closed it under the frozen caps
  (Amendment A).
- EDIT's inline wrap chunking remains a local implementation; NOTEPAD's tested
  `TextLayout` rule is the shared reference. Unifying them is a cleanup card,
  not a prerequisite.

## Amendment A — M70d #1456: JS does not fit the sandbox

Date: 2026-09-19. Card: #1456 deliverables 2–3 (a bounded JS subset as a
`wasm32-freestanding` module under `WASM.BIN`, measured before promising).
A negative result closes the card. Host: `zig` 0.16.0 (Homebrew), macOS 27.2
arm64, VZ `hv_vm_create -> HV_SUCCESS`.

The frozen interpreter caps (not re-decided here):

- module ≤ 64 KiB (`user/src/wasm.zig` `max_module_size`)
- linear memory ≤ 32 pages / 2 MiB (contract §2 D2)
- frozen `env.*` only, no WASI, no wasm exception handling
- call depth `max_frames = 32`

Bounded subset under test: eval a few-byte script (`1+2*3`), console
round-trip, no timers, no DOM, no network. No engine written from scratch.
Harness: `tests/js-wasm-measure/` (not a fleet gate). Inspector:
`tests/wasm-spike/wasm-inspect.py`.

### Observed compiles

| Engine | Ref | License | What was observed |
|---|---|---|---|
| Elk | `cesanta/elk` `71a86fa` | AGPL | `zig cc -target wasm32-freestanding -nostdlib -Os`: **22763 B** module, `env.write`+`env.exit` only, memory min=2 / max=32. Inspector **PASS**. |
| MicroQuickJS | `bellard/mquickjs` `203d5bb` | MIT | Native `gcc -Os` `mquickjs.o` **666384 B**. `wasm32-wasi` compile refused (`setjmp.h` requires wasm EH). |
| Duktape | 2.7.0 tarball | MIT | Native `cc -Os` `duktape.o` **428992 B**. `wasm32-wasi` refused on the same wasm-EH `setjmp`. |
| MuJS | `ccxvii/mujs` `8a32c39` | ISC | Native `cc -Os` amalgam `.o` **359184 B**. `wasm32-wasi` refused on wasm-EH `setjmp`. GitHub clone is README-only (migrated to Codeberg). |
| QuickJS | `bellard/quickjs` `04be246` | MIT | `quickjs.c` is 2033048 B of C; freestanding compile dies on libc headers (`inttypes.h` `include_next`). |
| mjs | `cesanta/mjs` `cf375c4` | GPL-2 | `#error CS_PLATFORM` / POSIX headers; not freestanding. |
| TinyJS | `gfwilliams/tiny-js` `8214477` | MIT | C++ (`std::string`/`vector`) plus exceptions; `-fno-exceptions` does not compile. |

Elk is the only engine that produced a contract-clean module under the three
byte caps.

### Observed guest run (Elk)

`VGATE_NO_BUILD=1 bash tools/gate/vgate.sh tests/js-wasm-measure/run-under-wasm.spec`
**PASS 1/1** on VZ, asserting the trap (not a successful eval):

- VF-FILE read of `ELK.WASM` size=22763, full read
- no `wasm: module too large` / parse / validate / instantiate trap
- serial: `wasm: trap during exec kind=stack_overflow module=ELK.WASM offset=0x1980`
- `tasks user-exec exited status=3` (the interpreter's trap-during-exec exit)

At measurement time the guest did not print a trap class, so **inferred:**
Elk's recursive C eval exceeds `max_frames = 32`. Inspect-clean is not
execute-clean.

### A1 — M70d #1518, same day: the class, observed

The exec-trap path now prints `kind=`, `module=`, and the module byte offset
(card #1518; spec `tools/gate/specs/live-wasm-trap.spec`). The inference is
**corrected, not confirmed**: the class is `stack_overflow`, not `call_depth`.
Re-running the same pinned module through the interpreter's host capture seam
(`-OReleaseFast`) records the state at the trap: `frame_len=16`
(`max_frames = 32` never reached), `ctl_len=64` (`max_ctl = 64` full), `sp=3`
(the operand stack is nearly empty). The binding cap is the **control stack**;
offset `0x1980` is a `block` opcode. Whether `max_frames` would also bind
after any `max_ctl` raise is unmeasured — do not carry the old
`max_frames = 32` cause forward as fact.

### Control: 64 KiB C stack (not a frozen cap)

The original link line used `-Wl,-z,stack-size=8192`. That is a wasm-ld
layout flag inside the 2 MiB linear-memory allowance, not an interpreter
cap, so stack exhaustion was an unfalsified alternative to `max_frames`.

Same compile 2026-09-19 with `-Wl,-z,stack-size=65536`:

- module still **22763 B**, inspector PASS, `env.write`+`env.exit`, memory 2/32
- binaries differ: global 0 `i32.const` **8192** vs **65536** (`__stack_pointer`)
- `VGATE_NO_BUILD=1 bash tools/gate/vgate.sh tests/js-wasm-measure/run-stack64k.spec`
  **PASS 1/1** on VZ, asserting the same named trap:
  `wasm: trap during exec kind=stack_overflow module=ELK.WASM offset=0x1980` /
  `tasks user-exec exited status=3` (A1)

The 8 KiB C stack is **falsified** as the cause. The remaining inference was
`max_frames = 32`; A1 observed the control-stack cap instead (`ctl_len = 64`
with 16 live frames), so `max_frames` is not the cap that fired for this
module either. A 64 KiB stack would have been a free fix; it is not.

### What this does not change

- The renderer is unchanged. No cascade. No renderer-side JS.
- No additive `env.*` names. Elk needed only `write` and `exit`, already frozen.
- No `live-browser-js.spec` in the fleet: that spec is for a module that runs.
  The measurement spec lives next to the harness and is not discovered by
  `fleet.sh`.
- Elk is AGPL; this tree is proprietary (`LICENSE`). It is not vendored. Even
  a future ADR that deepens `max_frames` would still have to pick an engine
  this license can carry.

Raising `max_module_size`, `max_frames`, or adding wasm EH/WASI to admit
MicroQuickJS/Duktape/MuJS is a new interpreter ADR. This card does not do it.

## Amendment B — M69d #1531: Inter Bold (and Italic) are real faces

Date: 2026-09-20. Card: #1531. Host: Inter 4.1 extras TTF (`rsms/inter` v4.1),
SIL OFL 1.1 (`image/fonts/OFL-Inter.txt`). Regular already in-tree at
`image/fonts/Inter-Regular.ttf` byte-matches `extras/ttf/Inter-Regular.ttf`
(411,640 bytes).

### Observed files

| Face | Source (Inter-4.1 extras) | In-tree | Share name | Bytes |
|---|---|---|---|---|
| Regular | `extras/ttf/Inter-Regular.ttf` | `image/fonts/Inter-Regular.ttf` | `/host/INTER.TTF` | 411,640 |
| Bold | `extras/ttf/Inter-Bold.ttf` | `image/fonts/Inter-Bold.ttf` | `/host/INTERB.TTF` | 420,428 |
| Italic | `extras/ttf/Inter-Italic.ttf` | `image/fonts/Inter-Italic.ttf` | `/host/INTERI.TTF` | 417,388 |
| Mono | (Fira Code, unchanged) | `image/fonts/FiraCode-Regular.ttf` | `/host/FIRACODE.TTF` | 289,624 |

Italic **was** in the same extras tree Regular already used, so D2 of the card
requires it. No other family's italic was fetched. Fira Code Bold was not
vendored.

Inter keeps glyph **advances** matched across Regular and Bold (observed:
`Measure("MMMMMMMM")` is 96px for both at body size). The discriminator is
stem coverage / ink, not width: Regular M×8 paints 440 ink px, Bold 592, a
Regular+1px strike 664. `Fonts.BoldHeavier()` and `live-web-ttf` boot 02 pin
that.

### The Zig consumer (M69d2, #1536)

Same share names, same shape — `ui.init_fonts` loads four faces through one
helper (`loadFace`) and every face gets its own `GlyphCache`, because the cache
keys an entry by **codepoint alone** (`font_ttf.zig: ascii_entries`); two faces
sharing one cache would paint whichever was rendered first. `DOC.BIN` paints a
bold run with Inter Bold and an `<em>` run with Inter Italic (the accent colour
stays, and Bold still wins where both apply — there is no Bold-Italic face, the
same rule Go WEB uses). The 1-px second strike survives only as the fallback for
a missing Bold face, which is what `typography: Inter Italic absent, em keeps
accent` reports for Italic.

Measured in-guest by that app's own probe (`typography: ink`, painted pixels at
the painter's 96/255 coverage cut; `diff` = pixels where the Bold mask disagrees
with the strike that doubles Regular), `live-doc` runs 01 vs 04:

| size | Regular | Bold (real) | 1-px strike | Bold vs strike (`diff`) |
|---|---|---|---|---|
| 14 px (body) | 21 | 38 | 36 | 2 |
| 24 px (heading) | 64 | 111 | 89 | 26 |
| 14 px, `INTERB.TTF` removed | 21 | 36 (=strike) | 36 | 0 |

Two things this records that the Go row's numbers do not say:

- The metric differs: Go's row counts ink on a RENDERED surface at body size
  (440/592/664 for `M`×8), while the Zig probe counts mask pixels at the
  painter's own cut. At the same nominal body size, Zig measures the real Bold
  face as **heavier** than the strike (38 vs 36), the opposite relation to the
  Go row — which is why `live-doc` asserts `bold > regular` at body size and
  `bold > strike` at 24 px, rather than the one direction that happened to hold
  on the other tree.
- At 14 px the real face and the synthetic strike are within **2 px** of each
  other, so the old behaviour was nearly invisible at body size and only became
  a design question at heading sizes. Card D2 (a missing Bold face is a failed
  card, not a silent fallback) is what keeps the difference honest.

### What this does not change

- No font system, no variable axes, no user-installable faces, no new syscall
  (card D3).
- No cache redesign: `GlyphCache` still keys by codepoint alone, so one cache
  still serves one size. DOC's probe therefore rasterizes each measured size
  into a local cache rather than reading the size through the app's own.
- `<em>` keeps the accent colour; the Italic face supplies the slant.
- Bitmap 8×8 fallback still synthesizes bold with a 1-px strike, because that
  face has no Bold counterpart. The TrueType path does not.

