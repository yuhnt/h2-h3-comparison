#!/usr/bin/env python3
"""Minimal aioquic HTTP/3 GET client for the benchmarks.

Downloads one URL, discards the body, and prints the elapsed seconds from
connection start to the last body byte (like curl's %{time_total}), so Python
start-up time isn't counted. Exits non-zero unless the response is 200.

Usage: aioquic-get.py [--insecure] https://10.0.10.1:8444/resources/single/1mb.bin
"""

import argparse
import asyncio
import ssl
import sys
import time
from urllib.parse import urlparse

from aioquic.asyncio.client import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration


class H3Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._http = H3Connection(self._quic)
        self._done = {}
        self._status = {}
        self._bytes = {}

    def quic_event_received(self, event):
        for h3_event in self._http.handle_event(event):
            if not isinstance(h3_event, (HeadersReceived, DataReceived)):
                continue
            stream_id = h3_event.stream_id
            if stream_id not in self._done:
                continue
            if isinstance(h3_event, HeadersReceived):
                self._status[stream_id] = dict(h3_event.headers).get(b":status", b"").decode()
            else:
                self._bytes[stream_id] += len(h3_event.data)
            if h3_event.stream_ended and not self._done[stream_id].done():
                self._done[stream_id].set_result(None)

    async def get(self, authority, path):
        stream_id = self._quic.get_next_available_stream_id()
        self._done[stream_id] = self._loop.create_future()
        self._bytes[stream_id] = 0
        self._http.send_headers(
            stream_id,
            [
                (b":method", b"GET"),
                (b":scheme", b"https"),
                (b":authority", authority.encode()),
                (b":path", path.encode()),
                (b"user-agent", b"aioquic-bench"),
            ],
            end_stream=True,
        )
        self.transmit()
        await self._done[stream_id]
        return self._status.get(stream_id, ""), self._bytes[stream_id]


async def fetch(url, insecure):
    parsed = urlparse(url)
    path = (parsed.path or "/") + (f"?{parsed.query}" if parsed.query else "")

    config = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    if insecure:
        config.verify_mode = ssl.CERT_NONE
    # aioquic's 1MB default flow-control windows would throttle large downloads
    config.max_data = 16 * 1024 * 1024
    config.max_stream_data = 16 * 1024 * 1024

    start = time.perf_counter()
    async with connect(
        parsed.hostname, parsed.port or 443, configuration=config, create_protocol=H3Client
    ) as client:
        status, size = await client.get(parsed.netloc, path)
        elapsed = time.perf_counter() - start
    return status, size, elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("url")
    parser.add_argument("--insecure", action="store_true", help="don't verify the server certificate")
    args = parser.parse_args()

    status, size, elapsed = asyncio.run(fetch(args.url, args.insecure))
    if status != "200":
        print(f"HTTP status {status or 'none'} ({size} bytes)", file=sys.stderr)
        sys.exit(1)
    print(f"{elapsed:.6f}")


if __name__ == "__main__":
    main()
