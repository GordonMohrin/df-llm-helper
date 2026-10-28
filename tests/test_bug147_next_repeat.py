"""BUG-147 (live test i1, 2026-10-28): the repeat limit of `dfllm next` held for one call only. The 'tried 3x' idle step
cleared the memory (the 5th call offered the skipped command again), and any other command in between overwrote the one
counter (brief, brief, brief, bp.place, brief, brief ...). The memory now counts per command inside REPEAT_WINDOW_S."""
import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import guide


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _only(monkeypatch, *cmds):
    monkeypatch.setattr(guide, "candidates", lambda f: [guide.Step("plan", c, f"because {c}") for c in cmds])


def _seq(save, n, t0=7_000_000.0):
    return [guide.next_step(save, now=t0 + i).cmd for i in range(n)]


def test_the_stuck_answer_keeps_the_memory(save, monkeypatch):
    _only(monkeypatch, "dfllm brief")
    assert _seq(save, 7) == ["dfllm brief"] * 3 + [None] * 4          # main: X, X, X, None, X, X, X
    s = guide.next_step(save, now=7_000_010.0)
    assert s.key == "idle" and "tried 3x" in s.why and s.tell


def test_another_command_in_between_does_not_reset_the_count(save, monkeypatch):
    calls = {"n": 0}

    def cands(f):
        calls["n"] += 1
        out = [guide.Step("r0", "dfllm brief", "R0 blockers")]
        if calls["n"] == 4:                                               # one other step shows up once
            out.insert(0, guide.Step("r0", guide.SEAL_CMD, "R0 seal"))
        return out
    monkeypatch.setattr(guide, "candidates", cands)
    got = _seq(save, 6)
    assert got[:4] == ["dfllm brief"] * 3 + [guide.SEAL_CMD]
    assert got[4:] == [None, None], got                                   # main: brief(n=1), brief(n=2)


def test_the_count_is_per_command_and_expires(save, monkeypatch):
    _only(monkeypatch, "dfllm brief", "dfllm audit")
    t0 = 8_000_000.0
    assert _seq(save, 7, t0) == ["dfllm brief"] * 3 + ["dfllm audit"] * 3 + [None]
    late = t0 + 6 + guide.REPEAT_WINDOW_S + 1                              # half an hour without a print: offered again
    assert guide.next_step(save, now=late).cmd == "dfllm brief"


def test_a_green_answer_clears_the_memory(save, monkeypatch):
    _only(monkeypatch, "dfllm brief")
    _seq(save, 4)
    _only(monkeypatch)                                                    # nothing applies and nothing was skipped
    s = guide.next_step(save, now=7_000_020.0)
    assert s.why.startswith("green")
    assert guide.read_memory(save, 7_000_021.0) == {}
    _only(monkeypatch, "dfllm brief")
    assert guide.next_step(save, now=7_000_022.0).cmd == "dfllm brief"


def test_danger_is_counted_but_never_skipped(save, monkeypatch):
    monkeypatch.setattr(guide, "candidates", lambda f: [guide.Step("danger", guide.WAIT, "siege")])
    assert _seq(save, 5) == [guide.WAIT] * 5
