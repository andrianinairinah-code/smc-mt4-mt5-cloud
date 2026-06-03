#!/bin/bash
# ============================================================
# SMC Cloud - MT5 + API Startup Script
# ============================================================

WINE_LOG="/tmp/wine.log"
API_LOG="/tmp/api.log"
> "$WINE_LOG"
> "$API_LOG"

VNC_PORT=5901
NOVNC_PORT=6080
NGINX_PORT=6901
API_PORT=8080

# Determine Python command
PYTHON_CMD=""
for cmd in python3 python; do
    if command -v $cmd &>/dev/null; then
        PYTHON_CMD=$cmd
        break
    fi
done
[ -z "$PYTHON_CMD" ] && PYTHON_CMD="python3"  # fallback
DISPLAY_NUM=1
RESOLUTION=${SCREEN_RESOLUTION:-1024x768}
DEPTH=24

MT5_DIR="/home/headless/.wine/drive_c/Program Files/MetaTrader 5"
MT5_EXE="$MT5_DIR/terminal64.exe"
MT5_FILES_DIR="$MT5_DIR/MQL5/Files"

# ============================================================
# Step display functions (from original)
# ============================================================
STEP_NUM=0
TOTAL_STEPS=11
SPINNER_PID=""

spinner_start() {
    local msg="$1"
    (
        local spin_chars='|/-\'
        local first=true
        local i=0
        while true; do
            local char="${spin_chars:$i:1}"
            if [ "$first" = true ]; then
                printf " [%d/%d] %s %-45s\n" "$STEP_NUM" "$TOTAL_STEPS" "$char" "$msg ..."
                first=false
            else
                printf "\033[1A\r [%d/%d] %s %-45s\n" "$STEP_NUM" "$TOTAL_STEPS" "$char" "$msg ..."
            fi
            sleep 0.2
            i=$(( (i + 1) % ${#spin_chars} ))
        done
    ) &
    SPINNER_PID=$!
}

spinner_stop() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
    fi
}

step_start() {
    STEP_NUM=$((STEP_NUM + 1))
    spinner_start "$1"
}

step_done() {
    spinner_stop
    printf "\033[1A\r [%d/%d] ✔  %-45s\n" "$STEP_NUM" "$TOTAL_STEPS" "$1"
}

step_fail() {
    spinner_stop
    printf "\033[1A\r [%d/%d] ✘  %-45s\n" "$STEP_NUM" "$TOTAL_STEPS" "$1"
}

# ============================================================
# Step 0: Immediate healthcheck server for Railway
# ============================================================
# MUST start before anything else - Railway healthcheck hits port 6901
# within seconds of container start. NoVNC/nginx aren't ready yet.
python3 -c "
import http.server, socketserver, json, os, sys

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'status':'ok','startup':'booting'}).encode())
    def do_HEAD(self):
        self.send_response(200)
        self.end_headers()
    def log_message(self,*a): pass

try:
    s = socketserver.TCPServer(('0.0.0.0', 6901), H)
    s.allow_reuse_address = True
    s.serve_forever()
except OSError as e:
    # Port 6901 might already be taken by base image's noVNC
    print(f'Healthcheck port 6901 busy: {e}', file=sys.stderr)
    # Try alternate port
    s = socketserver.TCPServer(('0.0.0.0', 8081), H)
    s.serve_forever()
" &
HEALTH_PID=$!
echo "   [0/11] Healthcheck server started (PID=$HEALTH_PID)"

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║   SMC Cloud - MT5 + API                     ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""

# ============================================================
# Step 1: Check Wine
# ============================================================
step_start "Checking Wine"
if command -v wine &> /dev/null; then
    WINE_VER=$(wine --version 2>>"$WINE_LOG")
    step_done "Wine OK ($WINE_VER)"
else
    step_fail "Wine is not installed"
    exit 1
fi

# ============================================================
# Step 2: Start VNC Server
# ============================================================
step_start "Starting VNC server"
mkdir -p ~/.vnc
echo "${VNC_PW:-password}" | vncpasswd -f > ~/.vnc/passwd 2>>"$WINE_LOG"
chmod 600 ~/.vnc/passwd

vncserver -kill :$DISPLAY_NUM 2>/dev/null || true
rm -rf /tmp/.X11-unix/X$DISPLAY_NUM /tmp/.X$DISPLAY_NUM-lock

vncserver :$DISPLAY_NUM -geometry $RESOLUTION -depth $DEPTH -rfbport $VNC_PORT -localhost no >>"$WINE_LOG" 2>&1
export DISPLAY=:$DISPLAY_NUM

for i in {1..10}; do
    if xset q > /dev/null 2>&1; then break; fi
    sleep 1
done
step_done "VNC server started (port $VNC_PORT)"

# ============================================================
# Step 3: Start Desktop Environment
# ============================================================
step_start "Starting desktop environment"
openbox >>"$WINE_LOG" 2>&1 &
tint2 >>"$WINE_LOG" 2>&1 &
sleep 1
step_done "Desktop environment started"

