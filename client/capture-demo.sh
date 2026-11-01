#!/usr/bin/env bash
# ==============================================================================
# Packet captures for the report (run on the client, e.g. Kali)
#
# Records one decryptable .pcapng per protocol and demo, with the TLS/QUIC keys
# embedded (editcap --inject-secrets), so Wireshark shows HTTP/2 and HTTP/3 frames
# without any extra setup.
#
# Packets are captured on the SERVER with tcpdump, not on the client: the client's
# GRO merges several QUIC datagrams into one capture record, which Wireshark can't
# split (short-header QUIC packets have no length field). The netem helper turns
# GRO/GSO/TSO off on the server for every condition, so the server sees each packet
# as sent on the wire. netem delays packets before tcpdump's capture point, so
# server timestamps match what the client sees to within the base RTT (< 1 ms).
#   Demo 1: one 10 KB request, server delay 50 ms, no loss   -> handshake, packet layout
#   Demo 2: 20 x 1 MB over one connection, 4% loss           -> multiplexing, loss recovery
#
# The server condition is applied over SSH (same helper as run-benchmarks.sh) and
# reset on exit. The server user needs passwordless sudo for tcpdump.
#
# Usage:
#   SERVER_SSH=myadmin@10.0.10.140 ./capture-demo.sh [all|demo1|demo2] [SERVER_IP]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHICH="${1:-all}"
SERVER_IP="${2:-${SERVER_IP:-10.0.10.140}}"
HTTP2_PORT="${HTTP2_PORT:-8443}"
HTTP3_PORT="${HTTP3_PORT:-8444}"
SERVER_SSH="${SERVER_SSH:-}"
SERVER_NETCOND="${SERVER_NETCOND:-cd h2-vs-h3 && docker compose -f docker-compose.linux.yml run --rm -T netem}"
CLIENT_IP="${CLIENT_IP:-$(ip route get "$SERVER_IP" | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')}"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/captures}"

DEMO1_FILE="${DEMO1_FILE:-10kb.bin}"
DEMO1_DELAY="${DEMO1_DELAY:-50ms}"
DEMO2_LOSS="${DEMO2_LOSS:-4%}"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

if [ -z "$SERVER_SSH" ]; then
    echo -e "${RED}✗ Set SERVER_SSH (e.g. myadmin@10.0.10.140) so the script can set delay/loss on the server.${NC}" >&2
    exit 1
fi

set_server() {
    ssh -n -o BatchMode=yes -o ConnectTimeout=8 "$SERVER_SSH" "$SERVER_NETCOND $1 $2" >/dev/null
}

# Server interface facing this client
SERVER_IFACE="${SERVER_IFACE:-$(ssh -n -o BatchMode=yes "$SERVER_SSH" "ip route get $CLIENT_IP" |
    awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')}"

mkdir -p "$OUT_DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; set_server reset "" && echo -e "${GREEN}✓ Server network reset${NC}"' EXIT

# $1 = output name, rest = curl arguments. Captures only this client's traffic on the benchmark ports.
capture() {
    local name="$1"
    shift
    local raw="$WORK/$name.pcap" keys="$WORK/$name.keys" remote="/tmp/h2h3-$name.pcap"
    local filter="host $CLIENT_IP and (port $HTTP2_PORT or port $HTTP3_PORT)"
    ssh -n -o BatchMode=yes "$SERVER_SSH" "sudo -n rm -f $remote; sudo -n nohup timeout 300 tcpdump -i $SERVER_IFACE -s 0 -B 16384 -U -w $remote '$filter' >/tmp/h2h3-tcpdump.log 2>&1 &"
    sleep 2
    # One line per transfer (HTTP version, whether it opened a connection, exit code), counted
    { SSLKEYLOGFILE="$keys" curl -k -s -o /dev/null --max-time 120 \
        -w "  HTTP/%{http_version}  new-conn=%{num_connects}  exit=%{exitcode}\n" "$@" || true; } | sort | uniq -c
    sleep 1
    ssh -n -o BatchMode=yes "$SERVER_SSH" "sudo -n pkill -INT -f 'tcpdump.*$remote'; sleep 1; sudo -n chmod 644 $remote; tail -2 /tmp/h2h3-tcpdump.log | sed 's/^/  server tcpdump: /'"
    scp -q "$SERVER_SSH:$remote" "$raw"
    ssh -n -o BatchMode=yes "$SERVER_SSH" "sudo -n rm -f $remote"
    editcap -F pcapng --inject-secrets "tls,$keys" "$raw" "$OUT_DIR/$name.pcapng"
    echo -e "  ${CYAN}→ $OUT_DIR/$name.pcapng${NC} ($(capinfos -c -M "$OUT_DIR/$name.pcapng" | awk -F: '/Number of packets/ {gsub(/ /, "", $2); print $2}') packets)"
}

if [ "$WHICH" = "all" ] || [ "$WHICH" = "demo1" ]; then
    echo -e "${GREEN}Demo 1: ${DEMO1_FILE}, delay ${DEMO1_DELAY}, no loss${NC}"
    set_server "$DEMO1_DELAY" "0%"
    capture demo1-http2 --http2 "https://${SERVER_IP}:${HTTP2_PORT}/resources/single/${DEMO1_FILE}"
    capture demo1-http3 --http3-only "https://${SERVER_IP}:${HTTP3_PORT}/resources/single/${DEMO1_FILE}"
fi

if [ "$WHICH" = "all" ] || [ "$WHICH" = "demo2" ]; then
    echo -e "${GREEN}Demo 2: 20 x 1 MB on one connection, no delay, loss ${DEMO2_LOSS}${NC}"
    set_server "0ms" "$DEMO2_LOSS"
    capture demo2-http2 --http2 --parallel --parallel-max 20 \
        "https://${SERVER_IP}:${HTTP2_PORT}/resources/multi/file-[1-20].bin"
    capture demo2-http3 --http3-only --parallel --parallel-max 20 \
        "https://${SERVER_IP}:${HTTP3_PORT}/resources/multi/file-[1-20].bin"
fi

echo -e "\n${GREEN}✓ Captures in ${OUT_DIR}${NC} (TLS/QUIC keys embedded; open directly in Wireshark)"
