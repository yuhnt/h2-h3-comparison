#!/usr/bin/env bash
# ==============================================================================
# Client Benchmark Runner: Scenario 1 - Single-Stream Requests
# Run this on Kali VM / Client machine
#
# Delay/loss is applied on the SERVER only (scripts/set-network-condition-linux.sh,
# run via the netem helper). This script measures whatever condition the server applies
# and labels the CSV with the DELAY/LOSS you pass, so pass the same values you
# set on the server:
#   results-demo1_delay<DELAY>_loss<LOSS>.csv
#
# Usage:
#   ./demo1-single-stream.sh [SERVER_IP] [DELAY] [LOSS]
#   RUNS=3 CLIENTS="curl-h2 curl-h3" ./demo1-single-stream.sh 10.0.10.140 25ms 2%
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVER_IP="${1:-${SERVER_IP:-10.0.10.140}}"
DELAY="${2:-${DELAY:-0ms}}"
LOSS="${3:-${LOSS:-0%}}"
HTTP2_PORT="${HTTP2_PORT:-8443}"
HTTP3_PORT="${HTTP3_PORT:-8444}"
RUNS="${RUNS:-5}"
# A request slower than this counts as a failure instead of stalling the run
REQ_TIMEOUT="${REQ_TIMEOUT:-60}"
# quiche is still supported (CLIENTS="... quiche") but off by default: debug build, timed with start-up
read -r -a CLIENTS <<< "${CLIENTS:-curl-h2 curl-h3 wget2 aioquic}"
# 10 KB = handshake-dominated, 100 KB-1 MB = crossover, 10 MB = bulk throughput.
# Full set: FILES="0kb.bin 10kb.bin 100kb.bin 500kb.bin 1mb.bin 5mb.bin 10mb.bin"
read -r -a FILES <<< "${FILES:-10kb.bin 100kb.bin 1mb.bin 10mb.bin}"

CSV_FILE="${SCRIPT_DIR}/results-demo1_delay${DELAY}_loss${LOSS//%/pct}.csv"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# No TCP Fast Open / OCSP / HSTS / HPKP, so wget2 does the same work per request as curl
WGET2_OPTS="-q --no-check-certificate --no-tcp-fastopen --no-ocsp --no-hsts --no-hpkp -O /dev/null"
STATS_DIR="$(mktemp -d)"
trap 'rm -rf "$STATS_DIR"' EXIT

want() {
    [[ " ${CLIENTS[*]} " == *" $1 "* ]]
}

check_tools() {
    echo -e "${CYAN}=== Checking Client Tools on $(hostname) ===${NC}"
    if command -v curl >/dev/null 2>&1; then
        echo -e "✓ Curl: Available ($(curl --version | head -n1 | cut -d' ' -f1-2))"
    else
        echo -e "${RED}✗ Curl is required!${NC}" >&2
        exit 1
    fi

    # GNU Wget 1.x only speaks HTTP/1.1; wget2 negotiates HTTP/2 via ALPN
    HAS_WGET2=false
    if want wget2 && command -v wget2 >/dev/null 2>&1; then
        local negotiation
        # shellcheck disable=SC2086
        negotiation=$(wget2 -d $WGET2_OPTS "https://${SERVER_IP}:${HTTP2_PORT}/health" 2>&1 || true)
        if [[ "$negotiation" == *"accepted protocol 'h2'"* ]]; then
            echo -e "✓ Wget2 (HTTP/2): Available ($(wget2 --version 2>&1 | head -n1 | cut -d' ' -f1-3))"
            HAS_WGET2=true
        else
            echo -e "${YELLOW}- Wget2: server didn't negotiate HTTP/2 (skipped)${NC}"
        fi
    else
        echo -e "${YELLOW}- Wget2: skipped${NC}"
    fi

    # aioquic is a library only; aioquic-get.py is the client. Prefer the venv next to it.
    HAS_AIOQUIC=false
    AIOQUIC_PY="python3"
    if [ -x "$SCRIPT_DIR/venv/bin/python" ]; then
        AIOQUIC_PY="$SCRIPT_DIR/venv/bin/python"
    fi
    if want aioquic && "$AIOQUIC_PY" -c "import aioquic" >/dev/null 2>&1; then
        echo -e "✓ aioquic (HTTP/3 Python): Available ($("$AIOQUIC_PY" -c "import aioquic; print(aioquic.__version__)") via $AIOQUIC_PY)"
        HAS_AIOQUIC=true
    else
        echo -e "${YELLOW}- aioquic: skipped${NC}"
    fi

    HAS_QUICHE=false
    QUICHE_BIN="$(command -v quiche-client || true)"
    if [ -z "$QUICHE_BIN" ] && [ -x "$SCRIPT_DIR/../quiche-client" ]; then
        QUICHE_BIN="$SCRIPT_DIR/../quiche-client"
    fi
    if want quiche && [ -n "$QUICHE_BIN" ]; then
        echo -e "✓ Quiche (HTTP/3): Available ($QUICHE_BIN)"
        HAS_QUICHE=true
    else
        echo -e "${YELLOW}- Quiche: skipped${NC}"
    fi

    echo -e "Runs: ${RUNS} | Per-request timeout: ${REQ_TIMEOUT}s\n"
}

