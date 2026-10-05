# InFocus Scribe: headless Chromium joins a Portal meeting as a listener,
# then faster-whisper + Ollama turn the audio into notes on the Drive.
# Idle, only the small FastAPI process runs: Chromium, whisper (child process)
# and `ollama serve` are started per meeting/job and exit afterwards.
# The Playwright image ships Python 3.12, a matching Chromium build and the
# non-root `pwuser`. Rebuild this image when Playwright/Chromium updates
# (bump the tag here and `playwright` in requirements.txt together).
FROM mcr.microsoft.com/playwright/python:v1.55.0-noble

RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Ollama binary (CPU only), run on demand while summarizing (ollama_runtime.py).
# Official release tarball, pinned; GPU libraries are skipped to keep the image small.
ARG OLLAMA_VERSION=0.12.3
ARG TARGETARCH=amd64
RUN curl -fsSL "https://github.com/ollama/ollama/releases/download/v${OLLAMA_VERSION}/ollama-linux-${TARGETARCH}.tgz" \
      | tar -xzf - -C /usr/local --exclude='lib/ollama/cuda_*' --exclude='lib/ollama/rocm*' \
      --exclude='lib/ollama/libggml-cuda*' --exclude='lib/ollama/libggml-hip*' \
    && test -x /usr/local/bin/ollama

WORKDIR /srv
COPY requirements.txt /srv/requirements.txt
RUN pip install --no-cache-dir --break-system-packages -r /srv/requirements.txt

COPY app/ /srv/app/

# The notes folder on the Drive (.ifd-meetings, mode 700) belongs to the NAS service owner, uid 1000.
# The Playwright noble image ships `ubuntu` as 1000 and pwuser as 1001, and on the NAS 1001 is a real
# person's account, so pwuser is renumbered to SCRIBE_UID instead of granting that uid access.
ARG SCRIBE_UID=1000
RUN if getent passwd ubuntu >/dev/null; then userdel -r ubuntu 2>/dev/null || userdel ubuntu; fi \
    && if getent group ubuntu >/dev/null; then groupdel ubuntu; fi \
    && groupmod -g "${SCRIBE_UID}" pwuser \
    && usermod -u "${SCRIBE_UID}" -g "${SCRIBE_UID}" pwuser \
    && chown -R pwuser:pwuser /home/pwuser

# Named volumes mounted here inherit this ownership on first use.
RUN mkdir -p /scribe-tmp /models/ollama /meetings && chown -R pwuser:pwuser /scribe-tmp /models /meetings

# Never root: Chromium runs with its own sandbox on (needs user namespaces;
# see security_opt in docker-compose.yml).
USER pwuser
ENV PYTHONUNBUFFERED=1 \
    HOME=/home/pwuser \
    HF_HOME=/models \
    OLLAMA_MODELS=/models/ollama
# Bridge network: compose publishes this on the host's 127.0.0.1:8792 only.
CMD ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8792", "--no-access-log"]
