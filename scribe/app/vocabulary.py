"""Words the transcriber should expect: InFocus terms, then people's names from the Portal.

faster-whisper puts `hotwords` in front of every 30-second window, which nudges spellings toward
these (names it would otherwise hear as look-alikes). It keeps only the first ~220 tokens, so the
short fixed terms go first and the Portal sends its names most-important first.
"""

from __future__ import annotations

from typing import Iterable

TERMS = ("InFocus", "Paly", "A-roll", "B-roll", "Initial Cut", "Final Cut", "teleprompter",
         "show manager", "floor director", "tech director", "package", "Portal")
# About 220 tokens of names (≈4 characters per token).
MAX_CHARS = 900


def clean_vocabulary(words: Iterable[str]) -> list[str]:
    """Trimmed, single-spaced, without blanks or repeats (case-insensitive), in order."""
    seen: set[str] = set()
    out: list[str] = []
    for word in words:
        text = " ".join(str(word).split())
        if text and text.lower() not in seen:
            seen.add(text.lower())
            out.append(text)
    return out


def hotwords(names: Iterable[str]) -> str | None:
    """"InFocus, Paly, …, Abby Example, Otto, …" cut at MAX_CHARS on a whole word; None if empty."""
    text = ""
    for word in clean_vocabulary([*TERMS, *names]):
        candidate = f"{text}, {word}" if text else word
        if len(candidate) > MAX_CHARS:
            break
        text = candidate
    return text or None
