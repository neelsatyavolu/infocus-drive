FROM python:3.12-slim-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
    util-linux \
    && rm -rf /var/lib/apt/lists/*

COPY scripts/userd.py /userd.py
ENV PYTHONUNBUFFERED=1
CMD ["python", "-u", "/userd.py"]
