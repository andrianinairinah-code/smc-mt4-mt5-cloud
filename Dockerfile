FROM hudsonventura/mt5:2.3

USER root

# Install Python3 + pip + Flask + wget + nginx
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3-pip \
        python3-flask \
        wget \
        nginx \
    && rm -rf /var/lib/apt/lists/* && \
    python3 -m pip install flask flask-cors gunicorn --break-system-packages --quiet 2>&1 || echo "[WARN] pip install flask-cors/gunicorn failed (non-fatal)"

# Copy API server
COPY api/ /app/api/

# Install Python deps
RUN python3 -m pip install -r /app/api/requirements.txt --break-system-packages --quiet 2>&1 || echo "[WARN] pip install requirements.txt failed (non-fatal)"

# Also create python symlink in case some scripts use 'python'
RUN sudo ln -sf $(which python3) /usr/local/bin/python 2>/dev/null; \
    sudo ln -sf $(which python3) /usr/bin/python 2>/dev/null; true

# Verify Flask is importable
RUN python3 -c "import flask; print('Flask OK')" 2>&1 || echo "[WARN] Flask import check failed"

# Copy nginx config
COPY nginx.conf /etc/nginx/nginx.conf
RUN chmod 644 /etc/nginx/nginx.conf

USER headless
WORKDIR /home/headless

# Create SMC include directories for MT5 and MT4 (will be populated at runtime)
RUN mkdir -p "/home/headless/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Include/SMC" && \
    mkdir -p "/home/headless/.wine/drive_c/Program Files/HFM MT4/MQL4/Include/SMC" 2>/dev/null; true

# Copy custom start script
COPY scripts/start.sh /start.sh
RUN sudo chmod +x /start.sh

EXPOSE 5901 6901 5000

CMD ["/bin/bash", "/start.sh"]
