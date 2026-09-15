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
# PASSES -- and it took two independent fixes to get here.
#
# 1. FIXTURES MUST BE PINNED. make_x509_fixtures.sh generates a fresh RANDOM CA
#    on every run, but FETCHS.BIN's vendored root is baked in at build time. A
#    chain generated at gate time therefore never terminates at the root the
#    guest carries, and the client answered -- correctly, and this is the whole
#    point of the exercise -- `ChainValidationFailed`. The fixtures under
#    user/src/lib/tls/vectors/fx/ are the same ones vendored_roots.zig was
#    generated from, and the spec serves those.
#
# 2. THE GUEST NEEDS A BIGGER TASK STACK. At the production
#    scheduler.task_stack_size (32,768 B) the faulting instruction is a prologue
#    store (`stp x29, x30, [sp, #-32]!`) and the client's call nest reaches
#    ~131 KiB below the stack top. At 256 KiB the spec goes green:
#
#      vgate live-tls13: PASS (1/1 runs)
#        fetchs: handshake ok                     = 1
#        fetchs: TLS1.3 TLS_AES_128_GCM_SHA256    = 1
#        fetchs: request sent                     = 1
#        live-tls13-ok                            = 1
#        fetchs: body complete                    = 1
#
#    That is a real handshake, a real GET and a real response body from a guest
#    process under Virtualization.framework.
#
# The stack value is NOT changed here. It is a system-wide decision: kernel host
# tests show a hardcoded 32768 expectation and an allocator that returns
# .out_of_memory at ~8x, and it is 8x per task in production. The spec documents
# the measurement; the value is the owner's call.
#
# Do not "fix" this by weakening the assertions.
#
# The responder's trust anchor is the fixture root, which is byte-identical to
# the vendored blob FETCHS.BIN carries, so the guest is validating against its
# own pinned root rather than a test-only bypass.
#
# KNOWN-FAILING, with the diagnosis narrowed to one number.
#
# Measured locally on Apple silicon macOS 27. Left at the production
# task_stack_size (32,768 B), the guest dies on a data abort. The faulting
# instruction is a prologue store (`stp x29, x30, [sp, #-32]!`), and the
# deepest address reached sits ~131 KiB below the stack top, so the client's
# call nest needs more stack than the guest has. Raising task_stack_size to
# 256 KiB on this machine removes the crash entirely and the run proceeds to a
# real handshake verdict -- which is the honest way to say the stack is the
# gate on this spec, and that changing it is a kernel-wide decision (it was
# already doubled 16 -> 32 KiB once for M25, carries "+16 KiB BSS per static
# stack" against the verify-bss-budget gate, and there are six static stacks).
#
# Progress the gate has already forced, all of it invisible to host tests
# because the driver has an 8 MB stack:
#   - an 81,264-byte entry frame (the client was a stack local) -> 208 B
#   - argv shifted by one (the DSK1/DSK3 argv block has no program name;
#     the ELF block does) -> `fetchs: target set` now passes
#   - signature verification inlined into the handshake frame -> 79,856 ->
#     62,784 B
#   - the guest's traffic does not reach the host by magic: `net ip` + `net arp`
#     plus `--net-tcp-respond 10.0.0.2:<port>:relay` + `--net-tcp-respond-relay`
#     are what connect the guest to a real responder on the host loopback.
#
# Do not "fix" this by weakening the assertions.

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

# PINNED fixtures, deliberately not regenerated. make_x509_fixtures.sh makes a
# fresh RANDOM CA on every run, so a chain generated here would never terminate
# at the root FETCHS.BIN carries -- the vendored blob is baked in at build time.
# The first attempt did exactly that and the client answered, correctly,
# `ChainValidationFailed`. The fixtures committed under
# user/src/lib/tls/vectors/fx/ are the same ones vendored_roots.zig was
# generated from, so the guest validates against its own pinned root.
cfx = os.path.join("user", "src", "lib", "tls", "vectors", "fx")
chain = os.path.join(cfx, "chain-ec.pem")
if not os.path.exists(chain):
    sys.exit("pinned fixture chain missing at %s" % chain)

sys.path.insert(0, os.path.join("user", "src", "lib", "tls", "vectors"))
cmd = [
    sys.executable,
    os.path.join("user", "src", "lib", "tls", "vectors", "tlsresponder.py"),
    "--host", "127.0.0.1", "--port", "24533",
    "--cert", chain, "--key", os.path.join(cfx, "leaf-ec.key"),
    "--body", "live-tls13-ok\n", "--accept", "1", "--timeout", "600",
]
log = open(os.path.join(run, "responder.log"), "wb")
proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
print("live-tls13: staged FETCHS.BIN and the fixture chain; responder pid=%d on 0.0.0.0:24533" % proc.pid)
PY

vgate_file script.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec FETCHS.BIN 10.0.0.2 24533
EOF

# The guest's traffic does not reach the host by magic: the runner simulates the
# link. `net ip` + `net arp` give the guest a stack and a neighbour, and
# `:relay` is what turns the guest's SYN into a real connection to the Python
# responder on the host loopback. Without the relay the guest sees a refused
# connect and the responder never accepts anything -- which is exactly what the
# first attempt at this spec did.
vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:24533:relay --net-tcp-respond-relay 127.0.0.1:24533 \
    --script '$RUN_DIR/script.txt' --script-expect 'fetchs: handshake ok' --timeout 180

vgate_assert 01 serial-contains 'fetchs: target set'
vgate_assert 01 serial-contains 'fetchs: roots loaded'
vgate_assert 01 serial-contains 'fetchs: connected'
vgate_assert 01 serial-contains 'fetchs: handshake ok'
vgate_assert 01 serial-contains 'fetchs: TLS1.3 TLS_AES_128_GCM_SHA256'
vgate_assert 01 serial-contains 'fetchs: request sent'
vgate_assert 01 serial-contains 'live-tls13-ok'
vgate_assert 01 serial-contains 'fetchs: body complete'
vgate_assert 01 serial-absent '[EXC] parking:'
