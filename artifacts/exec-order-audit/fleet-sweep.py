#!/usr/bin/env python3
"""Fleet sweep for exec-ordering shapes (claim #1193).

Reproduces the numbers in fleet-sweep.txt. Parses with the same rules as
`check_spec_order` in tools/inventory-gates.sh: heredoc bodies by name, logical
`vgate_run` lines (backslash continuations joined), flag values in all three
spellings.

  python3 artifacts/exec-order-audit/fleet-sweep.py "$PWD"
"""
import os
import re
import sys

root = sys.argv[1] if len(sys.argv) > 1 else "."
spec_dir = os.path.join(root, "tools/gate/specs")

FILE_RE = re.compile(r"^vgate_file\s+(\S+)\s+<<'([A-Z]+)'\s*$")
RUN_RE = re.compile(r"^vgate_run\s+(\S+)\s+--\s*(.*)$")
STAGE_FLAGS = ("--script-after", "--script2-after", "--script3-after",
               "--input-string-after")
EXEC_RE = re.compile(r"^\s*(?:strace\s+)?exec\s")
VF_RE = re.compile(r"^\s*vf\s+(ls|cat|rm|mv|mkdir|clone|open|close|write|truncate|fsync)\b")


def scan(path):
    raw = open(path, encoding="utf-8", errors="replace").read().split("\n")
    bodies, runs, pending = {}, [], ""
    i = 0
    while i < len(raw):
        line = raw[i]
        m = FILE_RE.match(line)
        if m:
            name, term = m.group(1), m.group(2)
            body = []
            i += 1
            while i < len(raw) and raw[i].strip() != term:
                body.append(raw[i])
                i += 1
            bodies[name] = body
            i += 1
            continue
        if line.rstrip().endswith("\\"):
            pending += line.rstrip()[:-1]
        else:
            logical = pending + line
            pending = ""
            r = RUN_RE.match(logical)
            if r:
                runs.append((r.group(1), r.group(2)))
        i += 1
    return bodies, runs


def script_names(flags):
    return re.findall(r"--script\S*\s+'?\$RUN_DIR/([^'\s]+)'?", flags)


def quote_arg(flags, name):
    pat = re.compile(re.escape(name) + r"\s+(?:'([^']*)'|\"([^\"]*)\"|(\S+))")
    return [a or b or c for a, b, c in pat.findall(flags)]


def has_exec(body):
    return any(EXEC_RE.match(x) for x in body)


def supplied_by_script(body, marker):
    return any(marker in x for x in body)


def main():
    specs = sorted(f for f in os.listdir(spec_dir) if f.endswith(".spec"))
    launches, runs_exec = 0, 0
    buckets = {"no-expect (timeout-ordered)": 0,
               "anchor gate, ends on script marker": 0,
               "ends on script marker, unanchored": 0,
               "ends on program marker (graded)": 0}
    flagged, file_op_after, multi_exec = [], [], {}
    for fname in specs:
        bodies, runs = scan(os.path.join(spec_dir, fname))
        if any(has_exec(b) for b in bodies.values()):
            launches += 1
        for name, body in bodies.items():
            n = sum(1 for x in body if EXEC_RE.match(x))
            if n > 1:
                multi_exec[(fname, name)] = n
            seen = False
            for line in body:
                if EXEC_RE.match(line):
                    seen = True
                elif seen and VF_RE.match(line):
                    file_op_after.append((fname, name, line.strip()))
        for tag, flags in runs:
            here = [bodies[s] for s in script_names(flags) if s in bodies]
            if not any(has_exec(b) for b in here):
                continue
            runs_exec += 1
            markers = quote_arg(flags, "--script-expect")
            if not markers:
                buckets["no-expect (timeout-ordered)"] += 1
                continue
            if not any(supplied_by_script(b, m) for m in markers for b in here):
                buckets["ends on program marker (graded)"] += 1
                continue
            gate_markers = [g for f in STAGE_FLAGS for g in quote_arg(flags, f)]
            if any(not supplied_by_script(b, g) for g in gate_markers for b in here):
                buckets["anchor gate, ends on script marker"] += 1
            else:
                buckets["ends on script marker, unanchored"] += 1
                flagged.append((fname, tag))

    print("specs scanned                        : %d" % len(specs))
    print("specs whose scripts launch a program : %d" % launches)
    print("runs whose scripts launch a program  : %d" % runs_exec)
    for k, v in buckets.items():
        print("   %-36s: %d" % (k, v))
    print("   (sum check %d)" % sum(buckets.values()))
    print()
    print("runs the guard flags (need a declaration): %d" % len(flagged))
    for f, t in flagged:
        print("   %-34s run %s" % (f, t))
    print()
    print("scripts launching >1 program (one boot)  : %d" % len(multi_exec))
    for (f, s), n in sorted(multi_exec.items()):
        print("   %-34s %-14s exec=%d" % (f, s, n))
    print()
    print("vf file-channel op after an exec        : %d" % len(file_op_after))
    for f, s, line in file_op_after:
        print("   %s (%s): %s" % (f, s, line))


main()
