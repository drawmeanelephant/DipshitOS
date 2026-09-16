# go-git.spec -- issue #1337: GOTGIT.ELF clones a tiny fixture repo over
# HTTPS via FETCHS.BIN (ADR 0029 git-over-https half).
#
# Smart HTTP against a real `git http-backend` on the host, TLS 1.3 only,
# the Zig helper owns the socket. Never a cleartext GET. Kernel untouched.
# Proves a known blob/tree/commit lands on the guest share.
#
# HOST PREREQUISITE: bash tools/go/build-gogit.sh -> .build/go/GOTGIT.ELF
# plus `git` on PATH. FETCHS.BIN comes from `zig build` (the harness).
#
# exec-order: assert-proven -- the run ends on `gotgit OK`, which only the
# program prints after objects and HELLO are on the share.

vgate_name go-git "issue #1337: GOTGIT.ELF clones over TLS via FETCHS.BIN from git http-backend"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOTGIT.ELF clone https://10.0.0.2:24541/g.git /host/G
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys, time

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)
# A previous failed run can leave a TLS listener on 24541; FETCHS then
# handshakes with a half-dead peer and gets AlertReceived.
subprocess.run(["sh", "-c", "lsof -ti tcp:24541 | xargs kill -9"],
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.2)

gogit = os.path.join(".build", "go", "GOTGIT.ELF")
if not os.path.exists(gogit):
    sys.exit("GOTGIT.ELF missing (expected " + gogit + ") - build it first: "
             "bash tools/go/build-gogit.sh")
fetchs = os.path.join("zig-out", "bin", "FETCHS.BIN")
if not os.path.exists(fetchs):
    sys.exit("FETCHS.BIN missing at %s -- run 'zig build' first" % fetchs)
shutil.copy(gogit, os.path.join(share, "GOTGIT.ELF"))
shutil.copy(fetchs, os.path.join(share, "FETCHS.BIN"))

git = shutil.which("git")
if not git:
    sys.exit("git not on PATH; go-git needs a real git http-backend")

root = os.path.join(run, "gitroot")
work = os.path.join(run, "work")
os.makedirs(root, exist_ok=True)
os.makedirs(work, exist_ok=True)
env = os.environ.copy()
env.update({
    "GIT_AUTHOR_NAME": "g",
    "GIT_AUTHOR_EMAIL": "g@g",
    "GIT_AUTHOR_DATE": "1000000000 +0000",
    "GIT_COMMITTER_NAME": "g",
    "GIT_COMMITTER_EMAIL": "g@g",
    "GIT_COMMITTER_DATE": "1000000000 +0000",
})
def g(*args, cwd=None):
    subprocess.check_call([git, "-c", "init.defaultBranch=main"] + list(args), cwd=cwd, env=env)

g("init", "-q", cwd=work)
open(os.path.join(work, "HELLO"), "w").write("hello, git\n")
g("add", "HELLO", cwd=work)
g("commit", "-q", "-m", "first", cwd=work)
open(os.path.join(work, "HELLO"), "w").write("hello, git!\n")
g("add", "HELLO", cwd=work)
g("commit", "-q", "-m", "second", cwd=work)
bare = os.path.join(root, "g.git")
g("clone", "-q", "--bare", work, bare)
g("--git-dir", bare, "config", "http.uploadpack", "true")
g("--git-dir", bare, "-c", "pack.window=50", "-c", "pack.depth=50",
  "repack", "-a", "-d", "-q")

cfx = os.path.join("user", "src", "lib", "tls", "vectors", "fx")
chain = os.path.join(cfx, "chain-ec.pem")
key = os.path.join(cfx, "leaf-ec.key")
if not os.path.exists(chain):
    sys.exit("pinned fixture chain missing at %s" % chain)

