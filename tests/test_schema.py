"""df_llm_helper.schema: DESIGN §6 / CONTRACTS examples, negative cases, contract.lua agreement."""
import copy
import json
import re
import subprocess
import sys
from pathlib import Path

import pytest

from df_llm_helper import schema as S

ROOT = Path(__file__).resolve().parent.parent
CONTRACTS = ROOT / "docs" / "v2" / "CONTRACTS.md"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

needs_lua = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")

# DESIGN.md §6, verbatim
DESIGN_STATE = """{"v":2,"seq":812,"t":{"y":3,"tick":123456,"season":1,"tps":462,"paused":false},"mode":"PEACE","phase":"P3",
 "pop":{"cit":52,"adults":44,"cap":55,"gate_cap":55,"soldiers":8},"ready":{"lvl":1,"worn":94,"cv":13,"drill_age":40000,
 "audit":{"ok":1,"age":9000,"min_traps":22},"fail":["traps<30"]},"stock":{"drink_d":182,"food_d":75,"meals":6,"hosp_water":1},
 "care":{"stressed_pct":4,"naked":0,"ghosts":0,"corpses_old":0,"tombs_free":9,"moods":0},"labor":{"starving":0,"idle":31},
 "threat":{"vis":0,"armed":0},"proj":[["fortcore","s2.build",64,""]],"bridges":{"O1":"down","B1":"down","B2":"down"},
 "k":{"ms_s":11,"gap_max_ms":420,"slow":[],"faults":0},"owners":{"pause":null,"tempo":"mode"},"ev":8812}"""
DESIGN_EVENT = '{"n":8812,"tick":1234500,"type":"SIEGE_END","cls":"A","msg":"149 hostiles, 31 killed, 0 lost, sealed 6.1 d","d":{}}'
DESIGN_INBOX = '{"id":"c123","verb":"bp.place","args":{"tpl":"bedrooms","site":"S2","n":20},"by":"llm"}'
DESIGN_OUTBOX = '{"id":"c123","ok":true,"msg":"queued P7"}'
DESIGN_PLAN = """{"v":2,"year":3,"policy":{"option":"A","pop_ceiling":75,"beauty":"used_rooms"},"phase_target":"P6",
 "seasons":[{"build":[{"tpl":"bedrooms","site":"S2","p":{"n":20,"tier":500}}]},{"build":[]},{"build":[]},{"build":[]}],
 "military":{"pct":15,"squads":{"melee":2,"xbow":1},"cv_min":12},"supply":{"drink_d":170,"food_d":60,"mood_stock":10},
 "orders":{"import":["library/smelting"]},"trade":{"want":["bar:iron","anvil","cloth"],"sell":["crafts"]},"notes":""}"""


def contract_examples():
    text = CONTRACTS.read_text(encoding="utf-8")
    return [(m.group(1), json.loads(m.group(2)))
            for m in re.finditer(r"<!-- ex:([a-z.]+) -->\s*\n```json\n(.*?)\n```", text, re.S)]


EXAMPLES = contract_examples()


@pytest.mark.parametrize("kind,text", [("state", DESIGN_STATE), ("event", DESIGN_EVENT), ("inbox", DESIGN_INBOX),
                                       ("outbox", DESIGN_OUTBOX), ("plan", DESIGN_PLAN)])
def test_design_examples_validate(kind, text):
    assert S.validate(kind, json.loads(text)) == []


def test_contract_has_examples_for_main_kinds():
    kinds = {k for k, _ in EXAMPLES}
    assert {"state", "event", "inbox", "outbox", "plan", "manifest", "snapshot", "bp", "phases", "heartbeat",
            "restore", "allowlist", "lock"} <= kinds


@pytest.mark.parametrize("kind,doc", EXAMPLES, ids=[k for k, _ in EXAMPLES])
def test_contract_examples_validate(kind, doc):
    assert S.validate(kind, doc) == []


def test_appendix_is_current():
    text = CONTRACTS.read_text(encoding="utf-8")
    m = re.search(r"<!-- BEGIN GENERATED SCHEMAS -->\n(.*)<!-- END GENERATED SCHEMAS -->", text, re.S)
    assert m, "appendix markers missing"
    assert m.group(1) == S.appendix(), "run: python -m df_llm_helper.schema --appendix and paste into CONTRACTS.md"


