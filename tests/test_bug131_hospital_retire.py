"""BUG-131 (Run 14, site90): readiness R0 hospital_out stayed red the whole run over an old hospital zone (24422 at
88,28,129) outside Kern+/Tiefe+ that the session was not allowed to delete. The verb hospital.retire (water, PEACE),
the state's water.hout (the blocking zone) and the status/brief/NEXT lines that name the zone and the command."""
import shlex

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, files, guide, lint, schema
from dfpilot.cmd import parse_kv


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put(save, hout, hosp_proj=None, monkeypatch=None):
    st = files.read_state(save)
    st["ready"] = {"lvl": 0, "worn": 94, "cv": 13, "drill_age": 5, "audit": {"age": 10, "ok": 1, "min_traps": 40},
                   "fail": ["hospital_out"], "open": 0}
    w = {"patients": 0, "thirst_max": 0, "hosp_ok": 1, "refuge_ok": 1, "buckets_free": 2, "hosp": 3, "src": [[1, 2, 3]],
         "hosp_out": 1}
    if hout is not None:
        w["hout"] = hout
    st["water"] = w
    st["seq"] = st["seq"] + 10
    assert schema.validate("state", st) == []
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))


def test_the_verb_and_the_state_key_are_in_the_registry():
    assert schema.VERBS["hospital.retire"] == ("water", ["PEACE"], False)
    assert schema.validate_args("hospital.retire", {"zone": 24422}) == []
    assert schema.validate_args("hospital.retire", {"zone": 24422, "approve": True}) == []
    assert schema.validate_args("hospital.retire", {}) != []
    assert schema.validate_args("hospital.retire", {"zone": "old"}) != []


def test_status_names_the_blocking_zone_and_the_retire_command(save):
    put(save, {"z": 24422, "at": [88, 28, 129], "ok": 0, "pat": 0})
    line = brief.status_text(save).splitlines()[1]
    assert line.startswith("SIEGE UNREADY (R0): hospital_out"), line
    assert ("zone 24422 at 88,28,129 blocks it: once the hospital inside has a bed, "
            "dfllm cmd hospital.retire zone=24422 (sooner only on Gordon's word: approve=true)") in line, line
    put(save, {"z": 24422, "at": [88, 28, 129], "ok": 1, "pat": 2})
    line = brief.status_text(save).splitlines()[1]
    assert ("zone 24422 at 88,28,129 blocks it: 2 patients lie in it; once they are up: "
            "dfllm cmd hospital.retire zone=24422") in line, line
    # an older kernel without hout: the old text alone
    put(save, None)
    line = brief.status_text(save).splitlines()[1]
    assert "hospital.retire" not in line and "then remove the old zones" in line, line


def test_next_names_the_retire_command_while_the_new_hospital_is_under_way(save, monkeypatch):
    monkeypatch.setattr(guide, "_hospital_project", lambda save_dir: True)
    put(save, {"z": 24422, "at": [88, 28, 129], "ok": 1, "pat": 0})
    s = guide.candidates(guide.gather(save))[0]
    assert (s.key, s.cmd) == ("r0", "dfllm cmd hospital.retire zone=24422"), (s.key, s.cmd, s.why)
    assert "zone 24422 at 88,28,129" in s.why
    put(save, {"z": 24422, "at": [88, 28, 129], "ok": 0, "pat": 0})
    s = guide.decide(guide.gather(save))
    assert s.key == "idle" and "R0 waits on hospital_out" in s.why, s.why     # approve is the player's: no NEXT for it


@pytest.mark.parametrize("line", ["dfllm cmd hospital.retire zone=24422",
                                  "dfllm cmd hospital.retire zone=24422 approve=true"])
def test_the_commands_parse_and_pass_the_hook(line):
    w = shlex.split(line)
    assert schema.validate_args(w[2], parse_kv(w[3:])) == []
    ok, why = lint.cmd(line, dev=False, shell=True)
    assert ok, why
