#!/usr/bin/env python3
"""A TLS 1.3 responder for the in-tree client's consumer interop.

The matrix in run_interop.sh pairs the client with OpenSSL, GnuTLS and Go. This
is the fourth kind of peer: Python's `ssl` module, i.e. a completely different
binding over a different OpenSSL build. It exists because the *consumer* path
needs a peer that serves the exact fixture identity the guest expects
(`leaf.example.com`, issued by the test intermediate to the vendored root), and
because a class-B gate will need a runner-side responder speaking TLS 1.3 with
a bounded, scriptable lifetime.

TLS 1.3 only, on purpose: the client implements nothing older, so a downgrade
must be impossible rather than merely unlikely. `--accept` counts *attempts*,
not successes, so a negative case (where the client aborts mid-handshake) still
terminates the loop instead of hanging the runner.
"""
import argparse
import socket
import ssl
import sys
import time


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--cert", required=True, help="PEM chain, leaf first")
    ap.add_argument("--key", required=True)
    ap.add_argument("--body", default="consumer-interop-ok\n")
    ap.add_argument("--accept", type=int, default=1, help="attempts before exit")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--timeout", type=float, default=30.0,
                    help="hard deadline, so a lost peer cannot hang a runner")
    a = ap.parse_args()

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.maximum_version = ssl.TLSVersion.TLSv1_3
    try:
        ctx.load_cert_chain(a.cert, a.key)
    except Exception as e:  # noqa: BLE001 - surface the reason, not a traceback
        sys.stderr.write("responder: cannot load %s: %s\n" % (a.cert, e))
        return 2

    ls = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    ls.bind((a.host, a.port))
    ls.listen(8)
    sys.stdout.write("responder: listening on %s:%d\n" % (a.host, a.port))
    sys.stdout.flush()

    attempts = 0
    deadline = time.monotonic() + a.timeout
    while attempts < a.accept:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            sys.stdout.write("responder: deadline reached, exiting\n")
            sys.stdout.flush()
            break
        ls.settimeout(remaining)
        attempts += 1
        try:
            raw, _ = ls.accept()
        except socket.timeout:
            sys.stdout.write("responder: accept timed out\n")
            sys.stdout.flush()
            break
        try:
            with ctx.wrap_socket(raw, server_side=True) as s:
                req = b""
                while b"\r\n\r\n" not in req and len(req) < 8192:
                    chunk = s.recv(4096)
                    if not chunk:
                        break
                    req += chunk
                body = a.body.encode()
                s.sendall(
                    b"HTTP/1.0 200 OK\r\nContent-Length: %d\r\n"
                    b"Connection: close\r\n\r\n" % len(body) + body
                )
                ver = s.version()
                cs = s.cipher()
                sys.stdout.write("responder: served %s %s: %s\n" % (
                    ver, cs[0] if cs else "?", req.split(b"\r\n")[0].decode("latin1")))
                sys.stdout.flush()
        except (ssl.SSLError, OSError) as e:
            # Expected on a negative case: the client aborts during or after
            # the handshake, which is the behaviour under test.
            sys.stdout.write("responder: refused: %s\n" % e)
            sys.stdout.flush()
        finally:
            try:
                raw.close()
            except OSError:
                pass
    ls.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
