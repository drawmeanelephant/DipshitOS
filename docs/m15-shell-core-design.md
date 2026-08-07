# Milestone 1.5 — console & shell core (agent B): design and self-review

Status: implemented, mock-tested, claim closed ✅ · Branch:
`freebuff/milestone-1-5-console-shell-core-agent-b-rx-read-p-2ee77bfe-eac9-4018-b5e1-ea38a0080268`
Date: 2026-08-06 · Prompt: the M1.5 agent-B prompt (console & shell core)

This design is subordinate to AGENTS.md, `docs/status.md` (M1.5 march
steps 9–11, coordination rules, changelog), ADR 0002/0004
(D4: polled TX-only console, no RX), `docs/testing.md`,
`docs/hardware-contract.md`, and the agent-B prompt. It builds **against a
mock console only**; no live serial RX is required and no hardware claim
is made. Live RX reads are `[inferred]` and gated on the VZ serial gate
(claim 0002, unpassed).

## 0. Coordination note (binding prompt vs. repo reality)

The agent-B prompt names `docs/claims/0004-m15-console-shell-core.md`,
`docs/logs/`, `docs/march-m15.md`, `tools/status/refresh-indexes.sh`, and
`docs/status.md` as binding — and on the current `main` they all exist.
Timeline honesty: this branch's base (`agent/buffy/m15-commands` tip)
**predated** the claims/logs split (PRs #14/#15 landed the coordination
infrastructure afterwards), so during development the claim was registered
in `docs/status.md`'s then-binding table and the march lived there. On the
current coordination surface the slice is re-registered properly:

- claim `docs/claims/0004-m15-console-shell-core.md` flipped ✅ with
  evidence;
- branch log `docs/logs/agent-buffy-m15-shell-core.md` created;
- `bash tools/status/refresh-indexes.sh` run to regenerate the index
  tables;
- steps 9–11 flipped in `docs/march-m15.md` (the per-milestone tracker),
  while `docs/status.md` stays edit-free;
- `tools/verify-unit-tests.sh` (binding kernel-module test list) extended
  with the three new modules; `tools/verify-coordination.sh` is main's
  authoritative version, reused as-is.

## 1. Goal and scope

Make the milestone-two kernel's terminal WFE loop serve the interactive
`dipshit>` monitor: read a line from the console, edit it (bounded, no
allocator), tokenize it (fixed arity), and execute it through the existing
`monitor.lookup`/`exec` registry. The VZ serial gate (claim 0002) has not
passed, so **no live RX read is implemented**; the loop is proven correct
against a scripted `MockConsole` in `zig test`, and the `main.zig` seam is
the smallest possible change (imports + one call + the WFE-park fallback),
leaving the takeover path (ExitBootServices, MMU, probe, `uart_*`)
byte-identical.

## 2. New / changed files

| File | Change |
|------|--------|
| `kernel/src/console.zig` | **changed**: `Console.VTable` gains `readByte: ?u8` (polled, non-blocking); `MockConsole` gains a scripted input queue (`feed`, `readByte`, `input_overflowed`); new tests |
| `kernel/src/lineedit.zig` | **new**: bounded 256-byte line editor (CR/LF submit, backspace, Ctrl-C cancel, overflow refusal, echo), all edge cases host-tested |
| `kernel/src/tokenizer.zig` | **new**: fixed-arity tokenizer (`max_args_limit + 1` slots), whitespace splitting, optional double-quoted strings, explicit unbalanced-quote and too-many behavior |
| `kernel/src/shell.zig` | **new**: `Shell` (`boot`, `poll`), `handle_line`, `bootAndPark` (banner → loop, or banner + prompt + return so the kernel parks), mock-fed end-to-end transcript test |
| `kernel/src/main.zig` | **seam only** (after the `kernel terminal state` print): imports, a TX-only `Console` adapter over `uart_*` whose `readByte` is an `[inferred]` no-RX stub, `Monitor` construction from the captured map + handoff, one `shell.bootAndPark(...)` call, then `halt_forever()` |
| `tools/verify-unit-tests.sh` | **new**: binding `MODULES` list — runs `zig test` on every `kernel/src/*.zig` module (existing 4 + lineedit/tokenizer/shell) |
| `tools/verify-coordination.sh` | **new**: claims/changelog/steps in sync with `docs/status.md` |
| `justfile`, `.github/workflows/ci.yml` | wire the two new tools into `just verify` and CI |

## 3. Step 9 — console read abstraction (`console.zig`)

Smallest honest API: a polled, non-blocking `readByte: ?u8` on the vtable
(`null` = no input available now). No buffers, no allocation, no blocking —
fits the polled WFE-loop design. The existing `write`/`flush` stay as-is.

`MockConsole(comptime capacity)` gains an input queue mirroring its output
capture: a fixed `[capacity]u8`, `feed(bytes)` appends (flagging
`input_overflowed` when the queue overflows), `readByte` pops in order.
`reset()` clears both directions.

