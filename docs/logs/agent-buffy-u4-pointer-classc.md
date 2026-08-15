# Log — U4 real-mouse pointer follow-on (claim 9015)

**Branch:** `agent/buffy/u4-pointer-classc`

- **2026-08-15** — *buffy*: wired claim 4993's real-mouse follow-up as a
  class-C gate `tools/verify-pointer-manual.sh`. The five synthesized
  pointer routes all produced `ptr-reports=0` (hardware contract), so only
  a human at the mouse can produce the reports — class C by construction.
  The gate boots `--input --display`, opens WINLOOP.BIN (three windows),
  instructs the human to move the real mouse (magenta cursor follows) and
  click clock → WINLOOP → terminal, then type `input` + `echo
  pointer-gate-done`; it asserts ≥2 distinct `win: pointer focus=` lines,
  `ptr-reports>0`, the magenta cursor pixel, and the done marker.
- Calibrated the cursor pixel live: `screen fill ff00ff` marker capture →
  magenta renders ~(234,51,247) through the color-managed pipeline, so the
  assertion reads the color family, not the raw triple.
- Smoke-proved the honest negative: a 60 s run reached
  `pointer-manual-ready` + `winloop: present ok` with zero focus lines and
  `ptr-reports=0` — the gate cannot false-PASS without a human.
- Registered in gate inventory (class=C, ci=no, apple=yes); updated the
  hardware contract, claim 4993, march-m8 U4, and status.md.
