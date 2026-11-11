"""BUG-720 (Run 16a i1 Basementflew y440: a Coffin on the seal wall tile 97,92,129, the seal blocked `occupied` for 40 days, the audit named the same
tile every day and `seal at=audit` answered 'nothing to close'): a tile another building stands on (PROJECT_BLOCKED why=occupied, BUG-579) is in
cmd.audit_avoid, so the audit finding names the next closable tile of the route. The kernel half (the stuck seal is cancelled after occupied_days)
is tests/lua/test_bug720_occupied_seal.lua."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent / "bp"))

from bp_fixtures import tiny                                                   # noqa: E402
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths        # noqa: E402

from dfpilot import bp, cmd, files                                             # noqa: E402


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    for old in (d / "bp").glob("*.json"):
        old.unlink()
    yield d
    reset_paths()


def _corridor():
    z0 = ["#######", "#.....#", "#######", "......#", "#######"]
    snap = tiny([z0])
    snap["traps"] = [[3, 3, 0, "W", 3, 1], [4, 3, 0, "W", 3, 1]]
    man = {"v": 2, "zones": {"Z2": [[3, 3, 0, 4, 3, 0]], "Z4": [[5, 1, 0, 5, 1, 0], [5, 3, 0, 5, 3, 0]]},
           "edge": [[1, 1, 0], [0, 3, 0]]}
    return snap, man


def _wall(res):
    fs = [f for f in res["fails"] if f.startswith("bypass: wall")]
    assert fs, res["fails"]
    return tuple(int(x) for x in fs[0].split("wall ")[1].split(" ")[0].split(","))


def test_a_tile_a_seal_is_blocked_on_is_in_the_audit_avoid_set(save):
    n = files.last_event_n(save) + 1
    append_events(save, [ev(n, "PROJECT_BLOCKED", "c1a1c7a48e (seal) blocked: occupied", {
        "proj": "c1a1c7a48e", "tpl": "seal", "stage": "seal.build", "why": "occupied", "parts": "Coffin 97,92,129 (a wall wanted)"}, tick=2000)])
    assert (97, 92, 129) in cmd.audit_avoid(save, 3000)                       # old: only fortcore tiles and finished seals


def test_the_audit_then_names_the_next_tile_of_the_route_not_the_coffin_tile():
    snap, man = _corridor()
    first = _wall(bp.audit(snap, man))
    res = bp.audit(snap, man, avoid={first})
    assert _wall(res) != first, res["fails"]
