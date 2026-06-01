#!/bin/bash
# ============================================================
# SMC Cloud - MT5 + MT4 + API Startup Script
# ============================================================

WINE_LOG="/tmp/wine.log"
API_LOG="/tmp/api.log"
> "$WINE_LOG"
> "$API_LOG"

VNC_PORT=5901
NOVNC_PORT=6080
NGINX_PORT=6901
API_PORT=${PORT:-5000}
DISPLAY_NUM=1
RESOLUTION=${SCREEN_RESOLUTION:-1024x768}
DEPTH=24

MT5_DIR="/home/headless/.wine/drive_c/Program Files/MetaTrader 5"
MT5_EXE="$MT5_DIR/terminal64.exe"
MT4_DIR="/home/headless/.wine/drive_c/Program Files/HFM MT4"
MT4_EXE="$MT4_DIR/terminal.exe"
MT5_FILES_DIR="$MT5_DIR/MQL5/Files"

# ============================================================
# Step display functions (from original)
# ============================================================
STEP_NUM=0
TOTAL_STEPS=12
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

echo ""
echo "  ╔══════════════════════════════════════════════╗"
echo "  ║   SMC Cloud - MT5 + MT4 + API               ║"
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
# Step 4: Start noVNC
# ============================================================
step_start "Starting noVNC web client"
/opt/noVNC/utils/novnc_proxy --vnc localhost:$VNC_PORT --listen $NOVNC_PORT --web /opt/noVNC >>"$WINE_LOG" 2>&1 &
sleep 1
step_done "noVNC started (internal port $NOVNC_PORT)"

# Start nginx reverse proxy (serves noVNC + Flask API on port 6901)
step_start "Starting nginx reverse proxy on port $NGINX_PORT"
sudo nginx -c /etc/nginx/nginx.conf >>"$WINE_LOG" 2>&1 &
sleep 1
if pgrep -f "nginx: master" > /dev/null 2>&1; then
    step_done "nginx reverse proxy started (port $NGINX_PORT)"
else
    step_fail "nginx failed to start, trying to use noVNC directly on port $NGINX_PORT"
    # Fallback: restart noVNC on the original port
    pkill -f novnc_proxy 2>/dev/null; sleep 1
    /opt/noVNC/utils/novnc_proxy --vnc localhost:$VNC_PORT --listen $NGINX_PORT --web /opt/noVNC >>"$WINE_LOG" 2>&1 &
fi

# ============================================================
# Step 5: Start API Server (early - do not block on MT install)
# ============================================================
step_start "Starting API server on port $API_PORT"
cd /app/api
nohup python3 server.py >> "$API_LOG" 2>&1 &
API_PID=$!
sleep 2
if kill -0 $API_PID 2>/dev/null; then
    step_done "API server started (port $API_PORT)"
else
    step_fail "API server failed to start"
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
# Step 8: Install HFM MT4 (if missing)
# ============================================================
if [ ! -f "$MT4_EXE" ]; then
    step_start "Installing HFM MetaTrader 4 (this may take a few minutes)"
    MT4_INSTALLER="/home/headless/mt4setup.exe"
    wget -q "https://download.mql5.com/cdn/web/hfmarketslimited/mt4/hfmarketssv4setup.exe" -O "$MT4_INSTALLER" 2>>"$WINE_LOG"
    wine "$MT4_INSTALLER" /verysilent /dir="C:\Program Files\HFM MT4" >>"$WINE_LOG" 2>&1 &
    for i in $(seq 1 60); do
        [ -f "$MT4_EXE" ] && break
        sleep 5
    done
    rm -f "$MT4_INSTALLER"
    mkdir -p "/home/headless/.wine/drive_c/Program Files/HFM MT4/MQL4/Include/SMC"
    if [ -f "$MT4_EXE" ]; then
        step_done "HFM MetaTrader 4 installed"
    else
        step_fail "HFM MT4 installation timed out"
    fi
else
    step_start "Checking HFM MetaTrader 4"
    sleep 0.5
    step_done "HFM MetaTrader 4 already installed"
fi

# ============================================================
# Step 9: Start MetaTrader 5
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
# Step 10: Start HFM MT4
# ============================================================
step_start "Starting HFM MetaTrader 4"
if [ -f "$MT4_EXE" ]; then
    wine "$MT4_EXE" >> "$WINE_LOG" 2>&1 &
    for i in $(seq 1 20); do
        if pgrep -f "terminal.exe" > /dev/null 2>&1; then break; fi
        sleep 2
    done
    if pgrep -f "terminal.exe" > /dev/null 2>&1; then
        step_done "HFM MetaTrader 4 started"
    else
        step_fail "HFM MT4 failed to start"
    fi
else
    step_fail "HFM MT4 not found at $MT4_EXE"
fi

# ============================================================
# Step 11: Configure servers.dat
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
echo "  ║  MT4: $MT4_DIR          ║"
echo "  ╚══════════════════════════════════════════════╝"
echo ""
echo "  Endpoints:"
echo "    POST /upload/ea      - Upload MT5 EA (.ex5)"
echo "    POST /upload/ea4     - Upload MT4 EA (.ex4)"
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
        cd /app/api && nohup python3 server.py >> "$API_LOG" 2>&1 &
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

    # Check MT4
    MT4_OK=false
    if pgrep -f "terminal.exe" > /dev/null 2>&1; then
        MT4_OK=true
    fi
    if [ "$MT4_OK" = false ] && [ -f "$MT4_EXE" ]; then
        echo "MT4 died, restarting..."
        wine "$MT4_EXE" >> "$WINE_LOG" 2>&1 &
    fi

    sleep 15
done
