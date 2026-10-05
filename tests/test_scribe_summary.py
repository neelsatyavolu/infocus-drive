"""Long-meeting summaries: capped digests, digested again until the final prompt fits num_ctx."""

import json

from scribe_fakes import MEETING  # noqa: F401  (puts scribe/ on sys.path)

from app import summarize  # noqa: E402

NOTE = json.dumps({"title": "Long meeting", "tldr": "Lots happened.", "sections": [], "decisions": [],
                   "action_items": []})
STARTED = "Oct 4, 2026, 9:15 PM PDT"


class Model:
    """Digests come back `digest_chars` long (≈ what num_predict 300 allows); the final call returns the note."""

    def __init__(self, digest_chars=1_200):
        self.digest_chars = digest_chars
        self.calls = []

    def __call__(self, system, user, schema, num_predict=None):
        self.calls.append((system, user, schema, num_predict))
        if system == summarize.DIGEST_SYSTEM:
            return "- " + "d" * self.digest_chars
        return NOTE


def _transcript(chunks):
    line = "[00:00:01] Abby: " + "w" * 180
    per_chunk = summarize.CHUNK_BUDGET // (len(line) + 1)
    return "\n".join([line] * per_chunk * chunks)


def test_twenty_digests_are_digested_again_before_the_final_call():
    model = Model()
    note = summarize.summarize(model, "Producer meeting", STARTED, _transcript(20))
    assert note.title == "Long meeting"
    first_round = [c for c in model.calls[:20]]
    assert all(c[0] == summarize.DIGEST_SYSTEM and c[3] == summarize.DIGEST_NUM_PREDICT for c in first_round)
    digest_calls = [c for c in model.calls if c[0] == summarize.DIGEST_SYSTEM]
    assert len(digest_calls) > 20  # a second (hierarchical) round ran
    final_system, final_user, final_schema, final_limit = model.calls[-1]
    assert final_system == summarize.SYSTEM and final_schema == summarize.SCHEMA and final_limit is None
    body = final_user.split("Digests of the transcript, in order:\n", 1)[1]
    assert len(body) <= summarize.DIGEST_BUDGET
    assert len(final_user) < 4 * summarize.NUM_CTX - 4_000  # chars ≈ 4 per token: room left for the answer


def test_digests_under_the_budget_go_straight_to_the_final_call():
    model = Model()
    summarize.summarize(model, "T", STARTED, _transcript(3))
    assert [c[0] for c in model.calls] == [summarize.DIGEST_SYSTEM] * 3 + [summarize.SYSTEM]


def test_digests_that_never_shrink_are_cut_to_fit():
    model = Model(digest_chars=summarize.CHUNK_BUDGET)  # a model that ignores the length limit
    summarize.summarize(model, "T", STARTED, _transcript(6))
    body = model.calls[-1][1].split("Digests of the transcript, in order:\n", 1)[1]
    assert len(body) <= summarize.DIGEST_BUDGET
    digest_calls = sum(1 for c in model.calls if c[0] == summarize.DIGEST_SYSTEM)
    assert digest_calls == 6  # no second round: it could only grow
