FROM python:3.12-slim-bookworm

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

COPY app/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt

COPY app/ /app/
COPY scripts/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Run as root so seteuid can impersonate NAS users for file ACLs
ENV PYTHONUNBUFFERED=1
EXPOSE 8787

# Watchdog restarts the process if /api/health fails (Docker HEALTHCHECK alone
# marks unhealthy but does not restart unless-stopped containers).
CMD ["/entrypoint.sh"]
