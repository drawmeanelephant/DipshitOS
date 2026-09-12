# ADR 0028: In-guest HTML rendering (M-web slice 1)

- Status: ACCEPTED (slice 1 design)
- Date: 2026-09-12
- Issue: #1200 (design card + slice 1), umbrella #1201
- Related: ADR 0009 (app events), ADR 0010 (userland storage), ADR 0011
  (desktop platform), ADR 0016 (pixel ownership), ADR 0013 D3.1 (.bss budget),
  ADR 0026 (Go runtime port — numbering note below), M40 GF6 (gate rules),
  `docs/html-renderer-scoping.md` (the design card this ADR fixes)

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

**D3 — parse → layout → paint are separate modules, two of them pure.**
`lib/html/parse.zig` (bytes → flat node array) and `lib/html/layout.zig`
(nodes + style + width → line boxes) are framebuffer-free and host-tested under
`zig build test`; `layout` takes the text measurement as an injected function
so tests use a stub metric. Only `doc.zig` touches `ui` drawing. This is the
same shape as the repo's other testable subsystems, and it is what makes the
renderer's behaviour assertable without a VM.

**D4 — No bold or italic faces exist, so the stylesheet synthesizes.**
`ui.init_fonts` loads exactly `/host/INTER.TTF` (UI) and `/host/FIRACODE.TTF`
(mono, fixed size 13). `<strong>` renders as synthetic bold (a second 1-px
strike) and `<em>` takes the accent color. Both are recorded as revisitable:
vendoring a bold/italic face replaces the trick with no other change.

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
  cannot be used to smuggle unbounded scope into a slice.
- EDIT's inline wrap chunking remains a local implementation; NOTEPAD's tested
  `TextLayout` rule is the shared reference. Unifying them is a cleanup card,
  not a prerequisite.
