# exec-order guard fixtures (claim #1193)

Not gates. `tools/gate/fleet.sh` discovers `tools/gate/specs/*.spec`, so nothing
here enters the fleet, the inventory, CI shards, or any `just gate` recipe —
these files are parsed as text and never executed.

They are the self-test for the spec-order guard in `tools/inventory-gates.sh`,
which `--check` runs on every invocation (`just verify-portable` calls it). A
guard that silently stops matching its shape is worse than no guard, so the
fixtures pin both directions:

| dir | fixture | asserted verdict |
|---|---|---|
| `fail/` | `ungated-echo-end.spec` | run launches a program, ends on a script-supplied marker, no stage gate → violation |
| `fail/` | `exec-then-vf.spec` | a `vf` file-channel op follows an `exec` in one script → violation |
| `fail/` | `bad-class.spec` | `# exec-order:` class that is not one of the four → hard failure |
| `pass/` | `declared-assert-proven.spec` | the same shape, declared → no violation, declaration echoed |
| `pass/` | `declared-self-sequenced.spec` | the same shape, declared → no violation, declaration echoed |
| `pass/` | `no-exec.spec` | run ends on a script marker but launches nothing → no declaration needed |
| `pass/` | `staged.spec` | program launched, run held by `--script2-after` on a guest marker → no declaration needed |

The two `fail/` shapes are not hypothetical: `exec-then-vf.spec` is the bug that
landed in `live-oliver` (#1188), and `ungated-echo-end.spec` is the shape
`go-hello.spec` and `live-jobs.spec` carry (both declare it — see the class list
in `tools/gate/SPEC.md`).

Run one direction by hand with the guard's directory argument:

```bash
bash -c 'ROOT=$PWD; eval "$(awk "/^check_spec_order\(\)/,/^}$/" tools/inventory-gates.sh)";
         check_spec_order "$ROOT/tools/gate/fixtures/exec-order/fail"'
```
