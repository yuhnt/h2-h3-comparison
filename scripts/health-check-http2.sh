#!/bin/sh

# Health check script for HTTP/2 server
set -e

HOST="localhost"
PORT="8443"
TIMEOUT=5

if pgrep -x "nginx" > /dev/null; then
    curl -k -s --max-time $TIMEOUT "https://$HOST:$PORT/health" | grep -q "HTTP/2 Server OK"
    exit $?
fi

exit 1
