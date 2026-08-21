# Log — `agent/buffy/m15-c9-calc-history`

### 2026-08-21 — claim 9091

Claimed. C9 CALC history + keyboard — top 60px history 10×40B ring, Up/Down cycle, complete keyboard surface 0-9 +-*/% . Enter Backspace Esc, M+/M-/MR/MC verify, BODMAS docs, pure calc.zig, no ScrollView, after C8 89dabe7.

### 2026-08-21 — claim 9091 done

Implemented. `calc.zig` history (`history_max 10`, `history_area 8,8,239,60`, `display_rect 8,72`, buttons y+64, `HistoryEntry`, `push_history_entry`, `record_history_from_engine`, `history_up`/`down` with scroll, `draw` history + indicator) + keyboard (`handle_keyboard_event` digits, `+-*/%`, `.` no-op, Enter `0x28`/`=`, Backspace `0x08`/`0x2a`, Esc `0x29`, Up/Down cycle, `m` MR, BODMAS docs) + memory verify. Host tests 22/22 PASS (3 new), AppState 1744B, `zig build`/`image` PASS 8153B, `verify-bss-budget` PASS.

