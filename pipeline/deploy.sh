#!/bin/bash
# ============================================================
# SMC Cloud - Deploy EA to Railway
# Usage:
#   ./deploy.sh --ea SMC_H8_M1_v212_RegimeZonePlus --mt5
#   ./deploy.sh --ea SMC_H8_M1_v213_RegimeZonePlus_MT4 --mt4
#   ./deploy.sh --all   # Deploy all EAs + includes
# ============================================================

set -e

API_URL="${API_URL:-https://mt5-production-1d95.up.railway.app}"
SMC_DIR="${SMC_DIR:-$(cd ../../ && pwd)}"
MT5_SRC="$SMC_DIR/SMC_M1"
MT4_SRC="$SMC_DIR/M1_MT4"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

# Parse args
DEPLOY_MT5=false
DEPLOY_MT4=false
DEPLOY_ALL=false
EA_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ea) EA_NAME="$2"; shift 2 ;;
        --mt5) DEPLOY_MT5=true; shift ;;
        --mt4) DEPLOY_MT4=true; shift ;;
        --all) DEPLOY_ALL=true; shift ;;
        --url) API_URL="$2"; shift 2 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

if [ "$DEPLOY_ALL" = true ]; then
    DEPLOY_MT5=true
    DEPLOY_MT4=true
fi

# Check API reachable
echo "Checking API at $API_URL..."
if ! curl -sf "$API_URL/status" > /dev/null 2>&1; then
    error "Cannot reach API at $API_URL"
    echo "Make sure the Railway service is running."
    echo "Set API_URL if different: --url https://your-service.up.railway.app"
    exit 1
fi
info "API reachable"

# Deploy MT5 EA
if [ "$DEPLOY_MT5" = true ]; then
    if [ -n "$EA_NAME" ]; then
        # Single EA
        EA_FILE="$MT5_SRC/EAs/$EA_NAME.ex5"
        if [ ! -f "$EA_FILE" ]; then
            EA_FILE="$MT5_SRC/EAs/$EA_NAME.mq5"
            if [ -f "$EA_FILE" ]; then
                warn "Source file found, compiling..."
                # Try to compile via MetaEditor
                METAEDITOR="/c/Program Files/MetaTrader 5/MetaEditor64.exe"
                if [ -f "$METAEDITOR" ]; then
                    "$METAEDITOR" /compile:"$EA_FILE" /log 2>/dev/null || true
                fi
                EA_FILE="${EA_FILE%.mq5}.ex5"
            fi
        fi
        if [ ! -f "$EA_FILE" ]; then
            error "EA file not found: $EA_NAME"
            exit 1
        fi
        echo "Uploading $EA_FILE to MT5 Experts..."
        curl -sf -X POST -F "file=@$EA_FILE" "$API_URL/upload/ea" || {
            error "Upload failed"
            exit 1
        }
        info "EA uploaded"
    else
        warn "No EA name specified, skipping MT5 EA upload"
    fi

    # Upload includes
    INCLUDES_DIR="$MT5_SRC/INCLUDE"
    if [ -d "$INCLUDES_DIR" ]; then
        echo "Uploading MT5 includes..."
        for f in "$INCLUDES_DIR"/*.mqh; do
            [ -f "$f" ] || continue
            curl -sf -X POST -F "file=@$f" "$API_URL/upload/include" > /dev/null
            echo "  $(basename $f)"
        done
        info "Includes uploaded"
    fi

    # Also upload from CORE
    CORE_DIR="$MT5_SRC/CORE"
    if [ -d "$CORE_DIR" ]; then
        for f in "$CORE_DIR"/*.mqh; do
            [ -f "$f" ] || continue
            curl -sf -X POST -F "file=@$f" "$API_URL/upload/include" > /dev/null
        done
    fi

    # Restart MT5
    echo "Restarting MT5..."
    curl -sf -X POST "$API_URL/restart/mt5" > /dev/null
    info "MT5 restarted"
fi

# Deploy MT4 EA
if [ "$DEPLOY_MT4" = true ]; then
    if [ -n "$EA_NAME" ]; then
        EA_FILE="$MT4_SRC/EAs/$EA_NAME.ex4"
        if [ ! -f "$EA_FILE" ]; then
            EA_FILE="$MT4_SRC/EAs/$EA_NAME.mq4"
        fi
        if [ -f "$EA_FILE" ]; then
            echo "Uploading $(basename $EA_FILE) to MT4 Experts..."
            curl -sf -X POST -F "file=@$EA_FILE" "$API_URL/upload/ea4" || {
                error "Upload failed"
                exit 1
            }
            info "EA uploaded"
        else
            warn "MT4 EA not found: $EA_NAME"
        fi
    fi

    # Upload MT4 includes (STRUCTURE + CORE)
    for dir in "$MT4_SRC/STRUCTURE" "$MT4_SRC/CORE"; do
        if [ -d "$dir" ]; then
            for f in "$dir"/*.mqh; do
                [ -f "$f" ] || continue
                curl -sf -X POST -F "file=@$f" "$API_URL/upload/include" > /dev/null
            done
        fi
    done
    info "MT4 includes uploaded"

    # Restart MT4
    echo "Restarting MT4..."
    curl -sf -X POST "$API_URL/restart/mt4" > /dev/null
    info "MT4 restarted"
fi

echo ""
echo "============================================"
echo "  Deployment complete!"
echo "  Open VNC: $API_URL/vnc.html"
echo "============================================"
