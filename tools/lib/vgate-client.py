#!/usr/bin/env python3
"""vgate-client.py -- the vgate during-run TCP client hook (M46 RC2, #1069).

Launched in the BACKGROUND by tools/gate/vgate.sh for the run tagged
$VG_TAG (see tools/gate/SPEC.md `vgate_client`). It waits for an optional
serial marker, connects to --addr with retry, sends a scripted fixture,
reads until --expect (or EOF/--timeout), writes the full capture to
$RUN_DIR/client-$VG_TAG.out, and exits 0 on success.

Environment (set by the harness): RUN_DIR, VG_TAG, VG_SER.

Exit codes: 0 success; 1 expectation/timeout/connect failure; 2 usage.
--expect-fail inverts the connect result (0 iff the connect is refused or
times out) for negative gates such as "no listener".
"""

import argparse
import os
import socket
import sys
import time


def log(msg):
    tag = os.environ.get("VG_TAG", "?")
    print(f"vgate-client[{tag}]: {msg}", flush=True)


def parse_addr(spec):
    host, sep, port = spec.rpartition(":")
    if not sep or not host or not port:
        log(f"--addr wants host:port, got {spec!r}")
        sys.exit(2)
    try:
        return host, int(port)
    except ValueError:
        log(f"--addr port is not an integer: {spec!r}")
        sys.exit(2)


def ser_text(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return b""


def wait_marker(path, marker, timeout):
    """Poll the serial log until MARKER appears (or timeout). Empty marker
    means "connect now". Returns True when satisfied."""
    if not marker:
        return True
    needle = marker.encode("utf-8", "replace")
    deadline = time.time() + timeout
    while time.time() < deadline:
        if needle in ser_text(path):
            return True
        time.sleep(0.2)
    return False


def connect(host, port, timeout):
    """Retry-connect for up to `timeout` seconds. Returns a socket or None."""
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(2.0)
        try:
            s.connect((host, port))
            s.settimeout(None)
            return s
        except OSError as e:
            last = e
            s.close()
            time.sleep(0.25)
    log(f"connect {host}:{port} failed after {timeout:.0f}s ({last})")
    return None


def load_payload(args):
    if args.send_file:
        path = args.send_file
        if not os.path.isabs(path):
            path = os.path.join(os.environ.get("RUN_DIR", "."), path)
        with open(path, "rb") as f:
            return f.read()
    if args.send_text is not None:
        data = args.send_text.encode("utf-8")
        if data and data[-1:] not in (b"\n", b"\r"):
            data += b"\r"  # submit the line (CR == Enter on the guest)
        return data
    return b""


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--addr", required=True)
    ap.add_argument("--after", default="")
    ap.add_argument("--after-timeout", type=float, default=45.0)
    ap.add_argument("--connect-timeout", type=float, default=20.0)
    ap.add_argument("--send-text", default=None)
    ap.add_argument("--send-file", default=None)
    ap.add_argument("--expect", default=None)
    ap.add_argument("--expect-fail", action="store_true")
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    run_dir = os.environ.get("RUN_DIR", ".")
    tag = os.environ.get("VG_TAG", "run")
    ser = os.environ.get("VG_SER", os.path.join(run_dir, "vm-serial.log"))
    out = args.out or os.path.join(run_dir, f"client-{tag}.out")
    host, port = parse_addr(args.addr)

    if args.expect_fail:
        # Negative gate: the port must NOT accept. A short single-shot
        # attempt; success == refusal/timeout.
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(max(args.connect_timeout, 1.0))
        try:
            s.connect((host, port))
            s.close()
            log(f"UNEXPECTED listener on {host}:{port} (--expect-fail)")
            with open(out, "wb") as f:
                f.write(b"<unexpected connection>\n")
            sys.exit(1)
        except OSError as e:
            log(f"refused as expected on {host}:{port} ({e})")
            with open(out, "wb") as f:
                f.write(b"<refused as expected>\n")
            sys.exit(0)

    if not wait_marker(ser, args.after, args.after_timeout):
        log(f"marker {args.after!r} not seen in {ser} within {args.after_timeout:.0f}s")
        sys.exit(1)

    s = connect(host, port, args.connect_timeout)
    if s is None:
        with open(out, "wb") as f:
            f.write(b"<connect failed>\n")
        sys.exit(1)

    payload = load_payload(args)
    if payload:
        s.sendall(payload)

    capture = bytearray()
    expect = args.expect.encode("utf-8", "replace") if args.expect else None
    deadline = time.time() + args.timeout
    try:
        while time.time() < deadline:
            s.settimeout(max(0.1, min(1.0, deadline - time.time())))
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                if expect is None:
                    break  # no expectation: a quiet settle is success
                continue
            if not chunk:
                break
            capture.extend(chunk)
            if expect is not None and expect in capture:
                break
    finally:
        try:
            s.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        s.close()

    with open(out, "wb") as f:
        f.write(capture)

    if expect is not None and expect not in capture:
        log(f"expected {args.expect!r} not seen ({len(capture)} bytes captured)")
        sys.exit(1)
    log(f"ok ({len(capture)} bytes captured -> {out})")
    sys.exit(0)


if __name__ == "__main__":
    main()
