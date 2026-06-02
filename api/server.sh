#!/bin/bash
# SMC Cloud API Server - uses Flask if available, else simple socat/nc echo
API_PORT=${PORT:-5000}

log() { echo "[api] $$ $(date '+%H:%M:%S') $*"; }

# Simple GET-only server using socat (responds with JSON for all requests)
simple_server() {
    log "Starting simple socat HTTP server on 0.0.0.0:$API_PORT"
    while true; do
        RESP=$(cat <<'HTTPEOF'
HTTP/1.1 200 OK
Content-Type: application/json
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: GET, POST, OPTIONS
Access-Control-Allow-Headers: *

{"status":"ok","mode":"simple","note":"Use Python for full functionality"}
HTTPEOF
)
        # Remove leading/trailing whitespace
        echo "$RESP" | socat - TCP-LISTEN:$API_PORT,reuseaddr,fork 2>/dev/null
    done
}

# Start simple socat server in background
simple_server &
SIMPLE_PID=$!
sleep 1

log "Simple server PID: $SIMPLE_PID"

# Keep running
wait $SIMPLE_PID
