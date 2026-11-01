# Packet captures (Wireshark / tshark)

Captured on 6 Oct 2026 with `client/capture-demo.sh`, on the server (tcpdump), against nginx 1.31.6.
TLS 1.3 / QUIC keys from curl (`SSLKEYLOGFILE`) are embedded in each file, so Wireshark decrypts
HTTP/2 and HTTP/3 without any setup (Wireshark 4.x; open the file and the frames are readable).

| File | Condition | What it shows |
|---|---|---|
| `demo1-http2.pcapng` | 1 × 10 KB, server delay 50 ms, no loss | TCP handshake, TLS 1.3, HTTP/2 preface/SETTINGS/HEADERS/DATA, GOAWAY |
| `demo1-http3.pcapng` | 1 × 10 KB, server delay 50 ms, no loss | QUIC Initial/Handshake/1-RTT, coalescing, HTTP/3 control stream, QPACK, HEADERS/DATA |
| `demo2-http2.pcapng` | 20 × 1 MB on one connection, 4% loss | Stream interleaving, SACK / dup ACK, retransmissions, RTO stalls |
| `demo2-http3.pcapng` | 20 × 1 MB on one connection, 4% loss | Stream IDs 0–76, ACK ranges with gaps, retransmission in new packet numbers |

Why on the server: the client's GRO merges several QUIC datagrams into one capture record, which
Wireshark cannot split. The netem helper turns GRO/GSO/TSO off on the server for every condition.
netem delays and drops packets before tcpdump's capture point, so dropped packets never appear
(Wireshark marks the gaps) and server timestamps match the client's view within the base RTT (< 1 ms).

Useful display filters:

```
quic.long.packet_type == 0              # QUIC Initial
quic.header_form == 0                   # QUIC 1-RTT (short header)
http3.frame_type == 4                   # HTTP/3 SETTINGS
http3.stream_uni_type                   # unidirectional streams (control, QPACK)
quic.ack.ack_range_count > 0            # ACK frames with gaps (lost packets)
http2.type == 1                         # HTTP/2 HEADERS
tcp.analysis.retransmission || tcp.analysis.duplicate_ack
tcp.analysis.lost_segment               # gaps in the TCP byte stream
```

`analysis/` holds the tshark exports used in the presentation: handshake timelines and packet
layouts for Demo 1, per-packet TCP / QUIC STREAM data for Demo 2 (`h2.tsv`, `h3.tsv`), and the
derived HoL series (`hol-series.json`).
