# HTTP/2 vs HTTP/3 Benchmark

Measures how **HTTP/2** (TCP + TLS 1.3) and **HTTP/3** (QUIC + TLS 1.3) behave under emulated delay and
packet loss, using two nginx servers on a Linux host and benchmark scripts on a separate client.

- **Demo 2: protocol advantage.** 20 × 1 MB fetched in parallel over one connection with curl, under
  0–12% loss. Only the protocol changes, so it shows head-of-line blocking in HTTP/2 and its absence in HTTP/3.
- **Demo 1: deployment check.** Single requests (10 KB – 10 MB) through curl, wget2 and aioquic under
  0–50 ms delay and 0 or 2% loss. Shows how today's servers and clients handle HTTP/3, and whether it can
  replace HTTP/2.

The report with results and the full configuration is in
[`results-linux-server/report.html`](results-linux-server/report.html).

---

## Test bed

```
Kali Linux VM (client)  ──  VMware virtual switch  ──  Ubuntu VM (server)
10.0.10.130                                            10.0.10.140
curl · wget2 · aioquic                                 Docker Engine, host networking
                                                       nginx HTTP/2 :8443/TCP · HTTP/3 :8444/UDP
                                                       tc netem on the server's outgoing traffic
```

nginx runs with **host networking**, so there is no port forwarding between client and nginx.
Docker Desktop is not suitable: its port forwarding terminates TCP but only relays UDP, which treats the
two protocols differently.

---

## Server (Linux)

Requirements: Docker Engine with Compose, a kernel with `sch_netem`, and a user in the `docker` group.

```bash
# In the project folder on the server
docker compose -f docker-compose.linux.yml up -d --build
docker compose -f docker-compose.linux.yml build netem

# Payload files (only if web/resources/single and multi are missing)
./scripts/generate-workloads.sh

# Delay/loss on outgoing traffic from ports 8443/8444 (SSH and other traffic unaffected)
docker compose -f docker-compose.linux.yml run --rm netem 25ms 2%
docker compose -f docker-compose.linux.yml run --rm netem show
docker compose -f docker-compose.linux.yml run --rm netem reset
```

With root instead of Docker: `sudo ./scripts/set-network-condition-linux.sh 25ms 2%`.

If the server is a VMware VM, use the **vmxnet3** network adapter. The e1000 adapter hung
(`Detected Tx Unit Hang`) during high-loss tests.

---

## Client

Copy `client/` to the client machine. See [`client/README.md`](client/README.md) for tool requirements.

```bash
./run-benchmarks.sh check 10.0.10.140

# Full run: applies each condition on the server over SSH, verifies it, measures, and resets at the end
SERVER_SSH=myadmin@10.0.10.140 ./run-benchmarks.sh 10.0.10.140
```

---

## Project structure

```
.
├── docker-compose.linux.yml        # nginx HTTP/2 + HTTP/3 (host networking), cert generator, netem helper
├── nginx/
│   ├── http2/                      # nginx:alpine, TCP 8443
│   └── http3/                      # nginx:mainline-alpine, QUIC 8444 (tuned: quic_retry, quic_gso, stream buffer)
├── scripts/                        # [SERVER]
│   ├── set-network-condition-linux.sh  # tc netem controller (delay, loss, reset, show)
│   ├── netem.Dockerfile            # tools image so tc runs without sudo
│   ├── generate-workloads.sh       # benchmark payload files
│   ├── generate-certs.sh           # self-signed certificate (run by cert-generator)
│   └── health-check-http2.sh / health-check-http3.sh
├── web/resources/
│   ├── single/                     # Demo 1 payloads (0 KB – 10 MB)
│   └── multi/                      # Demo 2 payloads (20 × 1 MB)
├── client/                         # [CLIENT]
│   ├── run-benchmarks.sh           # full run / single condition / connectivity check
│   ├── demo1-single-stream.sh
│   ├── demo2-multi-stream.sh
│   └── aioquic-get.py              # minimal aioquic HTTP/3 client used by Demo 1
├── results-linux-server/           # final CSVs, run log, report
└── results/docker-desktop/         # earlier results from the Docker Desktop setup (not used in the report)
```

---

## Troubleshooting

- **HTTP/3 unreachable:** make sure UDP 8444 is open, then test with
  `curl -k --http3-only https://10.0.10.140:8444/health`.
- **`Specified qdisc kind is unknown`:** the server kernel lacks `sch_netem`.
- **Run stops with "Server delay still doesn't match":** the condition wasn't applied. Check
  `docker compose -f docker-compose.linux.yml run --rm netem show` on the server.