def test_json_schema_for_every_kind():
    for kind in S.KINDS + [f"inbox.args.{v}" for v in S.VERB_ARGS]:
        js = S.json_schema(kind)
        assert js["title"] == kind
        for pat in re.findall(r'"pattern": "((?:[^"\\]|\\.)*)"', json.dumps(js)):
            re.compile(json.loads(f'"{pat}"'))


def state():
    return json.loads(DESIGN_STATE)


def errs(kind, doc):
    return S.validate(kind, doc)


@pytest.mark.parametrize("mutate,needle", [
    (lambda d: d.__setitem__("seq", 1.0), "expected int, got float"),
    (lambda d: d.__setitem__("seq", True), "expected int, got bool"),
    (lambda d: d["t"].__setitem__("paused", 0), "expected bool"),
    (lambda d: d.__setitem__("extra", 1), "unknown key"),
    (lambda d: d.pop("k"), "$.k: missing"),
    (lambda d: d.__setitem__("mode", "PANIC"), "not in"),
    (lambda d: d["ready"].__setitem__("worn", 101), "> 100"),
    (lambda d: d["bridges"].__setitem__("O1", "half"), "not in"),
    (lambda d: d["bridges"].__setitem__("o1", "up"), "does not match"),
    (lambda d: d.__setitem__("proj", [["p", "s", 1, ""]] * 9), "items > 8"),
    (lambda d: d["proj"][0].__setitem__(2, "64"), "expected int"),
    (lambda d: d["t"].__setitem__("tick", 403200), "> 403199"),
    (lambda d: d["owners"].__setitem__("pause", "someone"), "not in"),
])
def test_state_rejects(mutate, needle):
    d = state()
    mutate(d)
    e = errs("state", d)
    assert any(needle in x for x in e), e


def test_state_minimal_and_partial_pop():
    d = {"v": 2, "seq": 0, "t": {"y": 1, "tick": 0, "season": 0, "tps": 0, "paused": True}, "mode": "PEACE",
         "k": {"ms_s": 0, "gap_max_ms": 0, "slow": [], "faults": 0}, "ev": 0, "pop": {"cit": 7}}
    assert errs("state", d) == []


def test_event_rules():
    ev = json.loads(DESIGN_EVENT)
    assert errs("event", {**ev, "cls": "B"}) == ["$.cls: SIEGE_END is class A, got B"]
    unknown = {**ev, "type": "NEW_THING"}
    assert errs("event", unknown) and S.validate("event", unknown, strict=False) == []
    assert any("bridge: missing" in x for x in errs("event", {**ev, "type": "GATE_FAIL", "d": {}}))
    assert errs("event", {**ev, "type": "GATE_FAIL", "d": {"bridge": "O1", "why": "no_worker", "extra": 1}}) == []
    assert any("expected int" in x for x in errs("event", {**ev, "type": "MIGRANTS", "d": {"n": "3"}}))
    assert any("bytes" in x for x in errs("event", {**ev, "msg": "ä" * 101}))


@pytest.mark.parametrize("verb,args,ok", [
    ("lever", {"bridge": "O1", "want": "up"}, True),
    ("lever", {"bridge": "O1", "want": "sideways"}, False),
    ("lever", {"bridge": "O1"}, False),
    ("squad.sortie", {"squad": "A", "target": "K1", "approve": True}, True),
    ("squad.sortie", {"squad": "A", "target": [1, 2, 3], "approve": True}, True),
    ("squad.sortie", {"squad": "A", "target": "K1"}, False),
    ("squad.sortie", {"squad": "A", "target": "K1", "approve": 1}, False),
    ("bp.place", {"tpl": "bedrooms", "site": "S2", "n": 20, "tier": 500}, True),
    ("bp.place", {"tpl": "bedrooms", "site": "S2", "nested": {"a": 1}}, False),
    ("bp.place", {"tpl": "Bedrooms", "site": "S2"}, False),
    ("pause", {"ttl_s": 600}, True),
    ("pause", {"ttl_s": 601}, False),
    ("tempo.lower", {"fps": 100, "ttl_s": 60}, True),
    ("audit", {"snap": "c1", "ok": True, "fails": [], "min_traps": 31, "bypass": False, "refuge_sep": True,
               "civ_sep": True, "caverns": True}, True),
    ("audit", {"snap": "c1", "ok": 1, "fails": [], "min_traps": 31, "bypass": False, "refuge_sep": True,
               "civ_sep": True, "caverns": True}, False),
    ("snapshot", {"bbox": [0, 0, 0, 10, 10, 2], "purpose": "audit"}, True),
    ("snapshot", {"bbox": [10, 0, 0, 0, 10, 2]}, False),
    ("inspect", {"what": "census"}, True),
    ("plan.reload", {"x": 1}, False),
    ("trade.want", {"want": ["bar:iron", "anvil"]}, True),
    ("trade.want", {"want": ["Bar Iron"]}, False),
])
def test_verb_args(verb, args, ok):
    doc = {"id": "c1", "verb": verb, "args": args, "by": S.VERB_BY.get(verb, ["llm"])[0]}
    assert (errs("inbox", doc) == []) is ok, errs("inbox", doc)


