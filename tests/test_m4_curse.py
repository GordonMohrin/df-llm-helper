"""M4 (BUG-115, FR-83, FR-84; Run 14 y707: a curse, then 23 werecavies, and no tool said so): the contract side of the
curse events, the wake recipe, the status and brief lines, the config limits and the documents. The Lua suites
(tests/lua/test_curse.lua, test_curse_kern.lua, test_reflex.lua) prove the behaviour."""
import json
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import brief, fairplay, files, schema, wake
from dfpilot.events import est_tokens

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def event(type_, d, msg="x"):
    return {"n": 5, "tick": 100, "type": type_, "cls": "A", "msg": msg, "d": d}


def put_state(save, **keys):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    for k, v in keys.items():
        if k == "care":
            st["care"].update(v)
        else:
            st[k] = v
    assert schema.validate("state", st) == [], schema.validate("state", st)
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")


# ---------------------------------------------------------------- contracts
def test_the_events_are_class_a_events_of_care_and_two_are_interrupts():
    for t in ("CURSED", "TRANSFORM", "CURSE_MOON"):
        assert schema.EVENTS[t][:2] == ("A", "care"), t
    assert "CURSED" in schema.INTERRUPTS and "TRANSFORM" in schema.INTERRUPTS and "CURSE_MOON" not in schema.INTERRUPTS
    assert {"CURSED", "TRANSFORM", "CURSE_MOON"} <= wake.WAKE_TYPES
    assert {"CURSED", "TRANSFORM"} <= wake.URGENT


def test_the_event_fields_are_typed():
    ok = event("CURSED", {"n": 3, "unit": 1, "name": "Oddom", "god": "Ok", "trig": "toppled Statue", "ann": "SOMETYPE",
                          "kind": "were", "ids": [1, 2, 3], "more": 2, "moon": 206, "mi": 4})
    assert schema.validate("event", ok) == []
    assert schema.validate("event", event("CURSED", {"unit": 1})) != []            # n is required
    assert schema.validate("event", event("TRANSFORM", {"n": 1, "dir": "beast", "to": "werecavy", "bite": 1})) == []
    assert schema.validate("event", event("TRANSFORM", {"n": 1})) != []            # dir is required
    assert schema.validate("event", event("CURSE_MOON", {"moon": 206, "mi": 2, "n": 4, "ids": [1, 2]})) == []
    assert schema.validate("event", event("CURSE_MOON", {"moon": 206})) != []


def test_the_state_keys_are_typed_and_owned_by_care():
    base = json.loads((ROOT / "tests/fixtures/v2/runtime/region7/state.b.json").read_text("utf-8"))
    base["curse"] = {"n": 2, "tf": 1, "ids": [5, 6, 7], "mo": 206, "mi": 4, "dead": 3}
    assert schema.validate("state", base) == []
    base["curse"] = {"n": 2}
    assert schema.validate("state", base) != []                                   # tf is required
    base["curse"] = {"n": 2, "tf": 0, "ids": list(range(9))}
    assert schema.validate("state", base) != []                                   # at most 8 ids
    base["curse"] = {"n": 1, "tf": 0}
    base["care"]["s0"] = {"n": 9, "ids": [1, 2], "nm": ["Urist"]}
    assert schema.validate("state", base) == []
    base["care"]["s0"] = {"n": 9, "ids": list(range(7))}
    assert schema.validate("state", base) != []
    assert schema.STATE_OWNERS["curse.*"] == "care"


def test_inspect_knows_curse_and_unit():
    assert schema.validate_args("inspect", {"what": "curse"}) == []
    assert schema.validate_args("inspect", {"what": "unit", "key": "Oddom Letmoscog"}) == []
    assert schema.validate_args("inspect", {"what": "nonsense"}) != []


def test_the_lua_contract_agrees():
    import re
    text = (ROOT / "lua/dfllm/util/contract.lua").read_text("utf-8")
    for t in ("CURSED", "TRANSFORM", "CURSE_MOON"):
        assert re.search(rf"\b{t} = {{cls = 'A', by = 'care'}}", text), t
    assert re.search(r"C\.INTERRUPTS = {[^}]*CURSED = true,\s*TRANSFORM = true", text)
    assert "['curse.*'] = 'care'" in text


