# HTTP/2 vs HTTP/3 Client Benchmark Suite

Copy this directory to the **client machine** (e.g. Kali VM at `10.0.10.130`) and run it against the
**Linux server** (e.g. Ubuntu VM at `10.0.10.140`).

## Files

- `run-benchmarks.sh`: full run, one demo or one condition, and a connectivity check.
- `demo2-multi-stream.sh`: Demo 2, protocol advantage. 20 × 1 MB in parallel over one connection, curl only.
- `demo1-single-stream.sh`: Demo 1, deployment check. Single requests (10 KB, 100 KB, 1 MB, 10 MB) through
  several clients.
- `capture-demo.sh`: packet captures for the report. Records one decryptable `.pcapng` per protocol for
  Demo 1 (10 KB at 50 ms delay) and Demo 2 (20 × 1 MB at 4% loss) with tcpdump on the server, and embeds
  the TLS/QUIC keys so Wireshark shows HTTP/2 and HTTP/3 frames directly. Needs passwordless sudo on the server.
- `aioquic-get.py`: minimal aioquic HTTP/3 client used by Demo 1 (aioquic itself is only a library).
  Uses `venv/bin/python` next to it if present, otherwise `python3`.

## Requirements

- **curl** with HTTP/3 (`curl --version` lists `HTTP3`)
- **wget2** for a second HTTP/2 client: `sudo apt install wget2`
- **aioquic** for a second HTTP/3 client: `python3 -m venv venv && venv/bin/pip install aioquic`
- **SSH key login to the server** for automatic runs; the server user must be able to run Docker

Every client's timing excludes process start-up: curl reports `time_total`, wget2 its TLS handshake plus
transfer time (it starts after the TCP connection is open), and aioquic times itself.
quiche-client can be added with `CLIENTS="... quiche"`, but its time includes process start-up.

## Network conditions are set on the server only

These scripts never change the client's network. Delay and loss are applied with `tc netem` to the
server's outgoing traffic on ports 8443/8444. With `SERVER_SSH` set, `run-benchmarks.sh` applies each
condition over SSH, checks that time to first byte matches the delay, measures, and resets the server at
the end. Without it, the script prints the server command for each condition and waits for Enter.

## Quick start

```bash
./run-benchmarks.sh check 10.0.10.140

# Full run: 9 server conditions
#   Demo 1: 0/25/50 ms x 0/2% loss    Demo 2: 0 ms x 0/2/4/8/12% loss
SERVER_SSH=myadmin@10.0.10.140 ./run-benchmarks.sh 10.0.10.140

# One demo, or one condition
SERVER_SSH=myadmin@10.0.10.140 ./run-benchmarks.sh demo2 10.0.10.140
SERVER_SSH=myadmin@10.0.10.140 ./run-benchmarks.sh demo1 10.0.10.140 25ms 2%

# Keep running after SSH disconnects
SERVER_SSH=myadmin@10.0.10.140 setsid nohup ./run-benchmarks.sh 10.0.10.140 > run.log 2>&1 < /dev/null &
```

Useful overrides: `RUNS=7`, `CLIENTS="curl-h2 curl-h3"`, `FILES="10kb.bin 10mb.bin"`,
`REQ_TIMEOUT=30`, `DEMO1_DELAYS`, `DEMO1_LOSSES`, `DEMO2_DELAYS`, `DEMO2_LOSSES`.

## Output files

One CSV per condition, named after it:

- `results-demo1_delay<DELAY>_loss<LOSS>.csv` (e.g. `results-demo1_delay25ms_loss2pct.csv`):
  median, mean, min and max request time and failed runs per file size and client.
- `results-demo2_delay<DELAY>_loss<LOSS>.csv` (e.g. `results-demo2_delay0ms_loss8pct.csv`):
  batch completion time, per-stream time, failed transfers, and HTTP/2 ÷ HTTP/3
  speedup (`>1x` means HTTP/3 is faster).