def test_inbox_envelope():
    good = json.loads(DESIGN_INBOX)
    assert any("not in" in x for x in errs("inbox", {**good, "verb": "lua.exec"}))
    assert any("does not match" in x for x in errs("inbox", {**good, "id": "a b"}))
    assert any("not in" in x for x in errs("inbox", {**good, "by": "someone"}))
    assert S.validate_args("nope", {}) == ["$.verb: unknown verb 'nope'"]
    assert S.inbox_name("c123", 1791676800123) == "1791676800123-c123.json"
    assert re.fullmatch(S.INBOX_NAME_RE, S.inbox_name("c1", 5))
    with pytest.raises(ValueError):
        S.inbox_name("bad id", 1)


def test_outbox_rules():
    assert errs("outbox", {"id": "c1", "ok": True, "msg": "x" * 301})
    assert errs("outbox", {"id": "c1", "ok": True, "msg": "", "data": {"any": [1, {"x": None}]}, "tick": 5}) == []
    assert errs("outbox", {"id": "c1", "ok": "yes", "msg": ""})


def example(kind):
    return copy.deepcopy(next(d for k, d in EXAMPLES if k == kind))


def test_snapshot_geometry():
    s = example("snapshot")
    assert errs("snapshot", s) == []
    s2 = example("snapshot")
    s2["rows"]["z120"][0] = "#..=."
    assert any("width 5, expected 6" in x for x in errs("snapshot", s2))
    s3 = example("snapshot")
    del s3["rows"]["z121"]
    assert any("z121: missing" in x for x in errs("snapshot", s3))
    s4 = example("snapshot")
    s4["rows"]["z120"][0] = "#..@.#"
    assert any("does not match" in x for x in errs("snapshot", s4))
    s5 = example("snapshot")
    s5["rows"]["z119"] = ["......", "......"]
    assert any("outside bbox" in x for x in errs("snapshot", s5))
    s6 = example("snapshot")
    s6["traps"] = [[1, 2, 3, "W", 3], [1, 2, 3, "Q", 0]]
    assert any("not in" in x for x in errs("snapshot", s6))


def test_bp_rules():
    b = example("bp")
    b["stages"][0]["chunks"][0]["cells"] = [[i, 0, 0, "d"] for i in range(41)]
    assert any("items > 40" in x for x in errs("bp", b))
    b = example("bp")
    b["stages"][1]["label"] = b["stages"][0]["label"]
    assert any("unique" in x for x in errs("bp", b))
    b = example("bp")
    b["class"] = "fun"
    assert errs("bp", b)


def test_plan_rules():
    p = json.loads(DESIGN_PLAN)
    p["seasons"] = p["seasons"][:3]
    assert any("3 items < 4" in x for x in errs("plan", p))
    p = json.loads(DESIGN_PLAN)
    p["military"]["pct"] = 15.5
    assert errs("plan", p)
    p = json.loads(DESIGN_PLAN)
    p["orders"]["import"] = ["library/everything"]
    assert errs("plan", p)
    minimal = {k: v for k, v in json.loads(DESIGN_PLAN).items()
               if k in ("v", "year", "policy", "phase_target", "seasons")}
    assert errs("plan", minimal) == []


def test_phases_deliverables():
    ph = example("phases")
    ph["phases"][0]["deliver"].append({"k": "stock", "key": "drink_d"})
    assert any("needs ['min']" in x for x in errs("phases", ph))