**Observable evidence (zig test, `console.zig`):** `feed` then
`readByte` returns the exact scripted bytes in order; empty queue → `null`;
`readByte` on a fresh mock → `null`; vtable completeness (all three slots
wired). Output capture behavior is unchanged (existing tests still pass).

## 4. Step 10 — bounded line editor (`lineedit.zig`)

`LineEditor` holds `buffer: [256]u8` (no allocation, no libc). `feed(con,
byte)` returns `LineResult {none, submitted, cancelled}` and echoes:

| Input | Effect | Echo |
|-------|--------|------|
| CR (0x0D) or LF (0x0A) | submit the line (`buffer[0..len]`) | `\r\n` |
| backspace (0x08) or DEL (0x7F) | delete last char | `\b \b`; bell `\x07` when empty |
| Ctrl-C (0x03) | cancel/clear the line | `^C\r\n` |
| printable / tab | append while `len < 256` | the byte itself |
| printable when full | **refused** (never truncated mid-word) | bell `\x07`, sets `rejected` |
| other control bytes | ignored (not echoed, not appended) | — |

CRLF handling: a line submitted by CR leaves `submitted_cr` set; the LF
half of a CRLF pair is swallowed on the very next `feed` (one Enter → one
line), while a lone CR still submits ("CR without LF" edge). The shell
calls `nextLine()` after a submit (keeps the swallow window) and `reset()`
after a cancel (closes it). Accepted edge (reviewed, deliberate): the
swallow window survives `nextLine` until any byte arrives, so on a
pathological CR-only terminal a *later* lone-LF Enter would be swallowed
(an empty line lost). Realistic terminals send CR, LF, or CRLF
consistently, and any other byte closes the window — accepted and
documented in the code comment.

**Observable evidence (zig test, `lineedit.zig`):** exact echo streams for
empty line (`\r\n` only), 255/256 chars (fit exactly, submitted),
257 chars (bell once, `rejected`, 256-char line submitted), backspace at
start (bell, no deletion), backspace mid-line (`\b \b`), CR alone, CRLF
pair (one line), LF alone, Ctrl-C (`^C\r\n` + cancel), control bytes
ignored, tab accepted.

## 5. Step 11 — tokenizer (`tokenizer.zig`)

Fixed total token count `max_tokens = monitor.max_args_limit + 1` (17):
the command name plus up to 16 arguments. Explicit rules:

- Split on space/tab; leading, trailing, and multiple spaces collapse.
- A `"` at the **start of an argument** opens a quoted region; the closing
  `"` ends it, and everything between (including spaces) is one argument.
  A `"` inside an unquoted token is a literal byte (documented rule).
- `""` yields an empty argument.
- **Unbalanced quote** (open `"` to end of line): the rest of the line is
  taken as a literal argument and `unbalanced_quote` is set; the shell
  prints `unterminated quote: rest of line treated as literal` and still
  executes (documented "unclosed literal" choice).
- **Too many tokens** (an 18th token would be needed): stop at
  `max_tokens`, set `too_many`; the shell prints
  `too many arguments; type 'help' for a list of commands` and does **not**
  execute.

**Observable evidence (zig test, `tokenizer.zig`):** `echo "elephant
business"` → `["echo", "elephant business"]`; unquoted, mixed
(`a"b c` literal), empty quotes, `1`/`2`/`3`-space runs, leading/trailing
spaces, tab, unbalanced `echo "abc` → `["echo","abc"]` + flag, 17 tokens
OK, 18 tokens → `too_many`.

## 6. Shell loop (`shell.zig`)

```zig
pub const Shell = struct {
    mon: monitor.Monitor, editor: lineedit.LineEditor, prompt_shown: bool,
    pub fn init(con, state, machine) Shell;
    pub fn boot(self: *Shell) void;          // monitor.banner
    pub fn poll(self: *Shell) PollResult;    // idle | pending | processed
};
```

`poll` prints `dipshit> ` once per line, feeds one byte through the
editor, and on submit: prints the overflow notice if `rejected`, then
tokenizes + executes via `monitor.exec`. `bootAndPark(mon, rx_wired)`:
`banner()` → if RX wired run the loop forever (never returns) → else print
`dipshit> ` and return so `main.zig` parks in WFE (never spins hot). The
idle wait between polls is `wfe` under a comptime aarch64 guard, so the
module stays host-testable on x86_64 CI. Coverage note (reviewed,
accepted): `boot_and_park`'s `rx_wired = true` branch (the infinite
loop + WFE idle) is not itself unit-tested — it is dormant until the VZ
serial gate passes, and loop correctness is proven by the mock-fed
`poll`-driven e2e test, which drives the exact same prompt/read/tokenize/
exec path.

**Observable evidence (zig test, `shell.zig` — mock-fed end-to-end):**
feed `help\nversion\nmem\necho "elephant business"\n<256×'a'>\n<ctrl-c>\n`
through the mock input queue, drive `poll` until `.idle`, and assert the
exact transcript (below). Transcript is the loop proof: prompt per line,
command results, overflow/cancel behavior.

