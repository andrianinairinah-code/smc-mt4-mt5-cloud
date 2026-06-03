FROM hudsonventura/mt5:2.3
ENTRYPOINT []

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

# MT4 installer downloaded at runtime (not here) to avoid
# build-time network failures and unpredictable build duration.
# Railway build timeout is ~10 min; Wine + MT5 base image alone takes ~5-8 min.

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