# ============================================================
# Step 4: Start noVNC + nginx reverse proxy
# ============================================================
step_start "Starting noVNC + nginx"

# Kill ALL stale novnc/websockify from base image entrypoint (blocks port 6901)
# SIGKILL (-9) ensures they die immediately vs SIGTERM which can linger
pkill -9 -f "novnc_proxy" 2>/dev/null || true
pkill -9 -f "websockify" 2>/dev/null || true
sleep 2

# Kill healthcheck server that was holding port 6901 (started in Step 0)
kill $HEALTH_PID 2>/dev/null || true

# Wait for port 6901 to be fully released (TIME_WAIT can delay rebind)
for i in {1..10}; do
    if ! nc -z 127.0.0.1 $NGINX_PORT 2>/dev/null; then
        echo "Port $NGINX_PORT free after ${i}s" >> "$WINE_LOG"
        break
    fi
    sleep 1
done

# Start noVNC on internal port 6080 (NOT 6901 — nginx will proxy there)
/opt/noVNC/utils/novnc_proxy --vnc localhost:$VNC_PORT --listen $NOVNC_PORT --web /opt/noVNC >>"$WINE_LOG" 2>&1 &
NOVNC_PID=$!

# Wait for 6080 to be listening before starting nginx (up to 10s)
for i in {1..10}; do
    if nc -z 127.0.0.1 $NOVNC_PORT 2>/dev/null; then
        echo "noVNC listening on port $NOVNC_PORT after ${i}s" >> "$WINE_LOG"
        break
    fi
    sleep 1
done

# Start nginx on port 6901 with retry logic
NGINX_OK=false
for attempt in {1..5}; do
    sudo nginx -c /etc/nginx/nginx.conf >>"$WINE_LOG" 2>&1
    NGINX_EXIT=$?
    sleep 1
    if [ $NGINX_EXIT -eq 0 ] && pgrep -f "nginx: master" > /dev/null 2>&1; then
        echo "nginx started on attempt $attempt" >> "$WINE_LOG"
        NGINX_OK=true
        break
    fi
    # Kill stale nginx before retry
    sudo nginx -s quit 2>/dev/null || true
    pkill -9 -f "nginx" 2>/dev/null || true
    sleep 2
    echo "nginx attempt $attempt failed (exit $NGINX_EXIT), retrying..." >> "$WINE_LOG"
done

if [ "$NGINX_OK" = true ]; then
    step_done "noVNC + nginx ready (port $NGINX_PORT → noVNC:$NOVNC_PORT, API:$API_PORT)"
else
    step_fail "nginx failed after 5 attempts, starting noVNC directly on $NGINX_PORT"
    pkill -9 -f "novnc_proxy" 2>/dev/null; sleep 1
    /opt/noVNC/utils/novnc_proxy --vnc localhost:$VNC_PORT --listen $NGINX_PORT --web /opt/noVNC >>"$WINE_LOG" 2>&1 &
fi

# ============================================================
# Step 5: Start API Server (early - do not block on MT install)
# ============================================================
step_start "Starting API server on port $API_PORT"
cd /app/api

API_PID=""
# Stage 1: Try Python API server (full functionality)
echo "=== API Stage 1: Python server ==="
if command -v $PYTHON_CMD &>/dev/null; then
    echo "  Python version: $($PYTHON_CMD --version 2>&1)"
    cd /app/api
    API_PORT=$API_PORT nohup $PYTHON_CMD server.py >> "$API_LOG" 2>&1 &
    PY_PID=$!
    sleep 3
    if kill -0 $PY_PID 2>/dev/null; then
        echo "  Python API PID=$PY_PID"
        curl -s --connect-timeout 2 http://127.0.0.1:$API_PORT/status && echo "  Python API WORKS!" || echo "  curl check failed"
        API_PID=$PY_PID
        step_done "API server (Python) started (port $API_PORT)"
    else
        echo "  Python API DIED, trying nc fallback" >&2
    fi
fi

# Stage 2: Fallback to nc echo server if Python failed
if [ -z "$API_PID" ] && command -v nc &>/dev/null; then
    echo "=== API Stage 2: nc fallback ==="
    while true; do echo -ne "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"status\":\"ok\",\"mode\":\"nc\"}" | nc -l -p $API_PORT -q 1; done &
    NC_PID=$!
    sleep 2
    if kill -0 $NC_PID 2>/dev/null; then
        curl -s --connect-timeout 2 http://127.0.0.1:$API_PORT/ && echo "  nc fallback WORKS!" || true
        API_PID=$NC_PID
        step_done "API server (nc fallback) started (port $API_PORT)"
    fi
fi

# Final check
if [ -z "$API_PID" ]; then
    step_fail "API server failed to start"
fi