wrapper = os.path.join(run, "git-https.py")
open(wrapper, "w").write(r'''
import os, socket, ssl, subprocess, sys, time

host, port = "127.0.0.1", 24541
cert, keyp = sys.argv[1], sys.argv[2]
gitroot = sys.argv[3]
gitbin = sys.argv[4]
accept_n, timeout = 2, 600.0

ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.minimum_version = ssl.TLSVersion.TLSv1_3
ctx.maximum_version = ssl.TLSVersion.TLSv1_3
ctx.load_cert_chain(cert, keyp)
ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
ls.bind((host, port))
ls.listen(8)
sys.stdout.write("git-https: listening on %s:%d\n" % (host, port))
sys.stdout.flush()
deadline = time.monotonic() + timeout
n = 0
while n < accept_n:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        sys.stdout.write("git-https: deadline\n")
        sys.stdout.flush()
        break
    ls.settimeout(remaining)
    n += 1
    try:
        raw, _ = ls.accept()
    except socket.timeout:
        sys.stdout.write("git-https: accept timed out\n")
        sys.stdout.flush()
        break
    try:
        with ctx.wrap_socket(raw, server_side=True) as s:
            req = b""
            while b"\r\n\r\n" not in req and len(req) < 16384:
                chunk = s.recv(4096)
                if not chunk:
                    break
                req += chunk
            head, _, rest = req.partition(b"\r\n\r\n")
            lines = head.split(b"\r\n")
            reqline = lines[0].decode("latin1") if lines else ""
            parts = reqline.split(" ")
            method = parts[0] if parts else "GET"
            target = parts[1] if len(parts) > 1 else "/"
            headers = {}
            for ln in lines[1:]:
                if b":" in ln:
                    k, v = ln.split(b":", 1)
                    headers[k.decode("latin1").lower()] = v.strip().decode("latin1")
            body = rest
            need = int(headers.get("content-length", "0") or "0")
            while len(body) < need:
                chunk = s.recv(need - len(body))
                if not chunk:
                    break
                body += chunk
            path, _, qs = target.partition("?")
            env = os.environ.copy()
            env["GATEWAY_INTERFACE"] = "CGI/1.1"
            env["GIT_PROJECT_ROOT"] = gitroot
            env["GIT_HTTP_EXPORT_ALL"] = "1"
            env["REQUEST_METHOD"] = method
            env["PATH_INFO"] = path
            env["QUERY_STRING"] = qs
            env["CONTENT_TYPE"] = headers.get("content-type", "")
            env["CONTENT_LENGTH"] = str(len(body))
            env["REMOTE_ADDR"] = "127.0.0.1"
            p = subprocess.run([gitbin, "http-backend"], input=body, capture_output=True, env=env)
            cgi = p.stdout
            if p.returncode != 0:
                sys.stdout.write("git-https: backend rc=%d stderr=%s\n" % (p.returncode, p.stderr[:200]))
                sys.stdout.flush()
            sep = b"\r\n\r\n" if b"\r\n\r\n" in cgi else b"\n\n"
            cgi_h, _, cgi_b = cgi.partition(sep)
            status = "200 OK"
            out_h = []
            for ln in cgi_h.splitlines():
                if ln.lower().startswith(b"status:"):
                    status = ln.split(b":", 1)[1].strip().decode("latin1")
                elif ln:
                    out_h.append(ln)
            resp = b"HTTP/1.0 " + status.encode("latin1") + b"\r\n"
            for ln in out_h:
                resp += ln + b"\r\n"
            resp += b"Content-Length: %d\r\nConnection: close\r\n\r\n" % len(cgi_b)
            resp += cgi_b
            s.sendall(resp)
            sys.stdout.write("git-https: served %s\n" % reqline)
            sys.stdout.flush()
    except (ssl.SSLError, OSError) as e:
        sys.stdout.write("git-https: refused: %s\n" % e)
        sys.stdout.flush()
    finally:
        try:
            raw.close()
        except OSError:
            pass
ls.close()
''')
log = open(os.path.join(run, "git-https.log"), "wb")
proc = subprocess.Popen(
    [sys.executable, wrapper, chain, key, root, git],
    stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
time.sleep(0.2)
print("go-git: staged GOTGIT.ELF (%d) FETCHS.BIN (%d); git-https pid=%d" % (
    os.path.getsize(os.path.join(share, "GOTGIT.ELF")),
    os.path.getsize(os.path.join(share, "FETCHS.BIN")), proc.pid))
PY

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:24541:relay --net-tcp-respond-relay 127.0.0.1:24541 \
    --script '$RUN_DIR/script.txt' --script-expect 'gotgit OK' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded GOTGIT.ELF'
vgate_assert 01 serial-contains 'gotgit: start'
vgate_assert 01 serial-contains 'gotgit: url https://10.0.0.2:24541/g.git'
vgate_assert 01 serial-contains 'gotgit: helper FETCHS.BIN 10.0.0.2 24541 leaf.example.com GET'
vgate_assert 01 serial-contains 'fetchs: handshake ok'
vgate_assert 01 serial-contains 'fetchs: method GET'
vgate_assert 01 serial-contains 'fetchs: method POST'
vgate_assert 01 serial-contains 'gotgit: refs '
vgate_assert 01 serial-contains 'gotgit: want '
vgate_assert 01 serial-contains 'gotgit: pack objects='
vgate_assert 01 serial-contains 'gotgit: blob '
vgate_assert 01 serial-contains 'gotgit: tree '
vgate_assert 01 serial-contains 'gotgit: commit '
vgate_assert 01 serial-contains 'gotgit: checkout HELLO'
vgate_assert 01 serial-contains 'gotgit OK'
vgate_assert 01 serial-absent 'gotgit: error'
vgate_assert 01 serial-absent 'GET / HTTP'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 python <<'PY'
import os, zlib
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
hello_path = os.path.join(share, "G", "HELLO")
hello = open(hello_path, "rb").read()
assert hello == b"hello, git!\n", "HELLO = %r" % hello
objroot = os.path.join(share, "G", ".git", "objects")
found = {"blob": 0, "tree": 0, "commit": 0}
saw_hello = False
for d in sorted(os.listdir(objroot)):
    dp = os.path.join(objroot, d)
    if not os.path.isdir(dp) or len(d) != 2:
        continue
    for fn in os.listdir(dp):
        raw = open(os.path.join(dp, fn), "rb").read()
        data = zlib.decompress(raw)
        for kind in found:
            if data.startswith(kind.encode() + b" "):
                found[kind] += 1
        if data.startswith(b"blob ") and b"hello, git!\n" in data:
            saw_hello = True
assert found["blob"] >= 1 and found["tree"] >= 1 and found["commit"] >= 1, found
assert saw_hello, "known blob content missing from object store"
print("go-git objects on disk: %s HELLO=%r" % (found, hello))
PY
