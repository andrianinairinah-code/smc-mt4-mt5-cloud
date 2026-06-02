FROM hudsonventura/mt5:2.3

USER root

# Install Python3 + nginx + wget + unzip
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3 \
        python3-pip \
        netcat-openbsd \
        curl \
        wget \
        unzip \
        nginx \
    && rm -rf /var/lib/apt/lists/*

# Pre-download generic MetaQuotes MT4 installer at build time
# (HFM-branded CDN is blocked on Railway; generic MT4 works with any broker)
RUN mkdir -p /home/headless/installers && \
    if curl -fSL --retry 3 --retry-delay 5 \
      "https://download.mql5.com/cdn/web/metaquotes.software.corp/mt4/mt4setup.exe" \
      -o /home/headless/installers/mt4setup.exe; then \
        echo "MT4 installer pre-downloaded OK"; \
    else \
        echo "WARNING: MT4 installer pre-download failed (will retry at runtime)"; \
    fi

# Copy API server
COPY api/ /app/api/

# Copy nginx config
COPY nginx.conf /etc/nginx/nginx.conf
RUN chmod 644 /etc/nginx/nginx.conf

USER headless
WORKDIR /home/headless

# Create SMC include directories for MT5 and MT4 (will be populated at runtime)
RUN mkdir -p "/home/headless/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Include/SMC" && \
    mkdir -p "/home/headless/.wine/drive_c/Program Files/MetaTrader 4/MQL4/Include/SMC" && \
    mkdir -p "/home/headless/.wine/drive_c/Program Files/HFM MT4/MQL4/Include/SMC" 2>/dev/null; true

# Copy custom start script
COPY scripts/start.sh /start.sh
RUN sudo chmod +x /start.sh

EXPOSE 5901 6901 5000

CMD ["/bin/bash", "/start.sh"]
