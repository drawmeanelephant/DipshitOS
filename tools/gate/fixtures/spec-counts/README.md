# syscall-count guard fixtures (issue #1345)

Not gates. `tools/gate/fleet.sh` discovers `tools/gate/specs/*.spec`, so nothing
here enters the fleet, the inventory, CI shards, or any `just gate` recipe —
these files are parsed as text and never executed.

They are the self-test for the syscall-count guard in
`tools/inventory-gates.sh`, which `--check` runs on every invocation (`just
verify-portable` calls it). A guard that silently stops matching its shape is
worse than no guard, so the fixtures pin both directions:

| dir | fixture | asserted verdict |
|---|---|---|
| `fail/` | `pinned-count.spec` | an assert carries the literal `implemented=68` → violation |
| `pass/` | `shape-count.spec` | the report's shape plus its slot row, with the same literal only in a comment → no violation |

The `fail/` shape is not hypothetical: six fleet specs carried exactly it
(`live-win-syscall`, `live-win-close`, `live-net-udp-syscall`,
`live-sound-control`, `live-win-move`, `live-wmctl-register`) while
`kernel/src/syscall.zig` reported `implemented=76`, so all six were red at HEAD.
Nothing noticed, because the `vz-gates.yml` shards skip when no Apple-silicon
runner is registered under `VZ_RUNNER_LABEL` and a skipped shard concludes
`success` just like one that ran the fleet.

Run one direction by hand with the guard's directory argument:

```bash
bash -c 'ROOT=$PWD; eval "$(awk "/^check_spec_counts\(\)/,/^}$/" tools/inventory-gates.sh)";
         check_spec_counts "$ROOT/tools/gate/fixtures/spec-counts/fail"'
```
