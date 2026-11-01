#!/usr/bin/env bash
# ==============================================================================
# Master Client Benchmark Suite
# Run this on Kali VM / Client machine
#
# Delay/loss is applied on the SERVER only. With SERVER_SSH set (Linux server), each
# condition is applied over SSH automatically; otherwise the script tells you which
# server command to run and waits. Either way it checks the server's delay first.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_IP="${SERVER_IP:-10.0.10.140}"
HTTP2_PORT="${HTTP2_PORT:-8443}"
HTTP3_PORT="${HTTP3_PORT:-8444}"
# e.g. SERVER_SSH=myadmin@10.0.10.140 (key login; the user must be able to run docker)
SERVER_SSH="${SERVER_SSH:-}"
# Command on the server that takes "<delay> <loss>" or "reset"
SERVER_NETCOND="${SERVER_NETCOND:-cd h2-vs-h3 && docker compose -f docker-compose.linux.yml run --rm -T netem}"

read -r -a DEMO1_DELAYS <<< "${DEMO1_DELAYS:-0ms 25ms 50ms}"
# Loss sweeps belong to Demo 2; 4% with delay took 30+ min per condition in Demo 1
read -r -a DEMO1_LOSSES <<< "${DEMO1_LOSSES:-0% 2%}"
read -r -a DEMO2_DELAYS <<< "${DEMO2_DELAYS:-0ms}"
read -r -a DEMO2_LOSSES <<< "${DEMO2_LOSSES:-0% 2% 4% 8% 12%}"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

show_usage() {
    cat << EOF
${CYAN}HTTP/2 vs HTTP/3 Client Benchmark Suite${NC}

Usage:
    $0                                   Full run: Demo 1 + Demo 2, all conditions
    $0 [all|demo1|demo2] [IP]            Full run of the chosen demo(s)
    $0 [all|demo1|demo2] IP DELAY LOSS   One condition only (already set on the server)
    $0 check [IP]                        Test connection to the server
    $0 help

Default server IP: ${DEFAULT_IP}

Full-run conditions (delay x loss):
    Demo 1: ${DEMO1_DELAYS[*]} x ${DEMO1_LOSSES[*]}
    Demo 2: ${DEMO2_DELAYS[*]} x ${DEMO2_LOSSES[*]}
Conditions are applied on the server:
    SERVER_SSH set   automatically over SSH (Linux server)
    otherwise        you're asked to set each one on the server yourself

OVERRIDES (environment variables):
    SERVER_SSH=myadmin@10.0.10.140   Apply conditions on a Linux server over SSH
    SERVER_NETCOND=path              Script on that server (default: ${SERVER_NETCOND})
    RUNS=3                       Requests per measurement (default 5)
    CLIENTS="curl-h2 curl-h3"    Demo 1 clients (default: curl-h2 curl-h3 wget2 aioquic; also: quiche)
    FILES="10kb.bin 10mb.bin"    Demo 1 files (default: 10kb.bin 100kb.bin 1mb.bin 10mb.bin)
    REQ_TIMEOUT=30               Seconds before a request counts as failed
    DEMO1_DELAYS / DEMO1_LOSSES / DEMO2_DELAYS / DEMO2_LOSSES   Full-run matrix

EXAMPLES:
    $0
    SERVER_SSH=myadmin@10.0.10.140 $0 10.0.10.140
    RUNS=3 $0 demo1 10.0.10.140
    $0 demo2 10.0.10.140 0ms 8%
    $0 all 10.0.10.140 25ms 2%

EOF
}

check_server() {
    local ip="$1"
    echo -e "${CYAN}Checking connection to Server $ip...${NC}"
    echo "Testing HTTP/2 (Port ${HTTP2_PORT}):"
    curl -k -I --max-time 3 "https://${ip}:${HTTP2_PORT}/health" || true
    echo
    echo "Testing HTTP/3 (Port ${HTTP3_PORT}):"
    curl -k -I --http3-only --max-time 3 "https://${ip}:${HTTP3_PORT}/health" || true
}

in_list() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        [ "$item" = "$needle" ] && return 0
    done
    return 1
}

