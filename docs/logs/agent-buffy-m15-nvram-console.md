# Log — `agent/buffy/m15-nvram-console`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-07** — **Claim (buffy, `agent/buffy/m15-nvram-console`):** claim
  0015 filed — NVRAM console channel (post-exit console bytes over the
  proven runtime-SetVariable channel, the claim-0013-named successor step
  for the VZ serial gate). Status: 🔄 claimed, implementation starting.

- **2026-08-07** — **Done (buffy):** claim 0015 gate **passes** — post-exit
  console bytes reconstructed from the NVRAM channel on VZ
  (`tools/verify-nvram-console.sh`, evidence under `artifacts/`:
  `nvram-console-gate.txt`, `nvram-console.log`, `nvram-console-run.txt`).
  69–70 chunks covering banner, memory map, probe, seam diag, shell banner,
  and real `version`/`mem`/`echo`/`help` command output — the first
  post-exit console evidence from a real VZ run.

  **Big finding (ADR 0005):** a latent kernel bug — the flat loader copies
  the image to a runtime base without relocations, so `const`
  function-pointer tables in `.rodata` (vtables, the 14-command registry,
  string-slice tables) held link-time absolute addresses. The first vtable
  dispatch on real hardware (the shell seam) faulted instantly; host tests
  never caught it because macOS relocates test binaries. Fixed by building
  all such tables at runtime in BSS (`M15Console.vtable`,
  `monitor.registry`, `machine.control()`, `BootMessages.messages`,
  `elephant_lines`).

  Also fixed: NVRAM store capacity (probe dump gated off in nvram builds;
  the store is ~61 KiB writable, not 128 KiB), chunk cap raised 64→128
  (the cap — not the store — was truncating the session), and the gate now
  retries the documented flaky VZ post-exit death window (claim 0009) up
  to 3 times.
