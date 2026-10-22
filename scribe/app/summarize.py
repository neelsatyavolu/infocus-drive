"""Meeting notes in Redrule's format (prompt, JSON shape, parser, markdown).

Ported from Redrule `MinutesCore` (Summary.swift, Summarizer.swift, Models.swift):
long transcripts are digested chunk by chunk, then one JSON note is written,
with one retry and a fallback that keeps whatever the model wrote.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Optional

import httpx

from .vocabulary import TERMS

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
- Make no assumptions. Do not infer reasons, intentions, owners, deadlines, agreement or outcomes that nobody stated, and do not fill gaps with what usually happens in a meeting like this. If something was left unclear or undecided, say it was left open or leave it out.
- Never write that something did not happen (no vote, no decision, nobody objected) unless someone said so. The transcript can be garbled or missing stretches of speech: when a vote or decision was called for and its result is not clearly in the transcript, say the result was not captured in the transcript.
- The transcript comes from speech recognition: silently fix obvious mis-hearings, ignore filler and small talk. Leave out personal chatter that is not meeting business (other classes, homework, college applications, politics, opinions about the news).
- "Participants" lists the correct spelling of everyone who spoke, and "Class members" (when given) everyone in the class. A name in the transcript that sounds like one of them (a mis-hearing) means that person: write it exactly as those lists spell it, even where the transcript spells it differently. A word that is not clearly a name is not a person: never turn an ordinary word into someone's name.
- InFocus terms are spelled """ + ", ".join(TERMS) + """.
- Days: the first line gives the meeting's weekday and date. Work out "today", "tomorrow", "Thursday" or "next week" from that date and write the weekday (for example "Tuesday, Oct 20") instead of the relative word. Keep every plan on the day its speaker gave it: never move an event to another day or swap the days of two events.
- People change plans during a meeting: when a later line corrects, cancels or reassigns something (takes someone off a role, moves a date, drops an idea), report only the final version. When the group agrees on one plan and then settles on a different one, report only the plan they ended on, never both. Before you list any decision, read everything said after it: a later proposal that was accepted and drops a deadline, limit or step replaces it.
- Something read back from earlier notes or recalled from an earlier meeting was decided before: write it as a reminder of an earlier decision, never as a decision of this meeting.
- Keep every rule, limit and number with what it was said about: a length limit set for one package is not about another package mentioned nearby.
- A suggestion, a question or a joke is not a decision. When people disagreed and nobody settled it, say it was left open.
- The owner of a task is the person who was asked to do it or offered to, never the person who asked. "Can someone…" that nobody took on has no owner. Something a speaker says is already done ("I made the slides") is not a task.
- Keep every approval or denial that was given (a package, an extension, a pitch) and whose it was, even when it was said in passing.
- Keep students' private matters out of the notes (health, family, discipline, using AI on schoolwork): write only what the class has to do about it, for example "Abby can't anchor Tuesday; a backup anchor is needed".
- title: 3-7 words naming the meeting's subject, no date.
- tldr: two or three sentences a colleague who missed the meeting could act on.
- Cover the whole meeting, start to finish: later topics matter as much as the first one.
- sections: 2-6 topic sections in the order discussed, each with concise, specific bullets.
- Bullets, decisions and tasks are plain sentences: no leading "-", "*" or numbers.
- decisions: things actually agreed in this meeting. Empty list if none.
- open_questions: questions the meeting raised and did not settle, above all a request someone is waiting on (an extension, an approval, a pitch): what was asked, what each side said, and who was going to give the answer if someone said so. Empty list if none.
- action_items: concrete follow-ups someone actually took on or was given in the meeting; never add tasks nobody said. owner is a name if one was stated, otherwise an empty string.
Reply with a single JSON object and nothing else, with exactly these keys:
{"title": string, "tldr": string, "sections": [{"heading": string, "bullets": [string]}], "decisions": [string], "open_questions": [string], "action_items": [{"owner": string, "task": string}]}"""

DIGEST_SYSTEM = """You are condensing one part of a long meeting transcript so that notes can be written later from your digest.
Keep every decision, number, date, name, commitment and open question. Drop filler. Keep the order of discussion.
Do not assume or add anything that was not said: no guessed reasons, owners, deadlines or conclusions.
Never write that something did not happen unless someone said so. Keep every call for a vote and whatever was said about its result.
Reply with plain text bullets only."""

# A second call on Workers AI: the draft is checked against the transcript it came from.
REVIEW_SYSTEM = SYSTEM + """

You are now checking a draft of these notes against the transcript, statement by statement, and returning corrected notes:
- Find the transcript lines behind every statement in the tldr, sections, decisions and action items. Correct anything those lines contradict: another day, another person, the wrong owner, the opposite outcome.
- When a later line changes something, keep only the final version: check every decision against everything said after it. Remove statements nothing in the transcript supports. Move suggestions and unsettled questions out of decisions and into open_questions. Move anything recalled from an earlier meeting out of decisions.
- Check that every limit, number and owner is attached to the thing the transcript attaches it to, and that no task is something a speaker said was already done.
- Add decisions, open questions, tasks and announcements the draft left out. Every request the meeting discussed (an extension, an approval) is either a decision or an open question.
Reply with the corrected notes as a single JSON object with exactly the keys above."""


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
    "open_questions": {"type": "array", "items": _STRING},
    "action_items": {"type": "array", "items": _object({"owner": _STRING, "task": _STRING})},
})


