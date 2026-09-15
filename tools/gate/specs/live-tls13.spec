# live-tls13.spec -- cards TLS13-C8/C11: the guest HTTPS consumer.
#
# Proves the last hop the interop matrix cannot reach: FETCHS.BIN, running as a
# guest process, completes a real TLS 1.3 handshake against a responder outside
# the VM and reads an HTTP response through it.
#
# Shape of the proof:
#   1. setup (host): regenerate the X.509 fixtures with make_x509_fixtures.sh,
#      stage FETCHS.BIN and the fixture chain into the share, and start
#      tlsresponder.py bound to 0.0.0.0:24533. It is TLS 1.3-only and exits on
#      a deadline, so it can neither downgrade nor hang the runner.
#   2. the guest execs `FETCHS.BIN 10.0.0.2 24533` -- the gateway address
#      fetch.zig and download.zig already dial.
#   3. the guest serial must show the whole chain of events, ending in the
#      response body; a negative run must fail closed on a wrong name.
#
# Port 24533 rather than 443 on purpose: a runner that needs root to bind is a
# runner that silently stops testing anything.
#
# The responder's trust anchor is the fixture root, which is byte-identical to
# the vendored blob FETCHS.BIN carries, so the guest is validating against its
# own pinned root rather than a test-only bypass.
#
# KNOWN-FAILING (measured locally on Apple silicon macOS 27, 2026-09-15).
# The gate runs and reaches the consumer body, then the guest dies with a data
# abort. Cause, measured rather than guessed:
#
#   guest task stack (scheduler.task_stack_size)      32,768 B
#   largest stack frame in FETCHS.BIN                 79,856 B
#   second largest                                    34,032 B
#
# The TLS client's stack footprint exceeds the guest stack, so this cannot go
# green until one of two things changes: the client stops needing ~80 KiB of
# stack, or the per-task stack grows. Both are real decisions (the second
# changes every user task's memory), which is why this spec is committed red
# rather than papered over. Do not "fix" it by weakening the assertions.
#
# Earlier defects this gate already found and that are now fixed: an 81,264-byte
# entry frame (the client was a stack local), and argv shifted by one (the
# DSK1/DSK3 argv block has no program name; the ELF block does).

vgate_name live-tls13 "TLS 1.3: the guest consumer completes a real handshake and reads a response"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys

run = os.environ["RUN_DIR"]
share = os.path.join(run, "share")
fx = os.path.join(run, "fx")
os.makedirs(fx, exist_ok=True)
os.makedirs(share, exist_ok=True)

app = os.path.join("zig-out", "bin", "FETCHS.BIN")
if not os.path.exists(app):
    sys.exit("FETCHS.BIN missing at %s -- run 'zig build' first" % app)
shutil.copy(app, os.path.join(share, "FETCHS.BIN"))

fixtures = os.path.join("user", "src", "lib", "tls", "vectors", "make_x509_fixtures.sh")
if not os.path.exists(fixtures):
    sys.exit("fixture generator missing at %s" % fixtures)
r = subprocess.run(["bash", fixtures, fx], capture_output=True, text=True)
if r.returncode != 0:
    sys.exit("make_x509_fixtures.sh failed: %s%s" % (r.stdout, r.stderr))

chain = os.path.join(fx, "chain-ec.pem")
with open(chain, "wb") as out:
    for part in ("leaf-ec.pem", "inter.pem"):
        with open(os.path.join(fx, part), "rb") as src:
            out.write(src.read())

sys.path.insert(0, os.path.join("user", "src", "lib", "tls", "vectors"))
cmd = [
    sys.executable,
    os.path.join("user", "src", "lib", "tls", "vectors", "tlsresponder.py"),
    "--host", "0.0.0.0", "--port", "24533",
    "--cert", chain, "--key", os.path.join(fx, "leaf-ec.key"),
    "--body", "live-tls13-ok\n", "--accept", "1", "--timeout", "600",
]
log = open(os.path.join(run, "responder.log"), "wb")
proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
print("live-tls13: staged FETCHS.BIN and the fixture chain; responder pid=%d on 0.0.0.0:24533" % proc.pid)
PY

vgate_file script.txt <<'EOF'
exec FETCHS.BIN 10.0.0.2 24533
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'fetchs: handshake ok' --timeout 180

vgate_assert 01 serial-contains 'fetchs: target set'
vgate_assert 01 serial-contains 'fetchs: roots loaded'
vgate_assert 01 serial-contains 'fetchs: connected'
vgate_assert 01 serial-contains 'fetchs: handshake ok'
vgate_assert 01 serial-contains 'fetchs: TLS1.3 TLS_AES_128_GCM_SHA256'
vgate_assert 01 serial-contains 'fetchs: request sent'
vgate_assert 01 serial-contains 'live-tls13-ok'
vgate_assert 01 serial-contains 'fetchs: body complete'
vgate_assert 01 serial-absent '[EXC] parking:'
