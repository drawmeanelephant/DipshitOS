# vgate spec format (FROZEN at M40 GF2 close)

A spec **declares**; `tools/gate/vgate.sh` **executes**. A spec is bash that
may use *only* the `vgate_*` commands below (anything else fails the run).
History, claim numbers, and mechanism prose live in git/issues — a spec
header is WHAT + WHY in ≤15 lines.

```
vgate_name NAME [DESCRIPTION]      # required; evidence files are NAME-*
vgate_share none|arm|seed          # default none (gate-run.sh arm/seed)
vgate_fmt PATH...                  # default: boot/src/*.zig kernel/src/*.zig
                                   #   user/src/*.zig build.zig
vgate_runner_flags FLAGS...        # extra swift build flags (e.g. -Xswiftc -DSPIKE)
vgate_repeat N [ENV]               # run every vgate_run N times (default 1);
                                   # with ENV, use $ENV when set (e.g. BOOTS)
vgate_note TEXT                    # report line (repeatable)
vgate_file NAME <<'EOF'            # write NAME into $RUN_DIR (repeatable,
...                                #   in order; contents are literal)
EOF
vgate_setup_python <<'PY'          # python3 hook, $RUN_DIR env (repeatable,
...                                #   in order; nonzero exit fails the gate)
PY
vgate_run TAG -- FLAGS...          # one boot; FLAGS pass through verbatim
                                   # to VMRunner after the harness-owned
                                   # --serial/--overlay-base/--vars/--cvc-file
vgate_allow_rc TAG RC...           # allowed VMRunner exit codes for TAG (default 0;
                                   # e.g. 1 for death-asserting gates like reboot)
vgate_assert TAG KIND [args]       # all asserts of a TAG must hold, plus
                                   # runner rc in allowed set; failing assert = failed run
```

Assert KINDs (serial = the run's `vm-serial.log` copy; output = runner stdout):

| KIND | args | holds when |
|---|---|---|
| `serial-contains` | STR | STR occurs in serial (fixed-string) |
| `serial-contains-file` | FILE | contents of `$RUN_DIR/FILE` occur in serial (generated fixtures) |
| `serial-count` | STR MIN | STR occurs ≥ MIN times |
| `serial-exact` | STR N | STR matches exactly N whole lines (mirrors `grep -aFxc`; a command echo and its output are different lines) |
| `serial-absent` | STR | STR never occurs (e.g. `[EXC] parking:`) |
| `serial-echo` | CMD | `gate_serial_has_echo` accepts CMD (colored-or-plain prompt echo) |
| `output-contains` | STR | STR occurs in runner stdout (e.g. `input-string: ENABLED`) |
| `capture-equals` | FILE FIXTURE | `$RUN_DIR/FILE` is byte-equal to `$RUN_DIR/FIXTURE` (5×0.5 s retry; copied to evidence) |
| `capture-empty` | FILE | `$RUN_DIR/FILE` missing or zero-length |
| `snapshot` | GLOB + python on stdin | newest `$RUN_DIR/GLOB` exists and the python (path as `sys.argv[1]`, `sys.exit(str)` fails) passes; snapshot copied to evidence |
| `python` | python on stdin | hook passes (`$RUN_DIR`/`$VG_SER`/`$VG_TAG`/`$VG_SHARE` env; nonzero exit fails) |

Rules:

- Assert values are **literal** — no expansion. Files a hook needs go
  through `vgate_file`/`vgate_setup_python` (`$RUN_DIR` env) or the
  `FILE`/`FIXTURE` operands (resolved under `$RUN_DIR`).
- The one exception is `vgate_run` FLAGS: a literal `$RUN_DIR` (or
  `${RUN_DIR}`) token there expands to the run dir at execution, so specs
  can name their `vgate_file` outputs (`--script $RUN_DIR/script.txt`).
- `vgate_file` bodies are newline-terminated files by contract (the
  harness re-appends the single trailing newline `$(cat)` strips — a
  missing terminator glues the last script line to the next forwarded
  chunk and the guest executes them as one line).
- Runner flags are **passthrough** — the harness never enumerates the
  VMRunner surface, so new runner knobs need no harness change.
- Evidence per run: `artifacts/NAME-serial-TAG.log`,
  `artifacts/NAME-run-TAG.txt`, `artifacts/NAME-report.txt`, referenced
  captures/snapshots, all `VIRELAI_GATE_SUFFIX`-aware.
- `VGATE_NO_BUILD=1` skips the build preamble (dev iteration only).
  It is only valid when the already-built runner matches the spec's
  `vgate_runner_flags` (plain vs `-DSPIKE`): a stale-variant binary fails
  with the runner's SPIKE error, not a gate failure.
- Extending this file (new KINDs, new commands) is a spec-format change:
  it needs its own issue and a pilot proving it. GF3/GF4 add specs only.
