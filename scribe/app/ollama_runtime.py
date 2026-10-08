"""On-demand Ollama: started only while a meeting is summarized, then killed.

Nothing runs while the Scribe is idle. The server binds to 127.0.0.1 inside
the Scribe container; models live in OLLAMA_MODELS (a named volume). The first
summary pulls the model.
"""

from __future__ import annotations

import logging
import os
import subprocess
import time
from typing import Any, Callable

import httpx

from .config import ScribeConfig
from .summarize import SUMMARY_UNAVAILABLE, OllamaChat, summarize
from .workers_ai import CLOUD_CHUNK_BUDGET, WorkersAIChat, configured as workers_ai_configured

log = logging.getLogger("scribe.ollama")

READY_TIMEOUT_SECONDS = 60
STOP_TIMEOUT_SECONDS = 10
PULL_TIMEOUT = httpx.Timeout(3600.0, connect=5.0)


class OllamaServer:
    """`with OllamaServer(cfg) as base_url:` runs `ollama serve` for the block only."""

    def __init__(self, cfg: ScribeConfig, *, popen: Callable[..., Any] = subprocess.Popen,
                 client: httpx.Client | None = None, sleep: Callable[[float], None] = time.sleep) -> None:
        self.cfg = cfg
        self.base_url = f"http://127.0.0.1:{cfg.ollama_port}"
        self._popen = popen
        self._client = client or httpx.Client(timeout=httpx.Timeout(10.0, connect=2.0))
        self._sleep = sleep
        self.process: Any = None

    def __enter__(self) -> str:
        env = {**os.environ, "OLLAMA_HOST": f"127.0.0.1:{self.cfg.ollama_port}",
               "OLLAMA_MODELS": str(self.cfg.ollama_models_dir), "OLLAMA_NUM_PARALLEL": "1"}
        self.process = self._popen([self.cfg.ollama_bin, "serve"], env=env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            self._wait_ready()
            self._ensure_model()
        except BaseException:
            self.stop()
            raise
        return self.base_url

    def __exit__(self, *exc: object) -> None:
        self.stop()

    def _wait_ready(self) -> None:
        deadline = time.monotonic() + READY_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("ollama serve exited during startup")
            try:
                if self._client.get(f"{self.base_url}/api/version").status_code == 200:
                    return
            except httpx.HTTPError:
                pass
            self._sleep(0.5)
        raise RuntimeError("ollama serve did not become ready")

    def _ensure_model(self) -> None:
        model = self.cfg.ollama_model
        if self._client.post(f"{self.base_url}/api/show", json={"model": model}).status_code == 200:
            return
        log.info("Summary model %s is not downloaded yet: pulling it now (first summary only; this can take "
                 "several minutes)", model)
        resp = self._client.post(f"{self.base_url}/api/pull", json={"model": model, "stream": False},
                                 timeout=PULL_TIMEOUT)
        resp.raise_for_status()
        log.info("Summary model %s downloaded", model)

    def stop(self) -> None:
        """Terminate, then kill; never leaves the server running."""
        proc, self.process = self.process, None
        if proc is None or proc.poll() is not None:
            return
        proc.terminate()
        try:
            proc.wait(timeout=STOP_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def summarize_meeting(cfg: ScribeConfig, title: str, started: str, transcript: str,
                      server_factory: Callable[[ScribeConfig], OllamaServer] = OllamaServer) -> str:
    """Notes markdown, or the "Summary unavailable" note on any failure (the transcript still ships).

    Workers AI first when it's configured (one call over the whole transcript); the local model
    is the fallback."""
    if workers_ai_configured(cfg):
        try:
            return summarize(WorkersAIChat(cfg), title, started, transcript,
                             chunk_budget=CLOUD_CHUNK_BUDGET, digest_budget=CLOUD_CHUNK_BUDGET).markdown
        except Exception as e:
            log.warning("Workers AI summary failed (%s); using the local model", type(e).__name__)
    try:
        with server_factory(cfg) as base_url:
            chat = OllamaChat(base_url, cfg.ollama_model)
            return summarize(chat, title, started, transcript).markdown
    except Exception as e:
        log.warning("summary failed: %s", type(e).__name__)
        return SUMMARY_UNAVAILABLE