# ---------------------------------------------------------------- config
def test_the_config_keys_are_limited_and_agree_with_care():
    base = json.loads((ROOT / "config/baseline.json").read_text("utf-8"))["care"]
    lua = (ROOT / "lua/dfllm/care.lua").read_text("utf-8")
    for k in ("curse", "curse_every", "curse_keep", "curse_ids", "curse_moon_cycles", "curse_moon_lead", "curse_trig_win",
              "s0_ids"):
        assert k in base and k in fairplay.CARE_LIM, k
        assert k + " =" in lua, k
    assert fairplay.care_errors() == []


def test_a_bad_curse_value_is_refused(tmp_path):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"care": {"curse_keep": 0, "curse_ids": 99, "curse": "yes", "curse_moon_cycles": 0}}))
    errs = fairplay.care_errors(p)
    assert len(errs) == 4 and any("curse_keep" in e for e in errs)


def test_the_reflex_defaults_name_the_new_interrupts():
    d = json.loads((ROOT / "config/reflex.json").read_text("utf-8"))["defaults"]
    assert d["CURSED"] == [] and d["TRANSFORM"] == ["clock"]


# ---------------------------------------------------------------- the wake
def test_the_wake_line_carries_the_recipe_within_150_tokens():
    e = event("CURSED", {"n": 3, "unit": 1, "name": "Oddom Letmoscog", "god": "Ok", "moon": 206, "mi": 4, "ids": [1, 2, 3]},
              "Oddom Letmoscog cursed by Ok (toppled Statue in a tantrum); 3 cursed in the fort, full moon ~d206 in 4 d")
    line = wake.wake_line({"CURSED": {"c": 1, "n0": 5, "e": e}}, None)
    assert est_tokens(line) <= wake.WAKE_TOKENS
    assert "ONE room" in line and "never kill a citizen without his yes" in line and "inspect what=curse" in line
    t = event("TRANSFORM", {"n": 4, "dir": "beast", "to": "werecavy"}, "Kel turned into a werecavy; 4 were-form in the fort now")
    line = wake.wake_line({"TRANSFORM": {"c": 3, "n0": 6, "e": t}, "CURSED": {"c": 1, "n0": 5, "e": e}}, None)
    assert est_tokens(line) <= wake.WAKE_TOKENS
    assert line.index("TRANSFORM") < line.index("CURSED"), "the were-form comes first"
    m = event("CURSE_MOON", {"moon": 206, "mi": 2, "n": 3, "ids": [1, 2, 3]}, "full moon ~d206 in 2 d: 3 cursed (1,2,3)")
    assert "lock the cursed" in wake.wake_line({"CURSE_MOON": {"c": 1, "n0": 7, "e": m}}, None)
    k = event("DECISION_NEEDED", {"id": "curse_kill", "q": "q", "n": 2}, "curse_kill: 2 were-form unit(s)")
    kl = wake.wake_line({"DECISION_NEEDED": {"c": 1, "n0": 8, "e": k}}, None)
    assert "a kill order on the were-form" in kl and "no answer = no kill" in kl


def test_the_wake_gate_wakes_at_once_on_a_curse():
    g = wake.WakeGate()
    g.add(event("CURSED", {"n": 1}), 1000.0)
    assert g.blocked(1000.0) is None, "an interrupt wakes at once"
    g2 = wake.WakeGate()
    g2.add(event("CURSE_MOON", {"moon": 1, "mi": 1, "n": 1}), 1000.0)
    assert g2.blocked(1000.0) == "merging", "CURSE_MOON is class A but no interrupt: it merges"


# ---------------------------------------------------------------- status and brief
def test_the_status_says_who_is_cursed_and_when_the_moon_comes(save):
    put_state(save, curse={"n": 2, "tf": 1, "ids": [5, 6, 7], "mo": 206, "mi": 4})
    out = brief.status_text(save)
    assert "CURSED 3 (ids 5,6,7), 1 in were-form, next full moon ~d206 (in 4 d)" in out
    assert est_tokens(out) <= brief.STATUS_TOKENS


def test_the_status_without_a_curse_is_unchanged(save):
    assert "CURSED" not in brief.status_text(save)
    assert "## curse" not in brief.brief_text(save)