# A new HTTPS request needs ~3 server->client round trips, so time to first byte
# should be well above 2x the server delay. Uses the fastest of 3 tries so random
# loss can't hide a missing delay.
delay_matches() {
    local ip="$1" delay="$2"
    local delay_ms ttfb_ms
    if [[ ! "$delay" =~ ^([0-9]+)ms$ ]]; then
        return 0
    fi
    delay_ms="${BASH_REMATCH[1]}"
    ttfb_ms=$(for _ in 1 2 3; do
        curl --http2 -k -s -o /dev/null --max-time 10 -w "%{time_starttransfer}\n" "https://${ip}:${HTTP2_PORT}/health" || echo 10
    done | awk 'NR == 1 || $1 < min { min = $1 } END { printf "%d", min * 1000 }')

    if { [ "$delay_ms" -gt 0 ] && [ "$ttfb_ms" -lt $((delay_ms * 2)) ]; } ||
       { [ "$delay_ms" -eq 0 ] && [ "$ttfb_ms" -gt 40 ]; }; then
        echo -e "${YELLOW}! Server check: first byte took ${ttfb_ms}ms, which doesn't look like a ${delay} server delay.${NC}" >&2
        return 1
    fi
    echo -e "${GREEN}✓ Server check: first byte ${ttfb_ms}ms, consistent with ${delay} delay${NC}"
}

run_condition() {
    local which="$1" ip="$2" delay="$3" loss="$4"
    if [ "$which" = "demo1" ] || [ "$which" = "all" ]; then
        bash "$SCRIPT_DIR/demo1-single-stream.sh" "$ip" "$delay" "$loss"
    fi
    if [ "$which" = "demo2" ] || [ "$which" = "all" ]; then
        bash "$SCRIPT_DIR/demo2-multi-stream.sh" "$ip" "$delay" "$loss"
    fi
}

set_server() {
    # -n: don't let ssh consume this script's stdin (breaks piped or background runs)
    ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$SERVER_SSH" "$SERVER_NETCOND $1 $2" >/dev/null
}

reset_server() {
    if set_server reset ""; then
        echo -e "${GREEN}✓ Server network reset${NC}"
    else
        echo -e "${YELLOW}! Could not reset the server; on it run: ${SERVER_NETCOND} reset${NC}" >&2
    fi
}

# Automatic mode: apply over SSH, verify the delay, stop rather than record mislabeled data
apply_condition() {
    local ip="$1" delay="$2" loss="$3" attempt
    for attempt in 1 2; do
        if ! set_server "$delay" "$loss"; then
            echo -e "${RED}✗ Could not apply ${delay} ${loss} on ${SERVER_SSH} (needs SSH key login and: ${SERVER_NETCOND}).${NC}" >&2
            exit 1
        fi
        echo -e "${CYAN}➜ Server set to Delay=${delay} Loss=${loss}${NC}"
        sleep 1
        if delay_matches "$ip" "$delay"; then
            return 0
        fi
    done
    echo -e "${RED}✗ Server delay still doesn't match ${delay}; stopping so no results are mislabeled.${NC}" >&2
    exit 1
}

# Returns 0 = run, 1 = skip
wait_for_server() {
    local ip="$1" delay="$2" loss="$3" answer
    if [ -n "$SERVER_SSH" ]; then
        apply_condition "$ip" "$delay" "$loss"
        return 0
    fi
    while true; do
        echo
        echo -e "${CYAN}➜ Set the server to Delay=${delay} Loss=${loss}:${NC}"
        echo "    On the server:  docker compose -f docker-compose.linux.yml run --rm netem ${delay} ${loss}"
        read -r -p "  Press Enter when it's set (s = skip this condition, q = quit): " answer < /dev/tty
        case "$answer" in
            q|Q) echo "Stopped. Remember to reset the server network."; exit 0 ;;
            s|S) return 1 ;;
        esac
        if delay_matches "$ip" "$delay"; then
            return 0
        fi
        read -r -p "  Press Enter to re-check, or type c to continue anyway: " answer < /dev/tty
        [ "$answer" = "c" ] && return 0
    done
}

