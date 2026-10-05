"""Meeting notes in Redrule's format (prompt, JSON shape, parser, markdown).

Ported from Redrule `MinutesCore` (Summary.swift, Summarizer.swift, Models.swift):
long transcripts are digested chunk by chunk, then one JSON note is written,
with one retry and a fallback that keeps whatever the model wrote.
"""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

import httpx

log = logging.getLogger("scribe.summarize")

# Small local model: keep each prompt well inside num_ctx.
CHUNK_BUDGET = 12_000
NUM_CTX = 8192
# Digests are short (≈300 tokens each), and all of them together must leave the final
# call room inside num_ctx: above this they are digested again (hierarchically).
DIGEST_NUM_PREDICT = 300
DIGEST_BUDGET = 16_000
MAX_DIGEST_ROUNDS = 4
OLLAMA_TIMEOUT = httpx.Timeout(900.0, connect=5.0)

SUMMARY_UNAVAILABLE = (
    "## Summary unavailable\n\nThe summarizer on the Drive could not write notes for this meeting. "
    "The full transcript is in transcript.md.\n"
)
NO_SPEECH = "## No speech recorded\n\nNothing was transcribed in this meeting.\n"

SYSTEM = """You write meeting notes from a transcript, in the style of a sharp chief of staff.
Each speaker label is the participant's own name (their InFocus display name), taken from their own audio track.
Rules:
- Report only what was said. Never invent names, numbers, dates or commitments.
- The transcript comes from speech recognition: silently fix obvious mis-hearings, ignore filler and small talk.
- title: 3-7 words naming the meeting's subject, no date.
- tldr: two or three sentences a colleague who missed the meeting could act on.
- sections: 2-6 topic sections in the order discussed, each with concise, specific bullets.
- decisions: things actually agreed. Empty list if none.
- action_items: concrete follow-ups. owner is a name if one was stated, otherwise an empty string.
Reply with a single JSON object and nothing else, with exactly these keys:
{"title": string, "tldr": string, "sections": [{"heading": string, "bullets": [string]}], "decisions": [string], "action_items": [{"owner": string, "task": string}]}"""

DIGEST_SYSTEM = """You are condensing one part of a long meeting transcript so that notes can be written later from your digest.
Keep every decision, number, date, name, commitment and open question. Drop filler. Keep the order of discussion.
Reply with plain text bullets only."""


def _object(properties: dict[str, Any]) -> dict[str, Any]:
    return {"type": "object", "properties": properties, "required": sorted(properties),
            "additionalProperties": False}


_STRING = {"type": "string"}
SCHEMA = _object({
    "title": _STRING,
    "tldr": _STRING,
    "sections": {"type": "array", "items": _object({"heading": _STRING,
                                                     "bullets": {"type": "array", "items": _STRING}})},
    "decisions": {"type": "array", "items": _STRING},
    "action_items": {"type": "array", "items": _object({"owner": _STRING, "task": _STRING})},
})


def _header(title: str, started: str) -> str:
    return f"InFocus producer meeting \"{title}\", started {started}."


def user_prompt(transcript: str, title: str, started: str) -> str:
    return f"{_header(title, started)}\n\nTranscript:\n{transcript}"


def user_from_digests(digests: list[str], title: str, started: str) -> str:
    body = "\n\n".join(f"Part {i + 1}:\n{d}" for i, d in enumerate(digests))
    return f"{_header(title, started)}\n\nDigests of the transcript, in order:\n{body}"


def chunk_transcript(text: str, max_chars: int = CHUNK_BUDGET) -> list[str]:
    """Split on line boundaries into chunks of at most `max_chars` (long lines are cut)."""
    chunks: list[str] = []
    current: list[str] = []
    size = 0
    for line in text.splitlines():
        while len(line) > max_chars:
            if current:
                chunks.append("\n".join(current))
                current, size = [], 0
            chunks.append(line[:max_chars])
            line = line[max_chars:]
        extra = len(line) + (1 if current else 0)
        if current and size + extra > max_chars:
            chunks.append("\n".join(current))
            current, size = [], 0
            extra = len(line)
        if line:
            current.append(line)
            size += extra
    if current:
        chunks.append("\n".join(current))
    return chunks


@dataclass(frozen=True)
class ActionItem:
    task: str
    owner: Optional[str] = None


@dataclass(frozen=True)
class NoteSection:
    heading: str
    bullets: list[str]


@dataclass(frozen=True)
class MeetingNote:
    title: str
    tldr: str
    sections: list[NoteSection] = field(default_factory=list)
    decisions: list[str] = field(default_factory=list)
    action_items: list[ActionItem] = field(default_factory=list)

    @property
    def markdown(self) -> str:
        blocks = [f"# {self.title}", self.tldr]
        blocks += ["\n".join([f"## {s.heading}"] + [f"- {b}" for b in s.bullets]) for s in self.sections]
        if self.decisions:
            blocks.append("\n".join(["## Decisions"] + [f"- {d}" for d in self.decisions]))
        if self.action_items:
            lines = [f"- [ ] **{a.owner}** — {a.task}" if a.owner else f"- [ ] {a.task}" for a in self.action_items]
            blocks.append("\n".join(["## Action items"] + lines))
        return "\n\n".join(blocks) + "\n"