def test_the_brief_has_the_recipe_and_the_desperate_list(save):
    put_state(save, curse={"n": 3, "tf": 0, "ids": [5, 6, 7], "mo": 206, "mi": 3},
              care={"s0": {"n": 9, "ids": [1, 2, 3], "nm": ["Urist A", "Kel B", "Shem C"]}, "stressed_pct": 60,
                    "src": {"deaths": 30, "beds": 4}})
    append_events(save, [ev(901, "BUILDING_TOPPLED", "Statue toppled by Oddom", {"what": "Statue", "by": "Oddom", "n": 2}),
                         ev(902, "BUILDING_TOPPLED", "Door toppled by Kel", {"what": "Door", "by": "Kel"})])
    out = brief.brief_text(save)
    assert "CURSED 3 (ids 5,6,7), next full moon ~d206 (in 3 d)" in out
    assert "## curse (recipe)" in out and "ONE room" in out and "curse_kill" in out
    assert "stress level 0 (desperate): 9 units: 1 Urist A, 2 Kel B, 3 Shem C +6" in out
    assert "top cause deaths 30 -> bury the dead at once" in out
    assert "tantrums tore down 4 buildings in a year (Statue 3, Door 1)" in out
    assert "preceded the Run 14 curse" in out
    assert est_tokens(out) <= brief.BRIEF_TOKENS
    assert est_tokens(brief.status_text(save)) <= brief.STATUS_TOKENS


def test_the_worst_case_stays_in_both_budgets(save):
    put_state(save, curse={"n": 99999, "tf": 99999, "ids": [2 ** 31 - 1] * 8, "mo": 399, "mi": 99999, "dead": 99999},
              care={"s0": {"n": 99999, "ids": [2 ** 31 - 1] * 6, "nm": ["N" * 28] * 6}, "stressed_pct": 100,
                    "src": {"ghosts": 99, "deaths": 99, "beds": 99, "drink": 99, "food": 99, "rooms": 99, "toppled": 99}})
    append_events(save, [ev(1000 + i, "BUILDING_TOPPLED", "x", {"what": f"Kind{i}", "by": "x", "n": 50}) for i in range(40)])
    assert est_tokens(brief.status_text(save)) <= brief.STATUS_TOKENS
    out = brief.brief_text(save)
    assert est_tokens(out) <= brief.BRIEF_TOKENS
    assert "CURSED" in out.splitlines()[1] or "CURSED" in out


def test_tantrum_targets_put_statues_and_temple_objects_first(save):
    class Ctx:
        s = {"care": {"stressed_pct": 5}}
        b = [{"type": "BUILDING_TOPPLED", "d": {"what": w}} for w in ["Door"] * 5 + ["Statue", "Temple altar", "Bed"]]
    line = brief.line_stress(Ctx())
    assert line.index("Statue") < line.index("Door") and "Temple altar" in line
    assert brief.line_stress(type("C", (), {"s": {}, "b": []})()) == ""


# ---------------------------------------------------------------- documents
def test_the_documents_carry_the_package():
    rules = (ROOT / "RULES.md").read_text("utf-8")
    assert len(rules.splitlines()) <= 300
    row = next(x for x in rules.splitlines() if x.startswith("| DEATHS_3PLUS / CURSED / TRANSFORM / CURSE_MOON |"))
    assert "curse_kill" in row and "ONE room" in row and "what=unit" in row
    contracts = (ROOT / "docs/v2/CONTRACTS.md").read_text("utf-8")
    for t in ("CURSED", "TRANSFORM", "CURSE_MOON"):
        assert f"| {t} | A | care |" in contracts
    assert "| `curse?` |" in contracts
    for n in ("BUG-115",):
        assert (ROOT / "bugs").glob(f"{n}-*.md")
        assert list((ROOT / "bugs").glob(f"{n}-*.md")), n
    readme = (ROOT / "bugs/README.md").read_text("utf-8")
    assert "BUG-115" in readme
    frs = (ROOT / "docs/feature-requests/README.md").read_text("utf-8")
    assert "**FR-83" in frs and "**FR-84" in frs
    assert "BUG-115" in (ROOT / "CHANGELOG.md").read_text("utf-8").split("\n## ", 2)[1] or "BUG-115" in \
        (ROOT / "CHANGELOG.md").read_text("utf-8")[:6000]
