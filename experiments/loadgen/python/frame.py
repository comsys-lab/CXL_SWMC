"""Python peer of experiments/loadgen/frame.h: asyncio client for the length-prefixed binary frames.

Lets Python callers (e.g. a LangChain VectorStore like workloads/rag/gpu/LangChain/async_custom_vectorstore.py)
talk to the same servers the load generator drives. One connection carries many concurrent requests; responses
are matched by req_id.

    c = await FrameClient.connect("192.168.122.100", 7000)
    status, payload = await c.call(op, payload_bytes)
"""
import asyncio
import itertools
import struct

HEADER = struct.Struct("<IHHQ")  # len, op/status, flags, req_id; len counts everything after the len field
HEADER_TAIL = HEADER.size - 4


class FrameClient:
    def __init__(self, reader, writer):
        self._r, self._w = reader, writer
        self._ids = itertools.count(1)
        self._wait = {}
        self._rx = asyncio.get_running_loop().create_task(self._receive())

    @classmethod
    async def connect(cls, host, port):
        r, w = await asyncio.open_connection(host, port)
        return cls(r, w)

    async def call(self, op, payload=b"", flags=0):
        rid = next(self._ids)
        fut = asyncio.get_running_loop().create_future()
        self._wait[rid] = fut
        self._w.write(HEADER.pack(HEADER_TAIL + len(payload), op, flags, rid) + payload)
        await self._w.drain()
        return await fut

    async def _receive(self):
        try:
            while True:
                n, status, _flags, rid = HEADER.unpack(await self._r.readexactly(HEADER.size))
                body = await self._r.readexactly(n - HEADER_TAIL)
                fut = self._wait.pop(rid, None)
                if fut and not fut.done():
                    fut.set_result((status, body))
        except (asyncio.IncompleteReadError, ConnectionError) as e:
            for fut in self._wait.values():
                if not fut.done():
                    fut.set_exception(ConnectionError(str(e)))
            self._wait.clear()

    async def close(self):
        self._rx.cancel()
        self._w.close()
        await self._w.wait_closed()
