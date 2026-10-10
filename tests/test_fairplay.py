"""WP4: decisions (config/decisions.yaml) and the act.run allowlist (config/allowlist.json)."""
import json
import re
import sys
from pathlib import Path

import pytest

from df_llm_helper import fairplay as F
from df_llm_helper import schema as S

ROOT = Path(__file__).resolve().parent.parent
TOOLS_DOCS = Path(r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress\hack\docs\docs\tools")
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402


# ---------------------------------------------------------------- decisions
def test_decisions_file_holds_the_design_defaults_all_open():
    assert F.load_decisions() == S.DECISIONS
    assert S.parse_decisions(F.DECISIONS_PATH.read_text(encoding="utf-8")) == S.DECISIONS
    assert F.pending() == list(S.DECISIONS)                      # nothing answered yet
    assert F.decision_errors() == []
    assert F.get_decision("D-12") == "15/20" and F.decisions.get("D-01") == "A"
    assert F.decisions.all() == S.DECISIONS
    with pytest.raises(KeyError):
        F.get_decision("D-99")


def test_every_default_is_a_valid_choice():
    assert set(F.CHOICES) == set(S.DECISIONS)
    for did, dflt in S.DECISIONS.items():
        assert F._valid(did, dflt), did


def test_answers_invalid_values_and_missing_lines(tmp_path):
    p = tmp_path / "decisions.yaml"
    p.write_text("\ufeff# header\nD-01: B  # answered 2026-10-12 by Gordon\nD-04: maybe  # typo\n"
                 "D-07:visitor30#answered\nD-12: 20/25\nD-55: x\n", encoding="utf-8")
    d = F.load_decisions(p)
    assert d["D-01"] == "B" and d["D-07"] == "visitor30" and d["D-12"] == "20/25"
    assert d["D-04"] == "off"                                    # invalid -> default (fail safe)
    assert d["D-09"] == "no"                                     # missing -> default
    errs = F.decision_errors(p)
    assert any("D-04" in e for e in errs) and any("D-55" in e for e in errs)
    pend = F.pending(p)
    assert "D-01" not in pend and "D-07" not in pend and "D-12" not in pend and "D-04" not in pend
    assert "D-09" in pend
    assert F._Decisions(p).get("D-01") == "B"
    assert F.load_decisions(tmp_path / "missing.yaml") == S.DECISIONS


@pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")
def test_decisions_readable_by_a_tiny_lua_parser(tmp_path):
    """The kernel reads the same file with a Lua pattern equivalent of the CONTRACTS §9.16 regex."""
    src = r"""
local json = require('dfllm.util.json')
local out = {}
for line in io.lines(arg[1]) do
  line = line:gsub('^\239\187\191', '')
  local id, rest = line:match('^[ \t]*(D%-%d%d)[ \t]*:(.*)$')
  if id then
    local val = rest:gsub('#.*$', ''):match('^[ \t]*(.-)[ \t\r]*$')
    if val ~= '' then out[id] = val end
  end
end
print(json.encode(out))
"""
    f = tmp_path / "read_decisions.lua"
    f.write_text(src, encoding="utf-8")
    r = luahost.run_file(f, [str(F.DECISIONS_PATH)], timeout=10)
    assert r.ok, r.err
    assert json.loads(r.out.strip().splitlines()[-1]) == S.DECISIONS


# ---------------------------------------------------------------- allowlist: file and semantics
def test_allowlist_validates_and_is_explicit():
    al = F.allowlist()
    assert S.validate("allowlist", al) == []
    for cmd, e in al["commands"].items():
        for p in e["args"]:
            toks = p.split()
            assert "**" not in toks[:-1], (cmd, p)               # '**' only as the last token
        if cmd in ("control-panel", "enable"):                   # no wildcard enable
            assert not any(re.fullmatch(r"(enable )?\*\*?", p) for p in e["args"]), cmd
    assert "lever" not in al["commands"] and al["armok_exceptions"] == ["lever"]
    assert "dfllm" not in al["commands"]                         # act.run never calls ourselves


MINI = {"v": 2, "commands": {"a": {"rw": "w", "args": []}, "b": {"rw": "w", "args": [""]},
                             "c": {"rw": "w", "args": ["x *", "y **", "z"]}, "d": {"rw": "r", "args": ["**"]}},
        "blocked": ["c z", "--bad", "fastdwarf"], "armok_exceptions": []}


@pytest.mark.parametrize("cmd,args,ok", [
    ("a", [], True), ("a", ["1"], False),                        # empty list: bare command only
    ("b", [], True), ("b", ["1"], False),                        # "": no arguments
    ("c", ["x", "1"], True), ("c", ["x"], False), ("c", ["x", "1", "2"], False),
    ("c", ["y"], True), ("c", ["y", "1", "2", "3"], True),       # '**' = any rest, also none
    ("c", ["z"], False),                                         # blocked wins over commands
    ("c", ["y", "--bad"], False), ("d", ["q", "--bad=1"], False),  # a blocked flag anywhere
    ("c", ["x 1"], True),                                        # args are joined, then split
    ("e", [], False), ("fastdwarf", ["1"], False),
    ("d", [], True), ("d", ["anything", "goes"], True),
])
def test_check_run_semantics(cmd, args, ok):
    assert F.check_run(cmd, args, MINI)[0] is ok


def test_match_args_edge_cases():
    assert F.match_args("", []) and not F.match_args("", ["x"])
    assert F.match_args("**", []) and F.match_args("* **", ["a"]) and not F.match_args("* **", [])
    assert not F.match_args("a b", ["a"])


ALWAYS_BLOCKED = [   # DESIGN §11.4 plus the hook's done criteria
    "digv", "digvx", "digtype --hidden", "fastdwarf 1", "caravan extend", "caravan happy", "autodump",
    "locate-ore", "prospect all", "showmood", "reveal", "createitem BAR INORGANIC:IRON 5", "dig-now",
    "build-now", "fix/retrieve-units", "teleport -x 1", "lever pull --id 3 --instant", "lever pull --id 3",
    "control-panel enable fastdwarf", "enable fastdwarf", "control-panel enable 25",
    "control-panel autostart fastdwarf", "quickfort run x --instant", "gui/gm-editor", "tiletypes",
    "liquids", "exterminate", "migrants-now", "strangemood", "embark-skills", "unreveal", "revflood",
]


@pytest.mark.parametrize("line", ALWAYS_BLOCKED)
def test_always_blocked(line):
    t = line.split()
    assert F.check_run(t[0], t[1:])[0] is False, line


BASELINE = [         # DESIGN §5.5, §5.11, §4, §10: what the kernel must be able to run
    "control-panel enable suspendmanager", "control-panel enable autochop", "control-panel enable autobutcher",
    "control-panel enable autonestbox", "control-panel enable nestboxes", "control-panel enable autoslab",
    "control-panel enable preserve-tombs", "control-panel enable tailor", "control-panel enable seedwatch",
    "control-panel enable pop-control", "control-panel enable timestream", "control-panel enable prioritize",
    "control-panel enable fix/dead-units", "control-panel enable fix/empty-wheelbarrows", "control-panel enable combine",
    "enable buildingplan", "enable logistics", "enable idle-crafting", "enable preserve-rooms",
    "labormanager enable", "enable burrow", "burial", "prioritize -a defaults", "autochop target 14",
    "autochop target 40 14", "autobutcher target 2 2 2 2 all", "autobutcher autowatch",
    "tailor materials silk cloth yarn", "tailor confiscate false", "pop-control set max-pop 55",
    "pop-control set wave-size 8", "labormanager mode monitor", "labormanager mode modern",
    "labormanager balance balanced", "labormanager labor MINE unmanaged", "labormanager status",
    "autolabor mode monitor", "ban-cooking booze honey milk oil tallow", "seedwatch PLUMP_HELMET 12",
    "seedwatch all 12", "seedwatch clear", "uniform-unstick --all --drop --free",
    "fix/stuck-merchants", "fix/dead-units", "fix/empty-wheelbarrows", "combine all -q",
    "logistics add melt -s 7", "logistics add trade -s crafts", "logistics now", "burial -c",
    "labormanager mode", "control-panel disable work-now", "disable emigration", "control-panel disable deteriorate",
    "overlay list", "autochop target 40 14", "autobutcher target 0 0 1 1 CAT", "tailor materials silk cloth yarn",
]


# DESIGN §3: these actuators have a dedicated act function with an owner check (act.lua runs the command
# itself); act.run and the dev shell must never reach them (review WP4)
OWNED_LINES = [
    "timestream set fps 1000", "timestream set fps 500", "timestream", "timestream reset",
    "pop-control set max-pop 200", "pop-control set max-pop 56",
    "quickfort run library/dreamfort.csv -n /dig", "quickfort orders /tmp/x.csv", "quickfort undo x",
    "workorder {}", "orders import library/basic", "orders sort", "orders recheck", "orders clear",
    "overlay enable hotkeys.menu", "overlay disable all", "enable overlay", "disable overlay",
    "control-panel enable overlay", "disable timestream", "control-panel disable timestream",
    "disable pop-control", "control-panel disable pop-control", "disable autochop timestream",
    "zone assign 1 2", "zone unassign 1", "burrow tiles clear Kern+", "burrow units add Kern+ 5",
    "gui/civ-alert",
]
NOT_OWNED_BUT_REFUSED = ["disable suspendmanager", "control-panel disable suspendmanager", "disable *",
                         "control-panel disable 3", "control-panel enable 3", "pop-control set max-pop *"]


@pytest.mark.parametrize("line", OWNED_LINES)
def test_owned_actuators_are_not_reachable_through_act_run(line):
    t = line.split()
    assert F.owned_match(t) is not None, line
    assert F.check_run(t[0], t[1:])[0] is False, line


@pytest.mark.parametrize("line", NOT_OWNED_BUT_REFUSED)
def test_safety_natives_cannot_be_disabled(line):
    t = line.split()
    assert F.check_run(t[0], t[1:])[0] is False, line


def test_owned_match_exemptions():
    assert F.owned_match("pop-control set max-pop 55".split()) is None      # R0 cap, baseline.lua:198
    assert F.owned_match("control-panel enable timestream".split()) is None  # baseline, D-11
    assert F.owned_match("enable burrow".split()) is None                    # the burrow plugin itself
    assert F.owned_match("overlay list".split()) is None
    assert F.owned_match("pop-control set wave-size 8".split()) is None


@pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")
def test_lua_gate_agrees_with_python(tmp_path):
    """act.lua's A.allowed (the gate kern runs) and fairplay.check_run decide every vector the same way."""
    lines = BASELINE + ALWAYS_BLOCKED + OWNED_LINES + NOT_OWNED_BUT_REFUSED
    (tmp_path / "lines.json").write_text(json.dumps([x.split() for x in lines]), encoding="utf-8")
    src = r"""
local json = require('dfllm.util.json')
local A = require('dfllm.act')
local function slurp(p) local f = assert(io.open(p, 'rb')); local s = f:read('a'); f:close(); return s end
local al = json.decode(slurp(arg[1]))
local out = {}
for i, t in ipairs(json.decode(slurp(arg[2]))) do
  local args = {}
  for k = 2, #t do args[#args + 1] = t[k] end
  out[i] = A.allowed(al, t[1], args) and 1 or 0
end
print(json.encode(out))
"""
    f = tmp_path / "gate.lua"
    f.write_text(src, encoding="utf-8")
    r = luahost.run_file(f, [str(F.ALLOWLIST_PATH), str(tmp_path / "lines.json")], timeout=20)
    assert r.ok, r.err
    lua_says = json.loads(r.out.strip().splitlines()[-1])
    py_says = [1 if F.check_run(x.split()[0], x.split()[1:])[0] else 0 for x in lines]
    assert lua_says == py_says, [(x, a, b) for x, a, b in zip(lines, lua_says, py_says) if a != b]


@pytest.mark.parametrize("line", BASELINE)
def test_kernel_baseline_is_allowed(line):
    t = line.split()
    ok, why = F.check_run(t[0], t[1:])
    assert ok, (line, why)


@pytest.mark.parametrize("line", [
    "control-panel enable work-now", "enable work-now", "control-panel enable agitation-rebalance",
    "control-panel enable emigration", "control-panel enable deteriorate", "tailor confiscate true",
    "cleanowned all", "labormanager mode legacy", "autolabor enable", "enable autolabor",
    "enable labormanager",  # no such plugin: labormanager lives in autolabor.plug.dll (`labormanager enable`)
])
def test_decision_gated_tools_are_off_by_default(line):
    """D-04/05/06/10 default off: the allowlist ships without them (docs/v2/DECISIONS.md)."""
    t = line.split()
    assert F.check_run(t[0], t[1:])[0] is False, line


def _doc_tags():
    """{command: tags} from the installed DFHack tool docs (Tags: and Command: lines)."""
    out = {}
    for f in TOOLS_DOCS.rglob("*.txt"):
        text = f.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"^Tags: (.*)$", text, re.M)
        if not m:
            continue
        tags = {t.strip() for t in m.group(1).split("|")}
        for c in re.findall(r'^Command: "([^"]+)"', text, re.M):
            out[c] = tags
    return out


@pytest.mark.skipif(not TOOLS_DOCS.is_dir(), reason="DFHack docs not installed")
def test_armok_cross_check_offline():
    """The boot check (DESIGN §11.4) against helpdb tags, done offline from the same docs."""
    tags = _doc_tags()
    armok = {c for c, t in tags.items() if "armok" in t}
    assert {"lever", "fastdwarf", "reveal", "createitem", "caravan"} <= armok
    al = F.allowlist()
    assert F.armok_problems(armok) == []
    for c in sorted(armok):                                      # every armok tool is refused by act.run
        assert c in al["armok_exceptions"] or F.check_run(c, [])[0] is False, c
        assert c in al["armok_exceptions"] or F.blocked_match([c]), f"armok tool {c} missing from blocked"
    assert F.armok_problems({"autochop"}) == ["autochop"]        # the check itself works


def test_v1_names_are_forwarded():
    from df_llm_helper.fairplay import ExceptionRegistry, FairPlayError, check_command  # noqa: F401
    from df_llm_helper._v1 import fairplay as v1
    assert ExceptionRegistry is v1.ExceptionRegistry
    with pytest.raises(AttributeError):
        F.no_such_name  # noqa: B018
