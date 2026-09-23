#!/bin/sh
# Run uvicorn with an in-process watchdog. If /api/health fails repeatedly,
# exit non-zero so Docker `restart: unless-stopped` brings the app back.
# Complements Docker HEALTHCHECK (which alone does not restart containers).
set -eu

HOST="${IFD_BIND_HOST:-0.0.0.0}"
PORT="${IFD_BIND_PORT:-8787}"
HEALTH_URL="http://127.0.0.1:${PORT}/api/health"
INTERVAL="${IFD_WATCHDOG_INTERVAL_S:-15}"
TIMEOUT="${IFD_WATCHDOG_CURL_S:-5}"
FAILS_NEEDED="${IFD_WATCHDOG_FAILS:-3}"
START_GRACE="${IFD_WATCHDOG_START_S:-20}"

uvicorn main:app \
  --host "$HOST" \
  --port "$PORT" \
  --proxy-headers \
  --timeout-keep-alive 120 \
  --limit-concurrency 200 &
UV_PID=$!

cleanup() {
  if kill -0 "$UV_PID" 2>/dev/null; then
    kill -TERM "$UV_PID" 2>/dev/null || true
    # Brief grace, then force
    i=0
    while kill -0 "$UV_PID" 2>/dev/null && [ "$i" -lt 10 ]; do
      sleep 1
      i=$((i + 1))
    done
    kill -KILL "$UV_PID" 2>/dev/null || true
  fi
}
trap cleanup INT TERM

# Let uvicorn bind before probing.
sleep "$START_GRACE"

fails=0
while kill -0 "$UV_PID" 2>/dev/null; do
  if curl -fsS --max-time "$TIMEOUT" "$HEALTH_URL" >/dev/null 2>&1; then
    fails=0
  else
    fails=$((fails + 1))
    echo "watchdog: health failed ($fails/$FAILS_NEEDED)" >&2
    if [ "$fails" -ge "$FAILS_NEEDED" ]; then
      echo "watchdog: restarting — /api/health unresponsive" >&2
      cleanup
      exit 1
    fi
  fi
  sleep "$INTERVAL"
done

# uvicorn exited on its own
wait "$UV_PID"
exit $?
