#!/usr/bin/env python3
"""One synchronous recsys stats request (op 10, empty payload; experiments/loadgen/frame.h) per target.

usage: stats_snap.py <host:port> <out file> [--timeout S]
Writes '# when=<iso> target=<host:port> status=<code> rtt_us=<n>' and the server's key=value reply to <out file>
(must not exist). Exit 0 on status 0, 1 otherwise. Read-only: the stats op touches no table data.
"""
import datetime
import os
import socket
import struct
import sys
import time

HEADER = struct.Struct('<IHHQ')  # len (bytes after this field), op/status, flags, req_id
TAIL = HEADER.size - 4
OP_STATS = 10


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    target, out = sys.argv[1], sys.argv[2]
    timeout = float(sys.argv[sys.argv.index('--timeout') + 1]) if '--timeout' in sys.argv else 30.0
    if os.path.exists(out):
        sys.exit(f'refusing: {out} exists')
    host, port = target.rsplit(':', 1)
    t0 = time.monotonic()
    with socket.create_connection((host, int(port)), timeout=timeout) as s:
        s.sendall(HEADER.pack(TAIL, OP_STATS, 0, 1))
        buf = b''
        while len(buf) < HEADER.size:
            c = s.recv(65536)
            if not c:
                sys.exit('connection closed')
            buf += c
        n, status, _flags, rid = HEADER.unpack(buf[:HEADER.size])
        need = HEADER.size + n - TAIL
        while len(buf) < need:
            c = s.recv(1 << 20)
            if not c:
                sys.exit('connection closed')
            buf += c
    body = buf[HEADER.size:need].decode('utf-8', 'replace')
    rtt = int((time.monotonic() - t0) * 1e6)
    with open(out, 'x') as f:
        f.write(f'# when={datetime.datetime.now().astimezone().isoformat()} target={target} status={status} '
                f'req_id={rid} rtt_us={rtt}\n')
        f.write(body)
    sys.exit(0 if status == 0 else 1)


if __name__ == '__main__':
    main()
