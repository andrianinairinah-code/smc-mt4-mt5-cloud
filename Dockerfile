FROM hudsonventura/mt5:2.3
ARG CACHEBUST=20260603-2

USER root

RUN apt-get update && \
    apt-get install -y \
        python3 \
        python3-pip \
        netcat-openbsd \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# Copy API server
COPY api/ /app/api/
RUN pip3 install -r /app/api/requirements.txt 2>/dev/null || true

USER headless
WORKDIR /home/headless

# Create SMC include directories for MT5 (will be populated at runtime)
RUN mkdir -p "/home/headless/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Include/SMC"

# Copy custom start script
COPY --chown=headless:headless scripts/start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 6901

CMD ["/bin/bash", "/start.sh"]
