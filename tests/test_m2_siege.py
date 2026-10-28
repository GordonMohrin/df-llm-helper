"""Package M2 (BUG-107 .. BUG-110, FR-92): the contracts, the config ranges, the wake hint, the status line and the documents
of the siege refuge by supplies, the lockdown without an enemy, the bridge replacement and the drill refusal.
The behaviour itself is in tests/lua/test_m2_*.lua."""
import json
import re
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "tests"))

from cli_v2_helpers import make_runtime, reset_paths  # noqa: E402

from dfpilot import brief, fairplay, files, schema, wake  # noqa: E402


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


# ---------------------------------------------------------------- config
def test_reflex_json_has_the_new_keys_and_the_ranges_are_checked(tmp_path):
    doc = json.loads(read("config/reflex.json"))
    assert doc["inner"] == ["DEATHS_3PLUS"]
    assert {k: doc["refuge"][k] for k in ("floor_pct", "floor_pop", "supply_switch")} == \
        {"floor_pct": 100, "floor_pop": 30, "supply_switch": 50}
    assert fairplay.reflex_errors() == []
    p = tmp_path / "reflex.json"
    for bad in ({"inner": ["NOPE"]}, {"inner": "DEATHS_3PLUS"}, {"refuge": {"floor_pct": 301}},
                {"refuge": {"floor_pct": -1}}, {"refuge": {"floor_pop": 1001}}, {"refuge": {"supply_switch": 101}}):
        p.write_text(json.dumps(dict(bad, v=2)), encoding="utf-8")
        errs = fairplay.reflex_errors(p)
        assert len(errs) == 1 and (list(bad)[0] in errs[0]), (bad, errs)
    p.write_text(json.dumps({"v": 2, "inner": [], "refuge": {"floor_pct": 0, "floor_pop": 0, "supply_switch": 0}}),
                 encoding="utf-8")
    assert fairplay.reflex_errors(p) == []


# ---------------------------------------------------------------- contracts
def test_refuge_stock_is_a_class_a_event_of_seal_and_refuge_fail_takes_sup():
    assert schema.EVENTS["REFUGE_STOCK"][:2] == ("A", "seal")
    e = {"n": 4, "tick": 9, "type": "REFUGE_STOCK", "cls": "A",
         "msg": "Kern+ holds food 1/30, drink 0/30, under 100% of the siege need (30 citizens)",
         "d": {"burrow": "Kern+", "short": "food+drink", "food": 1, "fneed": 30, "drink": 0, "dneed": 30, "pct": 100,
               "cit": 30, "total_f": 900, "total_d": 400, "cmd": "dfllm cmd bp.place '{}'"}}
    assert schema.validate("event", e) == []
    assert any("burrow" in x for x in schema.validate("event", dict(e, d={"short": "food"})))
    f = {"n": 5, "tick": 9, "type": "REFUGE_FAIL", "cls": "A", "msg": "alert burrow Kern+ refused",
         "d": {"burrow": "Kern+", "fallback": "Innen+", "level": "FED", "sup": "Innen+ food 40/30, drink 40/30"}}
    assert schema.validate("event", f) == []
    assert "REFUGE_STOCK" in wake.WAKE_TYPES and "REFUGE_STOCK" in wake.NEXT


def test_ready_dref_is_a_state_field(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["ready"] = {"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": -1, "min_traps": 0},
                   "fail": ["no_inner", "no_outer"], "open": 0, "dhold": "no bridges", "dref": 320}
    assert schema.validate("state", st) == []
    st["ready"]["dref"] = -1
    assert schema.validate("state", st) != []


def test_status_shows_the_refused_drills(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["ready"] = {"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": -1, "min_traps": 0},
                   "fail": ["no_inner", "no_outer"], "open": 0, "dhold": "no bridges", "dref": 320}
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "drill never (auto: no bridges; run dfllm cmd drill) [320 refused: build fortcore stage 2/3 first]" in out
    st["ready"].pop("dref")
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert "refused" not in brief.status_text(save)


def test_the_lua_contract_agrees_on_the_new_names():
    text = read("lua/dfllm/util/contract.lua")
    assert "REFUGE_STOCK = {cls = 'A', by = 'seal'}" in text
    assert re.search(r"dhold = str\(24\), dref = NAT", text)
    assert "| REFUGE_STOCK | A | seal |" in read("docs/v2/CONTRACTS.md")
    assert "no lever-linked bridge: build fortcore stage 2/3 first" in read("lua/dfllm/drill.lua")


# ---------------------------------------------------------------- documents
def test_the_documents_name_the_four_bugs_and_the_fr():
    names = {n: next((ROOT / "bugs").glob(f"BUG-{n}-*.md")) for n in (107, 108, 109, 110)}
    readme = read("bugs/README.md")
    for n, p in names.items():
        assert f"[BUG-{n}]({p.name})" in readme
        body = p.read_text(encoding="utf-8")
        for head in ("Status:", "## Actual", "## Cause", "## Fix", "## Not decided offline", "## Tests"):
            assert head in body, (n, head)
    changelog = read("CHANGELOG.md")
    top = next(e for e in changelog.split("\n## ")[1:] if "BUG-107" in e and "BUG-110" in e)   # merges reorder the entries
    for n in (107, 108, 109, 110):
        assert f"BUG-{n}" in top
    assert "FR-92" in top and len(re.findall(r"^\*\*FR-92\b", read("docs/feature-requests/README.md"), re.M)) == 1
    rules = read("RULES.md")
    assert rules.count("\n") <= 300 and "REFUGE_STOCK" in rules and "BUG-108" in rules and "BUG-110" in rules


def test_the_refuge_stock_commands_are_valid_bp_place_calls():
    """review: the command REFUGE_STOCK names must pass the template's own parameter check (the stockroom has no
    `burrow` param: a call with one is refused 'unknown params')"""
    from dfpilot.bp.emit import check_params

    src = read("lua/dfllm/seal.lua")
    cmds = re.findall(r"bp\.place \\'(\{[^']*\})\\'", src[src.index("function RF.floor"):src.index("local function commit_audit")])
    assert len(cmds) == 2, cmds
    for c in cmds:
        call = json.loads(c)
        check_params(call["tpl"], call.get("p"))
