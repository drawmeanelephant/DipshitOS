# Log — agent/buffy/docs-pass

## 2026-08-28 — claim 3377 (docs pass: README, AGENTS, status, GitHub Pages → M31)

The local checkout sat on `agent/buffy/input-poll-563`, which PR #593 had
already merged; `origin/main` had moved to M28 (SMP), M29 (VM depth),
M30/M31 (dynamic linking), the `HTTPD.BIN` in-guest web server, the M26
offline-preflight cards N13/N14, and the `sys_tcp_connect` wall-clock fix.
Every GitHub milestone is closed and the issue tracker is at zero open
issues — but README.md, AGENTS.md, and the GitHub Pages corpus still claimed
we were on milestone 13/14/16. This claim is the overall documentation pass:
fresh branch off `origin/main`, facts cross-checked against the GitHub API,
kernel sources, build manifest, and march trackers.

- README.md Status rewritten: M0–M31 summary, the hardware-depth trio
  (M28/M29/M30/M31), post-milestone landings, zero-open-issues state, no M32
  defined yet; Layout's `user/` entry now names `.ELF`/`.SO`.
- AGENTS.md Current milestone: 0–31 closed, both former open threads
  resolved (#151 class-B-headless pointer injection, #179 virtio input
  channel), no M32.
- docs/status.md: M17–M31 added to the Current position table with
  GH-milestone/issue/claim citations and exact card ranges (M19 P1–P16,
  M22 D1–D16, M23 E1–E25, M24 K1–K16, M25 F1–F18, M26 N1–N16, M27 G1–G30);
  "What comes next" rewritten (everything closed, ABI effectively full at
  65/128 implemented, ADR 0013 reserved 52–54); stale open-thread line
  removed; march-tracker note widened to M18–M31.
- site/ (GitHub Pages): index (status table through M31, what-runs-today
  with SMP + dynamic linking + HTTPD, 65-of-128 ABI), roadmap (shipped
  table through M31, "no active milestone" current section, honest bounds
  updated), architecture (diagram + subsystem table: 2-core SMP, 11-slot
  scheduler, 65/128 syscalls, LD.SO layer), capabilities, networking
  (TCP client + passive-open server, HTTPD), memory (M29 demand paging/COW/
  mmap, 11-slot pool), processes (11/11 pool, eight concurrent), userspace
  (ABI table extended to slots 46–64), programs (47 flat images + dynamic
  .ELF/.SO inventory, verified against `build.zig`), run (69 monitor
  commands), live-gates (136 gate scripts, M21–M31 + custom-virtio groups),
  build (dynamic ELF pipeline note), drivers (custom-virtio row, balloon
  note corrected).
- No kernel/userland/host behavior changes — docs only. ✅ done.
