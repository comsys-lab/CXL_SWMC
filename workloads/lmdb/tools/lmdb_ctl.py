#!/usr/bin/env python3
"""Send one text request to an lmdb-server and print the reply (stats op 10, verify op 11).
usage: lmdb_ctl.py host:port stats|verify [--expect key=value ...]   (exit 1 if an expectation fails)
"""
import asyncio
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../../experiments/loadgen/python"))
from frame import FrameClient  # noqa: E402

OPS = {"stats": 10, "verify": 11}


async def main():
    host, port = sys.argv[1].rsplit(":", 1)
    op = OPS[sys.argv[2]]
    c = await FrameClient.connect(host, int(port))
    status, payload = await c.call(op)
    await c.close()
    text = payload.decode()
    print(text, end="")
    if status != 0:
        sys.exit(f"status {status}")
    kv = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
    bad = [e for e in sys.argv[4:] if sys.argv[3:4] == ["--expect"] and kv.get(e.split("=", 1)[0]) != e.split("=", 1)[1]]
    for e in bad:
        print(f"EXPECT FAILED {e} (got {kv.get(e.split('=', 1)[0])})", file=sys.stderr)
    sys.exit(1 if bad else 0)


asyncio.run(main())