### 6.1 Expected transcript (exact)

```
DipshitOS - AArch64 firmware-assisted kernel monitor
DipshitOS: memory is a map, not a territory.
Type 'help' before touching anything expensive.
dipshit> help
available commands:
  about     explain this questionable system
  beans     count beans, probably
  clear     clean up the crime scene
  echo      repeat your regrettable decisions
  elephant  operational mascot diagnostics
  handoff   display boot-to-kernel ABI data
  help      list commands and their help text
  hex       format an integer in hexadecimal
  mem       summarize the EFI memory map
  reboot    restart the machine
  repeat    repeat text, safely bounded
  shutdown  request power-off
  uname     compact system identity
  version   display build information
type 'help <command>' for details on a single command.
dipshit> version
dipshit-kernel
milestone-two kernel proper (ADR 0004)
handoff ABI v2
build label: m1.5 commands & personality (mock console)
dipshit> mem
mem: descriptors=0x0000000000000006 size=0x0000000000000028 version=0x0000000000000002 key=0x0000000000000042
  usable: 0x0000000000480000 bytes (0x0000000000000480 pages)
  conventional: 0x00000000003c0000 bytes (0x00000000000003c0 pages)
  loader: 0x0000000000040000 bytes (0x0000000000000040 pages)
  boot_services: 0x0000000000080000 bytes (0x0000000000000080 pages)
  runtime: 0x0000000000008000 bytes (0x0000000000000008 pages)
  reserved: 0x0000000000009000 bytes (0x0000000000000009 pages)
  mmio: 0x0000000000010000 bytes (0x0000000000000010 pages)
  kernel: 0x000000007e4df000..0x000000007e5613e8 (0x00000000000823e8 bytes)
dipshit> echo "elephant business"
elephant business
dipshit> aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
unknown command: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
type 'help' for a list of commands
dipshit> ^C
dipshit>
no command given; type 'help' for a list of commands
dipshit>
```

(Line terminators inside the typed lines are `\r\n` — the editor echoes
CRLF on submit; the monitor's own output lines are `\n`. The 256-char
line is a single unknown token, exercising the exact boundary. The script
ends `<ctrl-c>\n`: the Enter that follows the cancel submits an empty
line, which the registry answers with its no-command message, then a fresh
prompt — the asserted transcript includes that tail.)

## 7. The `main.zig` seam (the only `main.zig` change)

After the existing `uart_puts("kernel terminal state\n")`:

1. imports: `console`, `memmap`, `monitor`, `shell` (top of file);
2. an additive file-scope `M15Console` adapter: `write`/`flush` over
   `uart_puts`/no-op, `readByte` returns `null` and `rxWired()` returns
   `false` — both tagged `[inferred]`, gated on claim 0002, no device
   register touched;
3. construct `memmap.MapView` over the captured map buffer, `Monitor` with
   `.handoff = @bitCast(handoff.*)`, `.map = view`, `.console_name` from
   `layout_name(console_kind)` (minus the trailing newline),
   `MachineControl.disabled()`;
4. `shell.bootAndPark(&mon, m15.rxWired())`;
5. `halt_forever()` unchanged.

Nothing in ExitBootServices/MMU/probe/`uart_*` is modified — `git diff`
on `kernel/src/main.zig` shows only the seam. At boot today `rxWired()`
is false, so the kernel prints banner + `dipshit> ` and parks — it never
spins hot, and it never reads a real device register.

## 8. Verification gates and their evidence (all local, CI-independent)

| Gate | Command | Evidence file |
|------|---------|---------------|
| 1 format | `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig` | `artifacts/m15-shell-core-fmt.txt` |
| 2 build | `zig build` | `artifacts/m15-shell-core-build.txt` |
| 3 unit tests | `bash tools/verify-unit-tests.sh` (all 7 kernel modules) | `artifacts/m15-shell-core-tests.txt` |
| 4 mock-fed loop | the `shell.zig` e2e test, run and saved | `artifacts/m15-shell-core-loop.txt` |
| 5 seam diff | `git diff kernel/src/main.zig` reviewed | `artifacts/m15-shell-core-diff.txt` |
| 6 coordination | `bash tools/verify-coordination.sh` | `artifacts/m15-shell-core-coord.txt` |
| 7 docs | steps 9–11 flipped + changelog + claim closed in `docs/status.md` | — |

## 9. Do-nots honored

- Takeover path in `main.zig` untouched (gate 5 checks it).
- No allocator, interrupts, timers, storage drivers, libc/POSIX.
- Command registry/`banner()`/`monitor.zig` commands reused as-is; no
  rebuild of the registry.
- No live MMIO RX implementation — `readByte` stubs are `[inferred]`,
  gated on claim 0002, and no end-to-end keystroke→command claim is made
  (host keystrokes reaching the attachment was agent A's proof; guest
  receipt needs this slice *plus* the serial gate).
