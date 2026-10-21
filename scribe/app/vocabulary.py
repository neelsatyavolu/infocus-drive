"""Words the notes should spell right: InFocus terms, and people's names from the Portal.

They go to the summary model, which fixes mis-heard names and terms. Whisper gets no hints: with
`hotwords` (the class list, or only the people in the call) it skipped whole minutes of speech and
wrote names nobody said.
"""

from __future__ import annotations

from typing import Iterable

TERMS = ("InFocus", "Paly", "Fun Focus", "A-roll", "B-roll", "Initial Cut", "Final Cut", "teleprompter",
         "show manager", "floor director", "tech director", "package", "Portal")
# The Portal sends at most 300 names of at most 80 characters; this keeps the prompt line bounded.
MAX_CHARS = 4_000


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


def known_names(names: Iterable[str]) -> list[str]:
    """The Portal's names, cleaned, cut at MAX_CHARS (joined with ", ") on a whole name."""
    out: list[str] = []
    size = 0
    for name in clean_vocabulary(names):
        size += len(name) + (2 if out else 0)
        if size > MAX_CHARS:
            break
        out.append(name)
    return out
