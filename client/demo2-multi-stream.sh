#!/usr/bin/env bash
# ==============================================================================
# Client Benchmark Runner: Scenario 2 - Multi-Stream (20 x 1MB)
# Run this on Kali VM / Client machine
#
# Delay/loss is applied on the SERVER only (scripts/set-network-condition-linux.sh,
# run via the netem helper). This script measures whatever condition the server applies
# and labels the CSV with the DELAY/LOSS you pass, so pass the same values you
# set on the server:
#   results-demo2_delay<DELAY>_loss<LOSS>.csv
#
# Usage:
#   ./demo2-multi-stream.sh [SERVER_IP] [DELAY] [LOSS]
#   RUNS=3 ./demo2-multi-stream.sh 10.0.10.140 0ms 8%
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SERVER_IP="${1:-${SERVER_IP:-10.0.10.140}}"
DELAY="${2:-${DELAY:-0ms}}"
LOSS="${3:-${LOSS:-0%}}"
HTTP2_PORT="${HTTP2_PORT:-8443}"
HTTP3_PORT="${HTTP3_PORT:-8444}"
RUNS="${RUNS:-5}"
# A transfer slower than this counts as failed instead of stalling the run
REQ_TIMEOUT="${REQ_TIMEOUT:-120}"
STREAMS=20

CSV_FILE="${SCRIPT_DIR}/results-demo2_delay${DELAY}_loss${LOSS//%/pct}.csv"
URL_H2="https://${SERVER_IP}:${HTTP2_PORT}/resources/multi/file-[1-${STREAMS}].bin"
URL_H3="https://${SERVER_IP}:${HTTP3_PORT}/resources/multi/file-[1-${STREAMS}].bin"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Prints "<avg batch s> <avg per-stream s over successful transfers|NA> <failed transfers> <max connections per batch>"
# No --parallel-immediate: that option makes curl open a new connection per transfer instead of
# multiplexing, which would turn this into 20 independent connections with no head-of-line blocking.
measure_batch() {
    local proto_flag="$1" url="$2"
    local batch_total=0 ok_time=0 ok_count=0 failed=0 max_conns=0 start end timings conns
    for _ in $(seq 1 "$RUNS"); do
        start=$(date +%s.%N)
        timings=$(curl "$proto_flag" --parallel --parallel-max "$STREAMS" -k -s -o /dev/null \
            --max-time "$REQ_TIMEOUT" -w "%{time_total} %{exitcode} %{num_connects}\n" "$url" 2>/dev/null || true)
        end=$(date +%s.%N)
        batch_total=$(awk "BEGIN {print $batch_total + $end - $start}")
        read -r ok_time ok_count failed <<< "$(echo "$timings" | awk -v t="$ok_time" -v c="$ok_count" -v f="$failed" \
            'NF == 3 { if ($2 == 0) { t += $1; c++ } else f++ } END { print t, c, f }')"
        conns=$(echo "$timings" | awk 'NF == 3 { s += $3 } END { print s + 0 }')
        [ "$conns" -gt "$max_conns" ] && max_conns=$conns
    done
    local expected=$((RUNS * STREAMS))
    if [ "$ok_count" -lt "$expected" ]; then
        failed=$((expected - ok_count))
    fi
    if [ "$ok_count" -gt 0 ]; then
        awk "BEGIN {printf \"%.4f %.4f %d %d\", $batch_total / $RUNS, $ok_time / $ok_count, $failed, $max_conns}"
    else
        awk "BEGIN {printf \"%.4f NA %d %d\", $batch_total / $RUNS, $failed, $max_conns}"
    fi
}

echo -e "${CYAN}Testing connection to Server https://${SERVER_IP}:${HTTP2_PORT} ...${NC}"
if ! curl -k -s --max-time 3 "https://${SERVER_IP}:${HTTP2_PORT}/health" | grep -q "HTTP/2"; then
    echo -e "${RED}✗ Cannot connect to HTTP/2 server at https://${SERVER_IP}:${HTTP2_PORT}/health${NC}" >&2
    echo -e "${YELLOW}Please make sure Docker is running on the server (${SERVER_IP})!${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Server connection verified.${NC}\n"

echo -e "${GREEN}============================================================================${NC}"
echo -e "${GREEN}   SCENARIO 2: MULTI-STREAM REQUEST (${STREAMS} x 1MB) - HOL BLOCKING BENCHMARK${NC}"
echo -e "${GREEN}   Server: ${SERVER_IP} (H2: ${HTTP2_PORT}, H3: ${HTTP3_PORT}) | Runs: ${RUNS}${NC}"
echo -e "${GREEN}   Server condition (label): Delay=${DELAY} Loss=${LOSS}${NC}"
echo -e "${GREEN}============================================================================${NC}"

read -r h2_batch h2_stream h2_failed h2_conns <<< "$(measure_batch --http2 "$URL_H2")"
read -r h3_batch h3_stream h3_failed h3_conns <<< "$(measure_batch --http3-only "$URL_H3")"

if awk "BEGIN {exit !($h3_batch > 0)}"; then
    speedup=$(awk "BEGIN {printf \"%.2fx\", $h2_batch / $h3_batch}")
else
    speedup="N/A"
fi

echo "Scenario,Delay,Loss,Protocol,BatchCompletionTime_Sec,PerStreamAvgTime_Sec,FailedTransfers,MaxConnectionsPerBatch,Speedup" > "$CSV_FILE"
echo "Multi-Stream,$DELAY,$LOSS,HTTP/2,$h2_batch,$h2_stream,$h2_failed,$h2_conns,Base" >> "$CSV_FILE"
echo "Multi-Stream,$DELAY,$LOSS,HTTP/3,$h3_batch,$h3_stream,$h3_failed,$h3_conns,$speedup" >> "$CSV_FILE"

printf "%-7s | %-14s | %-18s | %-6s | %-5s | %s\n" "Proto" "Batch Time (s)" "Per-Stream Avg (s)" "Failed" "Conns" "Speedup"
echo "------------------------------------------------------------------------------------"
printf "%-7s | %-14s | %-18s | %-6s | %-5s | %s\n" "HTTP/2" "$h2_batch" "$h2_stream" "$h2_failed" "$h2_conns" "Base"
printf "%-7s | %-14s | %-18s | %-6s | %-5s | %s\n" "HTTP/3" "$h3_batch" "$h3_stream" "$h3_failed" "$h3_conns" "$speedup"

for pair in "HTTP/2:$h2_conns" "HTTP/3:$h3_conns"; do
    if [ "${pair#*:}" -gt 1 ]; then
        echo -e "${YELLOW}! ${pair%%:*} used up to ${pair#*:} connections per batch (expected 1): streams were not all multiplexed.${NC}" >&2
    fi
done

echo -e "\n${GREEN}✓ Scenario 2 Benchmark completed!${NC}"
echo -e "Results saved to: ${CYAN}${CSV_FILE}${NC}"