full_run() {
    local which="$1" ip="$2"
    local delays=() losses=() delay loss demos label count=0 total=0

    if [ -z "$SERVER_SSH" ] && ! (exec < /dev/tty) 2>/dev/null; then
        echo -e "${RED}✗ A full run asks you to set each condition on the server, so it needs a terminal.${NC}" >&2
        echo -e "${RED}  Pass one condition instead, e.g.: $0 demo1 ${ip} 25ms 2%${NC}" >&2
        exit 1
    fi

    # Union of both matrices, so shared conditions need one server change
    for delay in "${DEMO1_DELAYS[@]}" "${DEMO2_DELAYS[@]}"; do
        in_list "$delay" "${delays[@]}" || delays+=("$delay")
    done
    for loss in "${DEMO1_LOSSES[@]}" "${DEMO2_LOSSES[@]}"; do
        in_list "$loss" "${losses[@]}" || losses+=("$loss")
    done

    local plan=()
    for delay in "${delays[@]}"; do
        for loss in "${losses[@]}"; do
            demos=""
            if [ "$which" != "demo2" ] && in_list "$delay" "${DEMO1_DELAYS[@]}" && in_list "$loss" "${DEMO1_LOSSES[@]}"; then
                demos="demo1"
            fi
            if [ "$which" != "demo1" ] && in_list "$delay" "${DEMO2_DELAYS[@]}" && in_list "$loss" "${DEMO2_LOSSES[@]}"; then
                demos="${demos:+$demos+}demo2"
            fi
            [ -n "$demos" ] && plan+=("$delay|$loss|$demos")
        done
    done
    total=${#plan[@]}

    echo -e "${GREEN}Full run against ${ip}: ${total} server conditions${NC}"
    for label in "${plan[@]}"; do
        IFS='|' read -r delay loss demos <<< "$label"
        printf "  %-6s %-4s -> %s\n" "$delay" "$loss" "$demos"
    done

    for label in "${plan[@]}"; do
        IFS='|' read -r delay loss demos <<< "$label"
        count=$((count + 1))
        echo -e "\n${GREEN}===== Condition ${count}/${total}: Delay=${delay} Loss=${loss} (${demos}) =====${NC}"
        if ! wait_for_server "$ip" "$delay" "$loss"; then
            echo -e "${YELLOW}- Skipped${NC}"
            continue
        fi
        case "$demos" in
            demo1+demo2) run_condition all "$ip" "$delay" "$loss" ;;
            *) run_condition "$demos" "$ip" "$delay" "$loss" ;;
        esac
    done

    echo -e "\n${GREEN}✓ Full run completed. Results: ${SCRIPT_DIR}/results-*.csv${NC}"
    if [ -z "$SERVER_SSH" ]; then
        echo -e "${CYAN}➜ Reset the server network${NC} (on the server: docker compose -f docker-compose.linux.yml run --rm netem reset)"
    fi
}

COMMAND="${1:-all}"

# Allow "./run-benchmarks.sh 10.0.10.5" as a full run against that IP
if [[ "$COMMAND" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; then
    set -- all "$@"
    COMMAND="all"
fi

TARGET_IP="${2:-$DEFAULT_IP}"

case "$COMMAND" in
    all|demo1|demo2)
        if [ -n "$SERVER_SSH" ]; then
            trap reset_server EXIT
        fi
        if [ $# -ge 4 ]; then
            if [ -n "$SERVER_SSH" ]; then
                apply_condition "$TARGET_IP" "$3" "$4"
            else
                delay_matches "$TARGET_IP" "$3" || true
            fi
            run_condition "$COMMAND" "$TARGET_IP" "$3" "$4"
        elif [ $# -eq 3 ]; then
            echo -e "${RED}✗ Give both DELAY and LOSS, e.g.: $0 $COMMAND $TARGET_IP 25ms 2%${NC}" >&2
            exit 1
        else
            full_run "$COMMAND" "$TARGET_IP"
        fi
        ;;
    check)
        check_server "$TARGET_IP"
        ;;
    help|--help|-h)
        show_usage
        ;;
    *)
        echo -e "${RED}Unknown command: $COMMAND${NC}\n" >&2
        show_usage
        exit 1
        ;;
esac