def test_manifest_rules():
    m = example("manifest")
    m["bridges"]["O1"]["fp"] = [50, 10, 130, 52, 12, 131]
    assert any("one z level" in x for x in errs("manifest", m))
    m = example("manifest")
    m["bridges"]["O1"]["levers"] = []
    assert any("items < 1" in x for x in errs("manifest", m))
    assert errs("manifest", {"v": 2}) == []


def test_bbox_order():
    m = {"v": 2, "killboxes": [{"id": "K1", "bbox": [5, 0, 0, 4, 1, 1]}]}
    assert any("x0<=x1" in x for x in errs("manifest", m))


def test_decisions():
    text = "# Gordon's answers\nD-01: B   # option B\nD-07: on\nD-04:\nnot a line\n  D-12: 20/25\n"
    d = S.parse_decisions(text)
    assert d == {"D-01": "B", "D-07": "on", "D-12": "20/25"}
    assert S.decision("D-01", d) == "B"
    assert S.decision("D-09", d) == "no"
    with pytest.raises(KeyError):
        S.decision("D-99")


def test_check_raises():
    with pytest.raises(S.SchemaError) as ei:
        S.check("outbox", {"id": "c1"})
    assert ei.value.kind == "outbox" and ei.value.errors
    with pytest.raises(KeyError):
        S.validate("nope", {})


def test_cli_validate(tmp_path):
    f = tmp_path / "events.jsonl"
    f.write_text(DESIGN_EVENT + "\n" + DESIGN_EVENT.replace('"cls":"A"', '"cls":"C"') + "\n", encoding="utf-8")
    r = subprocess.run([sys.executable, "-m", "df_llm_helper.schema", "validate", "event", str(f)],
                       capture_output=True, text=True, cwd=ROOT)
    assert r.returncode == 1
    assert "2 document(s), 1 error(s)" in r.stdout


# ---------------------------------------------------------------- contract.lua agreement
@pytest.fixture(scope="module")
def lua_dump():
    r = luahost.run_file(ROOT / "tests" / "lua" / "dump_contract.lua", timeout=30)
    assert r.ok, r.out + r.err
    return json.loads(r.out)


@needs_lua
def test_contract_lua_matches_schema(lua_dump):
    d = lua_dump
    assert d["modes"] == S.MODES
    assert d["postures"] == S.POSTURES
    assert d["decisions"] == S.DECISIONS
    assert d["legend"] == S.SNAP_LEGEND
    assert d["state_owners"] == S.STATE_OWNERS
    assert d["transitions"] == {k: sorted(v) for k, v in S.TRANSITIONS.items()}
    assert d["mode_setters"] == {"siege": "*", "drill": sorted(S.MODE_SETTERS["drill"])}
    assert d["events"] == {k: [c, b] for k, (c, b, _) in S.EVENTS.items()}
    assert d["verbs"] == {k: [m, sorted(modes) if modes else None, a] for k, (m, modes, a) in S.VERBS.items()}
    assert set(S.VERB_ARGS) == set(S.VERBS)
    assert d["act"] == S.ACT
    assert [tuple(m) for m in d["modules"]] == S.MODULES
    assert d["persist"] == {k: list(v) for k, v in S.PERSIST.items()}


@needs_lua
def test_mock_output_conforms(lua_dump):
    m = lua_dump["mock"]
    assert S.validate("state", m["state"]) == []
    assert m["state"]["mode"] == "ALERT"
    assert len(json.dumps(m["state"], separators=(",", ":"))) <= 4096
    types = [e["type"] for e in m["events"]]
    assert {"DECISION_NEEDED", "SIEGE_END", "MODE", "CMD"} <= set(types)
    for e in m["events"]:
        assert S.validate("event", e) == [], e
    for r in m["replies"]:
        assert S.validate("outbox", r) == [], r
    assert [r["ok"] for r in m["replies"]] == [True, False]


# ---------------------------------------------------------------- review round 1 (state spec, decisions, trust, caps)
FMT = {S.ID_RE: "id", S.BRIDGE_RE: "bridge", S.MODULE_RE: "module", S.PHASE_RE: "phase"}


