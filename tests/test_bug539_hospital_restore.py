"""BUG-539 (Run 16b i2 Brotherarrow y395-y396): water.unstick removed the hospital zone 18030 and the kernel never drew it again;
'bp sites hospital' said 'no valid site' and a second hospital would have gone up beside the first room (beds, tables). The verb
hospital.restore, the state key water.hrm (removed zones waiting to be drawn again) and the site search that names the verb."""
import shlex

import pytest

from dfpilot import lint, schema
from dfpilot.bp import sites
from dfpilot.cmd import parse_kv, water_ctx


def test_the_verb_the_act_and_the_state_key_are_in_the_registry():
    assert schema.VERBS["hospital.restore"] == ("water", None, False)
    assert schema.validate_args("hospital.restore", {}) == []
    assert schema.validate_args("hospital.restore", {"loc": 600}) == []
    assert schema.validate_args("hospital.restore", {"loc": "x"}) != []
    assert schema.ACT["hospital_restore"] == ["water"]


@pytest.mark.parametrize("line", ["dfllm cmd hospital.restore", "dfllm cmd hospital.restore loc=600"])
def test_the_commands_parse_and_pass_the_hook(line):
    w = shlex.split(line)
    assert schema.validate_args(w[2], parse_kv(w[3:])) == []
    ok, why = lint.cmd(line, dev=False, shell=True)
    assert ok, why


def test_water_ctx_carries_the_remembered_zones(tmp_path, monkeypatch):
    state = {"water": {"src": [[1, 2, 3]], "hrm": 2}}
    assert water_ctx(tmp_path, "hospital", state)["hrm"] == 2
    assert "hrm" not in water_ctx(tmp_path, "hospital", {"water": {"src": [[1, 2, 3]]}})
    assert "hrm" not in water_ctx(tmp_path, "hospital", {"water": {"src": [[1, 2, 3]], "hrm": 0}})


def test_hospital_sites_name_the_restore_verb_while_a_removed_zone_waits():
    snap = {"id": "x", "w": 1, "h": 1}
    with pytest.raises(ValueError) as e:
        sites.rank(snap, "hospital", None, {"zones": {"Z4": [[0, 0, 0, 1, 1, 1]]}}, water={"src": [[1, 2, 3]], "near": 30, "hrm": 1})
    msg = str(e.value)
    assert "hospital.restore" in msg and "no second hospital" in msg and "1 zone" in msg, msg