_SPEAKER = re.compile(r"^\[\d{2}:\d{2}:\d{2}\] ([^:\n]{1,80}): ", re.MULTILINE)


def speaker_names(transcript: str) -> list[str]:
    """Speaker labels in order of first appearance (lines are `[hh:mm:ss] Name: text`)."""
    return list(dict.fromkeys(m.group(1).strip() for m in _SPEAKER.finditer(transcript)))


def _header(title: str, started: str, participants: list[str] | None = None, names: Iterable[str] = ()) -> str:
    lines = [f"InFocus producer meeting \"{title}\", started {started}."]
    if participants:
        lines.append(f"Participants: {', '.join(participants)}.")
    if names:
        lines.append(f"Class members: {', '.join(names)}.")
    return "\n".join(lines)


def user_prompt(transcript: str, title: str, started: str, names: Iterable[str] = ()) -> str:
    return f"{_header(title, started, speaker_names(transcript), names)}\n\nTranscript:\n{transcript}"


def user_from_digests(digests: list[str], title: str, started: str, participants: list[str] | None = None,
                      names: Iterable[str] = ()) -> str:
    body = "\n\n".join(f"Part {i + 1}:\n{d}" for i, d in enumerate(digests))
    return f"{_header(title, started, participants, names)}\n\nDigests of the transcript, in order:\n{body}"


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
    open_questions: list[str] = field(default_factory=list)

    @property
    def markdown(self) -> str:
        blocks = [f"# {self.title}", self.tldr]
        blocks += ["\n".join([f"## {s.heading}"] + [f"- {b}" for b in s.bullets]) for s in self.sections]
        if self.decisions:
            blocks.append("\n".join(["## Decisions"] + [f"- {d}" for d in self.decisions]))
        if self.open_questions:
            blocks.append("\n".join(["## Open questions"] + [f"- {q}" for q in self.open_questions]))
        if self.action_items:
            lines = [f"- [ ] **{a.owner}** — {a.task}" if a.owner else f"- [ ] {a.task}" for a in self.action_items]
            blocks.append("\n".join(["## Action items"] + lines))
        return "\n\n".join(blocks) + "\n"

    def as_dict(self) -> dict[str, Any]:
        """The note in the model's JSON shape (SCHEMA)."""
        return {"title": self.title, "tldr": self.tldr,
                "sections": [{"heading": s.heading, "bullets": s.bullets} for s in self.sections],
                "decisions": self.decisions, "open_questions": self.open_questions,
                "action_items": [{"owner": a.owner or "", "task": a.task} for a in self.action_items]}


class NotJSON(ValueError):
    pass


_BULLET_MARKER = re.compile(r"^\s*(?:(?:[-*•]|\d+[.)])\s+)+")


def _plain(text: str) -> str:
    """Drop list markers the model put in front ("- - a" would render as a nested bullet)."""
    return _BULLET_MARKER.sub("", text).strip()


def _strings(value: Any) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        raise NotJSON("expected a list of strings")
    return [_plain(v) for v in value]


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
            items.append(ActionItem(task=_plain(str(item["task"])), owner=owner or None))
        return MeetingNote(title=title, tldr=tldr, sections=sections,
                           decisions=_strings(data.get("decisions")), action_items=items,
                           open_questions=_strings(data.get("open_questions")))
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


def _ask_note(complete: Complete, system: str, user: str) -> tuple[MeetingNote | None, str]:
    """One JSON note (one retry). None and the last reply when neither reply parses."""
    reply = ""
    for _ in range(2):
        reply = complete(system, user, SCHEMA, None)
        try:
            return parse_note(reply), reply
        except NotJSON:
            continue
    return None, reply


def review_note(complete: Complete, user: str, draft: MeetingNote) -> MeetingNote:
    """The draft checked against the transcript in `user` and corrected; the draft if the check fails."""
    try:
        checked, _ = _ask_note(complete, REVIEW_SYSTEM,
                               f"{user}\n\nDraft notes:\n{json.dumps(draft.as_dict(), ensure_ascii=False)}")
    except Exception as e:
        log.warning("notes review failed (%s); keeping the draft", type(e).__name__)
        return draft
    return checked or draft


def summarize(complete: Complete, title: str, started: str, transcript: str,
              chunk_budget: int = CHUNK_BUDGET, digest_budget: int = DIGEST_BUDGET, *,
              names: Iterable[str] = (), review: bool = False) -> MeetingNote:
    """Redrule's Summarizer: digest long transcripts, then one JSON note (one retry, then fallback).
    With `review`, a transcript that fits one call is also checked against the note (review_note)."""
    chunks = chunk_transcript(transcript, chunk_budget)
    if not chunks:
        raise ValueError("empty transcript")
    names = list(names)
    whole = len(chunks) == 1
    if whole:
        user = user_prompt(transcript, title, started, names)
    else:
        user = user_from_digests(digest(complete, chunks, chunk_budget, digest_budget), title, started,
                                 speaker_names(transcript), names)
    note, reply = _ask_note(complete, SYSTEM, user)
    if note is None:
        # Keep whatever the model wrote rather than losing the meeting.
        return MeetingNote(title=title, tldr=reply.strip())
    # Digests no longer hold the transcript lines a review would check against.
    return review_note(complete, user, note) if review and whole else note


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