# Final: show errors
if [ -z "$API_PID" ]; then
    step_fail "API server failed to start"
    echo "=== Last 20 lines of API log ===" | tee -a "$API_LOG"
    tail -20 "$API_LOG" 2>/dev/null
fi

# ============================================================
# Step 6: Initialize Wine
# ============================================================
step_start "Initializing Wine environment"
if [ -d "$HOME/.wine" ]; then
    sudo chown -R $(whoami):$(whoami) "$HOME/.wine" 2>>"$WINE_LOG" 2>/dev/null || true
fi
WINEDLLOVERRIDES="mscoree,mshtml=" wineboot -i >>"$WINE_LOG" 2>&1
while pgrep -u $(whoami) wineboot >/dev/null 2>&1; do sleep 1; done
step_done "Wine environment initialized"

# ============================================================
# Step 7: Install MetaTrader 5 (if missing)
# ============================================================
if [ ! -f "$MT5_EXE" ]; then
    step_start "Installing MetaTrader 5 (this may take a few minutes)"
    MT5_INSTALLER="/home/headless/mt5setup.exe"
    wget -q "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe" -O "$MT5_INSTALLER" 2>>"$WINE_LOG"
    wine "$MT5_INSTALLER" /auto >>"$WINE_LOG" 2>&1 &
    for i in $(seq 1 120); do
        [ -f "$MT5_EXE" ] && break
        sleep 5
    done
    rm -f "$MT5_INSTALLER"
    mkdir -p "/home/headless/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Include/SMC"
    if [ -f "$MT5_EXE" ]; then
        step_done "MetaTrader 5 installed"
    else
        step_fail "MetaTrader 5 installation timed out"
    fi
else
    step_start "Checking MetaTrader 5"
    sleep 0.5
    step_done "MetaTrader 5 already installed"
fi

# ============================================================
# Step 8: Start MetaTrader 5
# ============================================================
step_start "Starting MetaTrader 5"
wineserver -p >>"$WINE_LOG" 2>&1 &

if [ -f "$MT5_EXE" ]; then
    wine "$MT5_EXE" /config:"$MT5_FILES_DIR\mt5.ini" >>"$WINE_LOG" 2>&1 &
    for i in $(seq 1 30); do
        if pgrep -f "terminal64.exe" > /dev/null 2>&1; then break; fi
        sleep 2
    done
    if pgrep -f "terminal64.exe" > /dev/null 2>&1; then
        step_done "MetaTrader 5 started"
    else
        step_fail "MetaTrader 5 failed to start"
    fi
else
    step_fail "MT5 not found at $MT5_EXE"
fi

# ============================================================
# Step 9: Configure servers.dat
# ============================================================
step_start "Checking servers.dat"
SERVERS_DAT="$MT5_DIR/Config/servers.dat"
mkdir -p "$MT5_DIR/Config"
if [ ! -f "$SERVERS_DAT" ] || [ "$(stat -c%s "$SERVERS_DAT" 2>/dev/null || echo 0)" -lt 1048576 ]; then
    wget -q "https://github.com/hudsonventura/MT5_Docker/raw/refs/heads/main/servers.dat" -O "$SERVERS_DAT" 2>>"$WINE_LOG"
fi
step_done "servers.dat ready"

# ============================================================
# Ready!
# ============================================================
step_start "Finalizing"
echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║              ✔  Ready!                       ║"
echo "  ╠══════════════════════════════════════════════╣"
echo "  ║  VNC:   localhost:$VNC_PORT                       ║"
echo "  ║  Web:   http://localhost:$NGINX_PORT/vnc.html       ║"
echo "  ║  API:   http://localhost:$NGINX_PORT/api/           ║"
echo "  ║  Pass:  ${VNC_PW:-password}                      ║"
echo "  ╠══════════════════════════════════════════════╣"
echo "  ║  MT5: $MT5_DIR          ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
echo "  Endpoints:"
echo "    POST /upload/ea      - Upload MT5 EA (.ex5)"
echo "    POST /upload/include - Upload .mqh include"
echo "    GET  /status         - Service status"
echo "    GET  /files/ea       - List installed EAs"
echo ""

step_done "Ready"

# ============================================================
# Monitor all processes
# ============================================================
while true; do
    # Check API
    if ! kill -0 $API_PID 2>/dev/null; then
        echo "API server died, restarting..."
        cd /app/api && API_PORT=$API_PORT nohup $PYTHON_CMD server.py >> "$API_LOG" 2>&1 &
        API_PID=$!
    fi

    # Check MT5
    MT5_OK=false
    if pgrep -f "terminal64.exe" > /dev/null 2>&1; then
        MT5_OK=true
    fi
    if [ "$MT5_OK" = false ] && [ -f "$MT5_EXE" ]; then
        echo "MT5 died, restarting..."
        wine "$MT5_EXE" /config:"$MT5_FILES_DIR\mt5.ini" >> "$WINE_LOG" 2>&1 &
    fi

    sleep 15
done
