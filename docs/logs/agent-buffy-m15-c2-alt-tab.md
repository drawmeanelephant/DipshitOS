# Log — `agent/buffy/m15-c2-alt-tab`

### 2026-08-20 — claim 2873

Claimed. C2 Alt+Tab cycling UI — visual overlay over the M8 U4 hidden decode. Hold-Alt+Tab shows centered preview list, Tab/Shift+Tab cycles, release-Alt raises. Pure compositor (`driving_award.zig`) + input latch (`input.zig`) + shell drain (`shell.zig`). No new ABI, respects D7/D8.


### 2026-08-20 — claim 2873 done

Implemented. `driving_award.zig` BSS overlay (`active`/`selected`/`ids`/`count` ≈32 B), `input.zig` Alt+Shift latch (`alt_held`+`take_alt_tab_shift`), `shell.zig` hold-Alt commit (activate → cycle → release `focus+raise`). Fixed `draw_chrome` title-bar alias memcpy panic (now host-tested with 2 user windows). Tests: `driving_award` 125/125 + 338/338 PASS (new `alt_tab` snapshot/cycle/commit/dismiss + overlay render), class-A `verify-unit-tests` + `verify-bss-budget` PASS `9787576/11534336` (1746760 headroom), `zig fmt` + `test-console` PASS. No new ABI, respects D7/D8.