def norm_spec(spec):
    """schema.py spec tree in the node format of contract.STATE_SPEC (tests/lua/dump_contract.lua)."""
    if isinstance(spec, S.Int):
        return {"t": "int", **({"lo": spec.lo} if spec.lo is not None else {}),
                **({"hi": spec.hi} if spec.hi is not None else {})}
    if isinstance(spec, S.Str):
        d = {"t": "str"}
        if spec.maxbytes is not None:
            d["max"] = spec.maxbytes
        if spec.enum is not None:
            d["enum"] = list(spec.enum)
        if spec.pattern:
            d["fmt"] = FMT[spec.pattern]
        return d
    if isinstance(spec, S.Bool):
        return {"t": "bool"}
    if isinstance(spec, S.Null):
        return {"t": "null"}
    if isinstance(spec, S.Const):
        return {"t": "const", "v": spec.value}
    if isinstance(spec, S.Arr):
        return {"t": "arr", "items": norm_spec(spec.items), "lo": spec.lo,
                **({"hi": spec.hi} if spec.hi is not None else {})}
    if isinstance(spec, S.Tup):
        assert spec.opt == 0
        return {"t": "tup", "items": [norm_spec(x) for x in spec.items]}
    if isinstance(spec, S.Obj):
        d = {"t": "obj", "req": {k: norm_spec(v) for k, v in spec.req.items()},
             "opt": {k: norm_spec(v) for k, v in spec.opt.items()}}
        if spec.extra is not None:
            d["extra"] = norm_spec(spec.extra)
        if spec.keys_src:
            d["keys"] = FMT[spec.keys_src]
        return d
    if isinstance(spec, S.AnyOf):
        return {"t": "any", "of": [norm_spec(x) for x in spec.opts]}
    raise TypeError(type(spec).__name__)


@needs_lua
def test_state_spec_lua_matches_schema(lua_dump):
    assert lua_dump["state_spec"] == norm_spec(S.STATE)


@needs_lua
def test_kern_limits_and_verb_by_match(lua_dump):
    assert lua_dump["kern"] == S.KERN
    assert lua_dump["verb_by"] == {k: sorted(v) for k, v in S.VERB_BY.items()}


NULL_MARK = "\u0000null"  # stands for JSON null: util/json drops null object members on decode