class NotJSON(ValueError):
    pass


def _strings(value: Any) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise NotJSON("expected a list of strings")
    return value


def parse_note(reply: str) -> MeetingNote:
    """Parse the model reply, tolerating code fences or prose around the JSON object."""
    start, end = reply.find("{"), reply.rfind("}")
    if start < 0 or end <= start:
        raise NotJSON("no JSON object")
    try:
        data = json.loads(reply[start:end + 1])
        title, tldr = data["title"], data["tldr"]
        if not isinstance(title, str) or not isinstance(tldr, str):
            raise NotJSON("title and tldr must be strings")
        sections = [NoteSection(heading=str(s["heading"]), bullets=_strings(s["bullets"]))
                    for s in (data.get("sections") or [])]
        items = []
        for item in data.get("action_items") or []:
            owner = (item.get("owner") or "").strip()
            items.append(ActionItem(task=str(item["task"]), owner=owner or None))
        return MeetingNote(title=title, tldr=tldr, sections=sections,
                           decisions=_strings(data.get("decisions")), action_items=items)
    except (ValueError, KeyError, TypeError, AttributeError) as e:
        raise NotJSON(str(e)) from e


# complete(system, user, json_schema, num_predict) -> model text
Complete = Callable[[str, str, Optional[dict[str, Any]], Optional[int]], str]


def _digests_size(digests: list[str]) -> int:
    return len(user_from_digests(digests, "", ""))


def _fit(digests: list[str], budget: int) -> list[str]:
    """Last resort when digesting stops shrinking: cut every digest to an equal share."""
    share = max(200, budget // max(1, len(digests)) - 20)
    return [d[:share] for d in digests]


def digest(complete: Complete, chunks: list[str], chunk_budget: int = CHUNK_BUDGET,
           budget: int = DIGEST_BUDGET) -> list[str]:
    """Digest each chunk; while the digests together are over `budget`, digest the digests
    (grouped into `chunk_budget` pieces) so the final prompt fits num_ctx."""
    digests = [complete(DIGEST_SYSTEM, chunk, None, DIGEST_NUM_PREDICT) for chunk in chunks]
    rounds = 1
    while _digests_size(digests) > budget and len(digests) > 1 and rounds < MAX_DIGEST_ROUNDS:
        groups = chunk_transcript("\n".join(digests), chunk_budget)
        if len(groups) >= len(digests):
            break  # digests longer than a chunk: another round wouldn't shrink anything
        digests = [complete(DIGEST_SYSTEM, group, None, DIGEST_NUM_PREDICT) for group in groups]
        rounds += 1
    return digests if _digests_size(digests) <= budget else _fit(digests, budget)


def summarize(complete: Complete, title: str, started: str, transcript: str,
              chunk_budget: int = CHUNK_BUDGET, digest_budget: int = DIGEST_BUDGET) -> MeetingNote:
    """Redrule's Summarizer: digest long transcripts, then one JSON note (one retry, then fallback)."""
    chunks = chunk_transcript(transcript, chunk_budget)
    if not chunks:
        raise ValueError("empty transcript")
    if len(chunks) == 1:
        user = user_prompt(transcript, title, started)
    else:
        user = user_from_digests(digest(complete, chunks, chunk_budget, digest_budget), title, started)
    reply = ""
    for _ in range(2):
        reply = complete(SYSTEM, user, SCHEMA, None)
        try:
            return parse_note(reply)
        except NotJSON:
            continue
    # Keep whatever the model wrote rather than losing the meeting.
    return MeetingNote(title=title, tldr=reply.strip())


class OllamaChat:
    """`complete` over Ollama's /api/chat, with `format` = JSON schema for structured output."""

    def __init__(self, base_url: str, model: str, client: httpx.Client | None = None) -> None:
        self._url = base_url.rstrip("/") + "/api/chat"
        self._model = model
        self._client = client or httpx.Client(timeout=OLLAMA_TIMEOUT)

    def __call__(self, system: str, user: str, json_schema: dict[str, Any] | None,
                 num_predict: int | None = None) -> str:
        options: dict[str, Any] = {"temperature": 0.2, "num_ctx": NUM_CTX}
        if num_predict is not None:
            options["num_predict"] = num_predict
        body: dict[str, Any] = {
            "model": self._model, "stream": False,
            "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
            "options": options,
        }
        if json_schema is not None:
            body["format"] = json_schema
        resp = self._client.post(self._url, json=body)
        resp.raise_for_status()
        return str((resp.json().get("message") or {}).get("content") or "")