# Prints "<median> <mean> <min> <max> <failed runs>" over successful runs (NA when none succeeded).
# $1 = successful times, one per line
summarize() {
    local times="$1" fail="$2"
    printf '%s\n' "$times" | awk 'NF' | sort -g | awk -v fail="$fail" '
        { v[++n] = $1; sum += $1 }
        END {
            if (n == 0) { printf "NA NA NA NA %d", fail; exit }
            median = (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
            printf "%.4f %.4f %.4f %.4f %d", median, sum / n, v[1], v[n], fail
        }'
}

# Uses curl's own time_total
avg_curl() {
    local times="" fail=0 t
    for _ in $(seq 1 "$RUNS"); do
        if t=$(curl "$@" -k -s -o /dev/null --max-time "$REQ_TIMEOUT" -w "%{time_total}" 2>/dev/null); then
            times+="$t"$'\n'
        else
            fail=$((fail + 1))
        fi
    done
    summarize "$times" "$fail"
}

# Wall-clock time of an external client
avg_wall() {
    local times="" fail=0 start end
    for _ in $(seq 1 "$RUNS"); do
        start=$(date +%s.%N)
        if timeout "$REQ_TIMEOUT" "$@" >/dev/null 2>&1; then
            end=$(date +%s.%N)
            times+="$(awk "BEGIN {print $end - $start}")"$'\n'
        else
            fail=$((fail + 1))
        fi
    done
    summarize "$times" "$fail"
}

# wget2's own stats: TLS handshake + transfer time (ms), which matches curl's
# time_total without wget2's ~90ms process start-up. Runs that didn't use h2 count as failed.
avg_wget2() {
    local url="$1" times="" fail=0 tls xfer alpn
    for _ in $(seq 1 "$RUNS"); do
        rm -f "$STATS_DIR/site.csv" "$STATS_DIR/tls.csv"
        # shellcheck disable=SC2086
        if timeout "$REQ_TIMEOUT" wget2 $WGET2_OPTS \
                --stats-site="csv:$STATS_DIR/site.csv" --stats-tls="csv:$STATS_DIR/tls.csv" "$url" 2>/dev/null \
            && alpn=$(awk -F, 'NR == 1 {print $6}' "$STATS_DIR/tls.csv" 2>/dev/null) && [ "$alpn" = "h2" ] \
            && tls=$(awk -F, 'NR == 1 {print $NF}' "$STATS_DIR/tls.csv") \
            && xfer=$(awk -F, 'NR == 2 {print $9}' "$STATS_DIR/site.csv") \
            && [ -n "$tls" ] && [ -n "$xfer" ]; then
            times+="$(awk "BEGIN {print ($tls + $xfer) / 1000}")"$'\n'
        else
            fail=$((fail + 1))
        fi
    done
    summarize "$times" "$fail"
}

# Time printed by the client itself (excludes interpreter start-up)
avg_reported() {
    local times="" fail=0 t
    for _ in $(seq 1 "$RUNS"); do
        if t=$(timeout "$REQ_TIMEOUT" "$@" 2>/dev/null) && [ -n "$t" ]; then
            times+="$t"$'\n'
        else
            fail=$((fail + 1))
        fi
    done
    summarize "$times" "$fail"
}

record() {
    local file="$1" client="$2" proto="$3" result="$4"
    local median mean min max fail
    read -r median mean min max fail <<< "$result"
    printf "%-10s | %-8s | %-9s | %-10s | %-17s | %s\n" "$file" "$client" "$proto" "$median" "$min-$max" "$fail"
    echo "Single-Stream,$file,$DELAY,$LOSS,$client,$proto,$median,$mean,$min,$max,$fail" >> "$CSV_FILE"
}

check_tools

echo -e "${CYAN}Testing connection to Server https://${SERVER_IP}:${HTTP2_PORT} ...${NC}"
if ! curl -k -s --max-time 3 "https://${SERVER_IP}:${HTTP2_PORT}/health" | grep -q "HTTP/2"; then
    echo -e "${RED}✗ Cannot connect to HTTP/2 server at https://${SERVER_IP}:${HTTP2_PORT}/health${NC}" >&2
    echo -e "${YELLOW}Please make sure the nginx containers are running on the server (${SERVER_IP})!${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Server connection verified.${NC}\n"

echo "Scenario,File,Delay,Loss,Client,Protocol,MedianTime_Sec,MeanTime_Sec,MinTime_Sec,MaxTime_Sec,FailedRuns" > "$CSV_FILE"

echo -e "${GREEN}========================================================================${NC}"
echo -e "${GREEN}           SCENARIO 1: SINGLE-STREAM REQUEST BENCHMARK                  ${NC}"
echo -e "${GREEN}  Server: ${SERVER_IP} (H2: ${HTTP2_PORT}, H3: ${HTTP3_PORT}) | Runs: ${RUNS}${NC}"
echo -e "${GREEN}  Server condition (label): Delay=${DELAY} Loss=${LOSS}${NC}"
echo -e "${GREEN}  Clients: ${CLIENTS[*]}${NC}"
echo -e "${GREEN}========================================================================${NC}"
printf "%-10s | %-8s | %-9s | %-10s | %-17s | %s\n" "File" "Client" "Protocol" "Median (s)" "Min-Max (s)" "Failed"
echo "----------------------------------------------------------------"

for file in "${FILES[@]}"; do
    h2_url="https://${SERVER_IP}:${HTTP2_PORT}/resources/single/${file}"
    h3_url="https://${SERVER_IP}:${HTTP3_PORT}/resources/single/${file}"

    if want curl-h2; then
        record "$file" "Curl" "HTTP/2" "$(avg_curl --http2 "$h2_url")"
    fi
    if want curl-h3; then
        record "$file" "Curl" "HTTP/3" "$(avg_curl --http3-only "$h3_url")"
    fi
    if [ "$HAS_WGET2" = true ]; then
        record "$file" "Wget2" "HTTP/2" "$(avg_wget2 "$h2_url")"
    fi
    if [ "$HAS_AIOQUIC" = true ]; then
        record "$file" "aioquic" "HTTP/3" "$(avg_reported "$AIOQUIC_PY" "$SCRIPT_DIR/aioquic-get.py" --insecure "$h3_url")"
    fi
    if [ "$HAS_QUICHE" = true ]; then
        # --wire-version 1: the default GREASE version forces an extra version-negotiation round trip
        record "$file" "Quiche" "HTTP/3" "$(avg_wall "$QUICHE_BIN" --no-verify --wire-version 1 "$h3_url")"
    fi
    echo "----------------------------------------------------------------"
done

echo -e "\n${GREEN}✓ Scenario 1 Benchmark completed!${NC}"
echo -e "Results saved to: ${CYAN}${CSV_FILE}${NC}"