def _mark(v):
    if v is None:
        return NULL_MARK
    if isinstance(v, dict):
        return {k: _mark(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_mark(x) for x in v]
    return v


def run_probe(tmp_path, state_docs=(), decisions=()):
    f = tmp_path / "probe_in.json"
    f.write_text(json.dumps({"state": [_mark(d) for d in state_docs], "decisions": list(decisions)}),
                 encoding="utf-8")
    r = luahost.run_file(ROOT / "tests" / "lua" / "contract_probe.lua", [str(f)], timeout=30)
    assert r.ok, r.out + r.err
    return json.loads(r.out.strip().splitlines()[-1])


def _set(path, value):
    def f(d):
        *head, last = path
        for k in head:
            d = d[k]
        d[last] = value
    return f


STATE_VECTORS = [
    ("seq bool", _set(["seq"], True)),
    ("paused int", _set(["t", "paused"], 0)),
    ("unknown top key", _set(["extra"], 1)),
    ("missing k", lambda d: d.pop("k")),
    ("missing t.y", lambda d: d["t"].pop("y")),
    ("v 3", _set(["v"], 3)),
    ("bad mode", _set(["mode"], "PANIC")),
    ("worn 101", _set(["ready", "worn"], 101)),
    ("bridge state", _set(["bridges", "O1"], "half")),
    ("bridge name", _set(["bridges", "o1"], "up")),
    ("bridges array", _set(["bridges"], [])),
    ("proj 9", _set(["proj"], [["p", "s", 1, ""]] * 9)),
    ("proj pct str", lambda d: d["proj"][0].__setitem__(2, "64")),
    ("proj short", _set(["proj"], [["p", "s", 1]])),
    ("ytick range", _set(["t", "tick"], 403200)),
    ("pause owner", _set(["owners", "pause"], "someone")),
    ("pause missing", _set(["owners"], {"tempo": "mode"})),
    ("pop cap neg", _set(["pop", "cap"], -1)),
    ("ready partial", _set(["ready"], {"lvl": 1, "bogus": 2})),
    ("threat partial", _set(["threat"], {"vis": 1})),
    ("slow module name", _set(["k", "slow"], ["Sense"])),
    ("phase P8", _set(["phase"], "P8")),
    ("save too long", _set(["save"], "ä" * 61)),
    ("fail 9 + long", _set(["ready", "fail"], ["x"] * 8 + ["y" * 25])),
]
VALID_VECTORS = [
    ("valid", lambda d: None),
    ("pause null", _set(["owners", "pause"], None)),
    ("disabled empty", _set(["k", "disabled"], [])),
    ("stock empty", _set(["stock"], {})),
    ("pop partial", _set(["pop"], {"cit": 3})),
]


@needs_lua
def test_state_vectors_agree_with_lua(tmp_path):
    vectors = VALID_VECTORS + STATE_VECTORS
    docs = []
    for _, mutate in vectors:
        d = state()
        mutate(d)
        docs.append(d)
    docs.append([])  # not an object
    got = run_probe(tmp_path, state_docs=docs)["state"]
    for (name, _), doc, lua_paths in zip(vectors + [("array doc", None)], docs, got):
        py_paths = sorted({e.split(": ", 1)[0] for e in S.validate("state", doc)})
        assert py_paths == lua_paths, (name, S.validate("state", doc))
        assert bool(py_paths) is (name not in dict(VALID_VECTORS)), name


def test_prune_state():
    d = state()
    assert S.prune_state(d) == (d, [])
    d["bridges"], d["threat"] = [], {"vis": 1}
    pruned, e = S.prune_state(d)
    assert len(e) == 2 and "bridges" not in pruned and "threat" not in pruned and pruned["ready"]["lvl"] == 1
    d = state()
    d["seq"] = -1
    assert S.prune_state(d)[0] is None
    assert S.prune_state([])[0] is None


DECISION_VECTORS = json.loads((ROOT / "fixtures" / "v2" / "decisions_vectors.json")
                              .read_text(encoding="utf-8"))["vectors"]


@pytest.mark.parametrize("vec", DECISION_VECTORS, ids=[v["name"] for v in DECISION_VECTORS])
def test_decision_vectors_python(vec):
    assert S.parse_decisions(vec["text"]) == vec["want"]


@pytest.fixture(scope="module")
def decision_probe(tmp_path_factory):
    return run_probe(tmp_path_factory.mktemp("dec"), decisions=[v["text"] for v in DECISION_VECTORS])


@needs_lua
def test_decision_vectors_lua_contract(decision_probe):
    for vec, got in zip(DECISION_VECTORS, decision_probe["decisions"]):
        assert got == vec["want"], vec["name"]


@needs_lua
def test_decision_vectors_kernel_reader(decision_probe):   # kern uses contract.parse_decisions (§9.16)
    assert decision_probe["kern"] is not None, decision_probe["kern_err"]
    for vec, got in zip(DECISION_VECTORS, decision_probe["kern"]):
        assert got == vec["want"], vec["name"]


def test_bp_size_caps():
    b = example("bp")
    assert errs("bp", b) == []
    big = [[i % 40, i // 40, 0, "d"] for i in range(S.BP_MAX_CELLS + 1)]
    b["stages"][0]["chunks"] = [{"pos": [60, 40, 120], "cells": big[i:i + 40]} for i in range(0, len(big), 40)]
    assert any("cells >" in x for x in errs("bp", b))
    b = example("bp")
    b["stages"][0]["chunks"] = [{"pos": [60, 40, 120], "cells": [[0, 0, 0, "x" * 64]] * 40}] * 10
    assert any("bytes of compact JSON" in x for x in errs("bp", b))


def test_inbox_by_and_module_enable():
    audit = {"snap": "c1", "ok": True, "fails": [], "min_traps": 31, "bypass": False, "refuge_sep": True,
             "civ_sep": True, "caverns": True}
    for by, ok in [("follow", True), ("test", True), ("llm", False), ("gordon", False), ("cli", False)]:
        doc = {"id": "c1", "verb": "audit", "args": audit, "by": by}
        assert (errs("inbox", doc) == []) is ok, (by, errs("inbox", doc))
    good = {"id": "c2", "verb": "module.enable", "args": {"module": "siege"}, "by": "llm"}
    assert errs("inbox", good) == []
    assert errs("inbox", {**good, "args": {"module": "Siege"}})
    assert errs("inbox", {**good, "args": {}})
    assert S.ACT["squad_leader"] == ["military"]
