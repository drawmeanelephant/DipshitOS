# live-ls-l.spec -- long listing: permission bits, owner, sizes
# (the seeded share: KERNEL.BIN at its pinned byte size), plus the
# plain `ls` BIN row.
# Mirrors tools/verify-live-ls-l.sh (M22 D15, issue #338). The
# line-anchored EREs ride python (no trailing-\r stripping: grep $
# and python $ agree on raw splitlines). Two stimulus notes,
# assertions byte-identical: KERNEL.BIN size is shape-pinned
# (legacy's exact 11406096 rotted at 8080528 -- the claim-5069
# shape-not-count precedent), and `ls -l` runs TWICE up front (the
# image-side EFI row settles ~1 s after the prompt: probed live as
# host=0x5a then 0x5b in one boot -- same family as #965).

vgate_name live-ls-l "ls -l bits/owner/sizes on the seeded share on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_setup_python <<'PY'
import os
os.makedirs(os.path.join(os.environ["RUN_DIR"], "share", "EFI"), exist_ok=True)
PY

vgate_file script.txt <<'EOF'
ls -l
ls -l
ls
echo rx-lsl-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'rx-lsl-ok' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'root'
vgate_assert 01 serial-contains 'rx-lsl-ok'
vgate_assert 01 python <<'PY'
import os, re, sys
lines = open(os.environ["VG_SER"], errors="replace").read().splitlines()
# Legacy -qE set (line-anchored; $ is end-of-line as in grep). The
# KERNEL.BIN byte size is shape-pinned, not constant-pinned: legacy's
# exact 11406096 rotted when the kernel shrank to 8080528 (same stale
# class as implemented=61; the claim-5069 shape-not-count precedent).
for p in (r"^-rw- +1 +root$", r"^drwx +1 +root$",
          r"^ +[0-9]{3,} +[A-Z]+\.BIN$", r"^ +[0-9]{3,} +KERNEL\.BIN$",
          r"^  [A-Za-z0-9_]+\.BIN"):
    if not any(re.search(p, l) for l in lines):
        sys.exit("FAIL: ERE absent: %s" % p)
print("ls-l rows ok")
PY
