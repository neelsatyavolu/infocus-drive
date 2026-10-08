"""Meeting summaries through Cloudflare Workers AI (OpenAI-compatible chat completions).

Workers AI keeps no prompts or outputs and doesn't train on them. Its 128k-token context
takes a whole meeting in one request, so the transcript is never digested in pieces.
"""

from __future__ import annotations

from typing import Any

import httpx

from .config import ScribeConfig

API_BASE = "https://api.cloudflare.com/client/v4/accounts"
# Room for the model's reasoning plus the JSON note.
MAX_OUTPUT_TOKENS = 8192
# About 85k tokens: every meeting up to the 4-hour recording cap fits in one call.
CLOUD_CHUNK_BUDGET = 300_000
TIMEOUT = httpx.Timeout(300.0, connect=10.0)


def configured(cfg: ScribeConfig) -> bool:
    return bool(cfg.workers_ai_account_id and cfg.workers_ai_token)


class WorkersAIChat:
    """`complete` over Workers AI chat completions. The JSON shape is asked for in the prompt."""

    def __init__(self, cfg: ScribeConfig, client: httpx.Client | None = None) -> None:
        self._url = f"{API_BASE}/{cfg.workers_ai_account_id}/ai/v1/chat/completions"
        self._headers = {"Authorization": f"Bearer {cfg.workers_ai_token}"}
        self._model = cfg.workers_ai_model
        self._client = client or httpx.Client(timeout=TIMEOUT)

    def __call__(self, system: str, user: str, json_schema: dict[str, Any] | None,
                 num_predict: int | None = None) -> str:
        body = {
            "model": self._model,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "max_tokens": num_predict or MAX_OUTPUT_TOKENS,
            "temperature": 0.2,
            "stream": False,
        }
        resp = self._client.post(self._url, json=body, headers=self._headers)
        resp.raise_for_status()
        choices = resp.json().get("choices") or [{}]
        content = str((choices[0].get("message") or {}).get("content") or "").strip()
        if not content:
            raise RuntimeError("Workers AI returned no text")
        return content
