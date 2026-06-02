#!/bin/bash
# SMC Cloud API Server (pure bash, no Python required)
# Uses ncat or nc to serve HTTP on port 5000

API_PORT=${PORT:-5000}
WINE_DIR="${WINEPREFIX:-$HOME/.wine}"
MT5_EXPERTS="$WINE_DIR/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
MT5_INCLUDES="$WINE_DIR/drive_c/Program Files/MetaTrader 5/MQL5/Include"
MT4_EXPERTS="$WINE_DIR/drive_c/Program Files/HFM MT4/MQL4/Experts"
MT4_INCLUDES="$WINE_DIR/drive_c/Program Files/HFM MT4/MQL4/Include"

log() { echo "[api] $(date '+%H:%M:%S') $*"; }

# Find netcat
NC=""
for cmd in ncat nc.traditional nc; do
    if command -v $cmd &>/dev/null; then
        NC=$cmd
        break
    fi
done
if [ -z "$NC" ]; then
    log "ERROR: no netcat found"
    # Fallback to bash TCP
    NC="bash"
fi

response() {
    local status="$1" ct="$2" body="$3"
    echo "HTTP/1.1 $status OK"
    echo "Content-Type: $ct"
    echo "Content-Length: ${#body}"
    echo "Access-Control-Allow-Origin: *"
    echo "Access-Control-Allow-Methods: GET, POST, OPTIONS"
    echo "Access-Control-Allow-Headers: *"
    echo ""
    echo -n "$body"
}

json_resp() {
    response 200 "application/json" "$(echo "$*")"
}

json_err() {
    response "${2:-400}" "application/json" "{\"error\":\"$1\"}"
}

handle_request() {
    read -r request_line
    [ -z "$request_line" ] && return
    method=$(echo "$request_line" | cut -d' ' -f1)
    path=$(echo "$request_line" | cut -d' ' -f2 | sed 's|/[^/]*$||;s|/$||')
    [ -z "$path" ] && path="/"

    # Read headers
    while read -r header; do
        [ -z "$(echo "$header" | tr -d '\r')" ] && break
    done

    case "$method:$path" in
        GET:/status)
            mt5="false"; mt4="false"
            ps aux 2>/dev/null | grep -qi "terminal64" && mt5="true"
            ps aux 2>/dev/null | grep -qi "terminal.exe" && mt4="true"
            json_resp "{\"mt5_running\":$mt5,\"mt4_running\":$mt4,\"status\":\"ok\"}"
            ;;
        GET:/files/ea)
            mkdir -p "$MT5_EXPERTS/SMC" "$MT4_EXPERTS/SMC"
            m5=$(ls "$MT5_EXPERTS"/*.{ex5,mq5} 2>/dev/null | xargs -I{} basename {} | tr '\n' ',' | sed 's/,$//')
            m4=$(ls "$MT4_EXPERTS"/*.{ex4,mq4} 2>/dev/null | xargs -I{} basename {} | tr '\n' ',' | sed 's/,$//')
            m5_json=$(echo "$m5" | sed 's/[^,]*/"&"/g')
            m4_json=$(echo "$m4" | sed 's/[^,]*/"&"/g')
            [ -z "$m5_json" ] && m5_json="[]" || m5_json="[$m5_json]"
            [ -z "$m4_json" ] && m4_json="[]" || m4_json="[$m4_json]"
            json_resp "{\"mt5\":$m5_json,\"mt4\":$m4_json}"
            ;;
        POST:/restart/mt5)
            pkill -f terminal64 2>/dev/null
            pkill -f metaeditor 2>/dev/null
            wine "C:\\Program Files\\MetaTrader 5\\terminal64.exe" &
            json_resp "{\"status\":\"restarted\",\"target\":\"MT5\"}"
            ;;
        POST:/restart/mt4)
            pkill -f terminal.exe 2>/dev/null
            wine "C:\\Program Files\\HFM MT4\\terminal.exe" &
            json_resp "{\"status\":\"restarted\",\"target\":\"MT4\"}"
            ;;
        *)
            json_err "Not found" 404
            ;;
    esac
}

log "Starting API server on 0.0.0.0:$API_PORT"

if [ "$NC" = "bash" ]; then
    # Bash built-in TCP server (requires bash compiled with /dev/tcp support)
    while true; do
        handle_request < /dev/tcp/0.0.0.0/$API_PORT
    done
else
    while true; do
        handle_request | $NC -l -p $API_PORT -q 1 2>/dev/null
    done
fi
