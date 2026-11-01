#!/usr/bin/env bash
# ==============================================================================
# Network Condition Controller for a Linux server (docker-compose.linux.yml)
# Run on the Linux server as root.
#
# Applies tc netem to the server's outgoing traffic from the benchmark ports only
# (HTTP/2 8443, HTTP/3 8444), so SSH and everything else stay unaffected.
# Delay D adds about D to each round trip; loss is random per packet.
#
# Usage:
#   sudo ./set-network-condition-linux.sh 25ms 2%
#   sudo ./set-network-condition-linux.sh reset
#   sudo ./set-network-condition-linux.sh show
#
# Env: IFACE (default: interface of the default route), PORTS (default "8443 8444")
# ==============================================================================

set -euo pipefail

DELAY="${1:-0ms}"
LOSS="${2:-0%}"
IFACE="${IFACE:-$(ip route show default | awk '{print $5; exit}')}"
read -r -a PORTS <<< "${PORTS:-8443 8444}"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [ -z "$IFACE" ] || ! ip link show "$IFACE" >/dev/null 2>&1; then
    echo -e "${RED}✗ Network interface not found (set IFACE=...).${NC}" >&2
    exit 1
fi

show() {
    echo "--- $IFACE qdiscs ---"
    tc -s qdisc show dev "$IFACE"
    echo "--- $IFACE filters ---"
    tc filter show dev "$IFACE" parent 1: 2>/dev/null || true
    echo "--- offloads ---"
    ethtool -k "$IFACE" 2>/dev/null | grep -E "^(tcp-segmentation|generic-segmentation|generic-receive)-offload" || true
}

if [ "$DELAY" = "show" ]; then
    show
    exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}✗ Needs root: sudo $0 $*${NC}" >&2
    exit 1
fi

# Offloads hand netem 64KB super-packets, so TCP would lose whole bursts while QUIC
# loses single packets. Keep them off for the whole benchmark, baseline included.
set_offloads() {
    ethtool -K "$IFACE" tso "$1" gso "$1" gro "$1" 2>/dev/null \
        || echo -e "${YELLOW}! Could not set offloads $1 on $IFACE${NC}" >&2
}

tc qdisc del dev "$IFACE" root 2>/dev/null || true

if [ "$DELAY" = "reset" ]; then
    set_offloads on
    echo -e "${GREEN}✓ Reset $IFACE: no shaping, offloads on${NC}"
    exit 0
fi

set_offloads off

if [ "$DELAY" = "0ms" ] && [ "$LOSS" = "0%" ]; then
    echo -e "${GREEN}✓ Baseline on $IFACE: no delay/loss, offloads off${NC}"
    exit 0
fi

# prio with a 4th band: bands 1:1-1:3 keep normal traffic, 1:4 carries the benchmark ports
tc qdisc add dev "$IFACE" root handle 1: prio bands 4 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1
tc qdisc add dev "$IFACE" parent 1:4 handle 40: netem delay "$DELAY" loss "$LOSS" limit 100000
for port in "${PORTS[@]}"; do
    tc filter add dev "$IFACE" parent 1: protocol ip prio 1 u32 match ip sport "$port" 0xffff flowid 1:4
done

echo -e "${CYAN}✓ $IFACE: Delay=${DELAY} Loss=${LOSS} on traffic from ports ${PORTS[*]}${NC}"
tc qdisc show dev "$IFACE" parent 1:4
