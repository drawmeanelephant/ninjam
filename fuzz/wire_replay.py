#!/usr/bin/env python3
"""Replay a fuzzer corpus/crash file against the REAL NINJAM server over TCP.

Usage:
  wire_replay.py <server-binary> <config.cfg> <input-file> [--split N]

Connects to the server, performs the client side of the NINJAM handshake, then
sends the input file's bytes verbatim (after the handshake). If `--split N` is
given, the post-handshake stream is written in N-byte chunks with short delays
to exercise TCP fragmentation.

Reports whether the server process died (crash) and, on request, captures the
server log/stderr.
"""

import socket
import struct
import subprocess
import sys
import time
import os
import signal

MSG_CLIENT_AUTH_USER = 0x80
PROTO_VER_CUR = 0x00020000


def read_message(sock):
    """Read one NINJAM message; returns (type, payload) or None on EOF."""
    hdr = b""
    while len(hdr) < 5:
        b = sock.recv(5 - len(hdr))
        if not b:
            return None
        hdr += b
    mtype = hdr[0]
    (size,) = struct.unpack("<I", hdr[1:5])
    payload = b""
    while len(payload) < size:
        b = sock.recv(min(65536, size - len(payload)))
        if not b:
            break
        payload += b
    return mtype, payload


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    server_bin, cfg, infile = sys.argv[1], sys.argv[2], sys.argv[3]
    split = 0
    raw = "--raw" in sys.argv
    if "--split" in sys.argv:
        split = int(sys.argv[sys.argv.index("--split") + 1])

    with open(infile, "rb") as f:
        stream = f.read()

    port = 22049  # fixed test port (config overrides not needed)
    srvlog = "/tmp/ninjam_wire_srv.log"
    log = open(srvlog, "ab")
    proc = subprocess.Popen([server_bin, cfg, "-port", str(port), "-logfile",
                             srvlog], stdout=log, stderr=subprocess.STDOUT)
    time.sleep(0.8)
    if proc.poll() is not None:
        print("server exited during startup, rc=%d" % proc.returncode)
        return 1

    rc = 0
    try:
        sock = socket.create_connection(("127.0.0.1", port), timeout=5)
        msg = read_message(sock)
        if raw:
            # pre-auth crashes: stream is sent before completing any handshake
            if split:
                for i in range(0, len(stream), split):
                    sock.sendall(stream[i:i + split])
                    time.sleep(0.002)
            else:
                sock.sendall(stream)
            time.sleep(0.8)
        elif not msg or msg[0] != 0x00:
            print("no server challenge received")
            rc = 1
        else:
            challenge = msg[1][:8]
            # anonymous-style login; the server may accept or refuse it, the
            # fuzzer input after this point is what we are replaying
            user = b"anonymous"
            import hashlib
            sha1 = hashlib.sha1(user + b":" + b"x").digest()
            authpayload = sha1 + user + b"\x00" + struct.pack("<II", 1, PROTO_VER_CUR)
            sock.sendall(bytes([MSG_CLIENT_AUTH_USER]) +
                         struct.pack("<I", len(authpayload)) + authpayload)
            time.sleep(0.3)
            # drain the auth reply / any server traffic
            sock.settimeout(0.3)
            try:
                while read_message(sock):
                    pass
            except socket.timeout:
                pass
            sock.settimeout(5)
            if split:
                for i in range(0, len(stream), split):
                    sock.sendall(stream[i:i + split])
                    time.sleep(0.002)
            else:
                sock.sendall(stream)
            time.sleep(0.8)
        sock.close()
    except (ConnectionResetError, BrokenPipeError, OSError) as e:
        print("connection error: %s" % e)

    time.sleep(0.5)
    if proc.poll() is None:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        status = "ALIVE (no crash)"
    else:
        status = "DEAD rc=%d (crash)" % proc.returncode
        rc = rc or 1
    print("server: %s" % status)
    return rc


if __name__ == "__main__":
    sys.exit(main())
