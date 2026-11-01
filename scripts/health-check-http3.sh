#!/bin/sh

# Health check script for HTTP/3 server
set -e

HOST="localhost"
PORT="8444"
TIMEOUT=5

if pgrep -x "nginx" > /dev/null; then
    curl -k -s --max-time $TIMEOUT "https://$HOST:$PORT/health" | grep -q "HTTP/3 Server OK"
    exit $?
fi

exit 1
