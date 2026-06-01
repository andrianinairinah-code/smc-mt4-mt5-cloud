FROM hudsonventura/mt5:2.3

USER root

# Install Python3 + pip + Flask + wget
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3-pip \
        python3-flask \
        wget \
    && rm -rf /var/lib/apt/lists/* && \
    pip3 install flask-cors gunicorn --break-system-packages --quiet 2>/dev/null || true

# Copy API server
COPY api/ /app/api/

# Install Python deps
RUN pip3 install -r /app/api/requirements.txt --break-system-packages --quiet 2>/dev/null || true

USER headless
WORKDIR /home/headless

# Create SMC include directories for MT5 and MT4 (will be populated at runtime)
RUN mkdir -p "/home/headless/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Include/SMC" && \
    mkdir -p "/home/headless/.wine/drive_c/Program Files/HFM MT4/MQL4/Include/SMC" 2>/dev/null; true

# Copy custom start script
COPY scripts/start.sh /start.sh
RUN sudo chmod +x /start.sh

EXPOSE 5901 6901

CMD ["/bin/bash", "/start.sh"]
