"""wake gamelog rules (df_llm_helper/wakerules.py): fixtures with gamelog-style lines, rotation, rate limit, wake_check."""
from __future__ import annotations

from pathlib import Path

import pytest

from df_llm_helper.clock import FakeClock
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from df_llm_helper.wake import wake_check
from df_llm_helper.wakerules import build_rules, gamelog_events, match_line, read_since

FIX = Path(__file__).resolve().parent.parent / "fixtures" / "wake" / "gamelog_sample.txt"
RULES = build_rules(None)


def cat(line):
    m = match_line(line, RULES)
    return m and (m[0]["name"], m[1], m[2])


@pytest.mark.parametrize("line,expect", [
    ("Reg Sefolfikod, Carpenter has been found dead, dehydrated.", ("death_tantrum_mood", "death", "Reg Sefolfikod")),
    ("Urist McMiner has been struck down.", ("death_tantrum_mood", "death", "Urist McMiner")),
    ("Ast Kadol, Mason is throwing a tantrum!", ("death_tantrum_mood", "tantrum", "Ast Kadol")),
    ("Datan Onulrigoth, Peasant has gone berserk!", ("death_tantrum_mood", "berserk", "Datan Onulrigoth")),
    ("Mosus Lorbamuz, Metalsmith has been taken by a fey mood!", ("death_tantrum_mood", "mood", "Mosus Lorbamuz")),
    ("Mosus has been taken by a possessed mood!", ("death_tantrum_mood", "mood", "Mosus")),
    ("Id Lorbam, Farmer has been drained of blood.", ("death_tantrum_mood", "death", "Id Lorbam")),
    ("A vile force of darkness has arrived!", ("alarm_hard", "siege", "")),
    ("Ambush!  A group of goblins has been spotted.", ("alarm_hard", "ambush", "")),
    ("A forgotten beast has come! The Fiend of Rot", ("alarm_hard", "forgotten-beast", "")),
    ("A caravan from The Gilded Hammers has arrived.", ("caravan", "", "Gilded Hammers")),
    ("The ghost of Reg has been seen haunting the fortress.", ("ghost", "", "")),
    ("The ghost is restless.", ("ghost", "", "")),
])
def test_match(line, expect):
    assert cat(line) == expect


@pytest.mark.parametrize("line", ["Cattle gives birth to a calf.", "Urist McMiner cancels Mine: Interrupted by Dehydrated.",
                                  "The Mountainhomes have lost 1 workers..."])
def test_no_match(line):
    assert cat(line) is None


def test_fixture_cp437_and_rate_limit(tmp_path):
    log = tmp_path / "gamelog.txt"
    log.write_bytes(b"old line\r\n")
    st: dict = {}
    assert gamelog_events(log, st, RULES, 1000.0) == []          # baseline: history is not replayed
    log.write_bytes(b"old line\r\n" + FIX.read_bytes())
    out = gamelog_events(log, st, RULES, 1000.0)
    text = "\n".join(out)
    assert "WAKE caravan: Gilded Hammers" in text
    assert text.count("tantrum") == 1 or "Ast Kadol" in text    # duplicate identical line within the cooldown suppressed
    assert sum("Ast Kadol" in o for o in out) == 1
    assert any(o.startswith("WAKE death_tantrum_mood") or o.startswith("WAKE unit/death") for o in out)
    assert any(o.startswith("WAKE alarm/siege") for o in out) and any(o.startswith("WAKE alarm/ambush") for o in out)
    assert sum(o.startswith("WAKE caravan") for o in out) == 1   # 'merchants have arrived' shares the category limit
    assert any(o.startswith("WAKE ghost") for o in out)
    assert all(o.endswith(tuple("abcdefghijklmnopqrstuvwxyz)")) and " -> " in o for o in out)


def test_category_cooldown_counts_suppressed(tmp_path):
    log = tmp_path / "g.txt"
    log.write_text("x\n", encoding="utf-8")
    st: dict = {}
    gamelog_events(log, st, RULES, 0.0)
    with log.open("a") as f:
        f.write("A ghost walks.\nThe ghost of Bob haunts.\nA restless ghost.\n")
    assert len(gamelog_events(log, st, RULES, 10.0)) == 1
    with log.open("a") as f:
        f.write("A restless ghost again.\n")
    out = gamelog_events(log, st, RULES, 10.0 + 901)
    assert len(out) == 1 and "(+2 suppressed)" in out[0]


def test_rotation_and_partial_line(tmp_path):
    log = tmp_path / "gamelog.txt"
    log.write_text("first line of game one\nsecond\n", encoding="utf-8")
    lines, pos, head = read_since(log, None, None)
    assert lines == [] and pos == log.stat().st_size
    log.write_text("brand new game\nA ghost appears\nhalf a li", encoding="utf-8")      # rotation + incomplete last line
    lines, pos2, head2 = read_since(log, pos, head)
    assert lines == ["brand new game", "A ghost appears"]
    log.write_text("brand new game\nA ghost appears\nhalf a line\n", encoding="utf-8")
    assert read_since(log, pos2, head2)[0] == ["half a line"]
    assert read_since(tmp_path / "missing.txt", 5, "x")[0] == []


def test_config_override_disable_and_extra(tmp_path):
    rules = build_rules({"rules": {"ghost": {"enabled": False}, "alarm_hard": {"cooldown_s": 1}},
                         "extra": [{"name": "plague", "pattern": r"plague", "next": "look", "cooldown_s": 10},
                                   {"name": "broken", "pattern": "("}]})
    names = [r["name"] for r in rules]
    assert "ghost" not in names and "plague" in names and "broken" not in names
    assert next(r for r in rules if r["name"] == "alarm_hard")["cooldown_s"] == 1
    log = tmp_path / "g.txt"
    log.write_text("a\n", encoding="utf-8")
    st: dict = {}
    gamelog_events(log, st, rules, 0.0)
    log.write_text("a\nA plague spreads.\nThe ghost haunts.\n", encoding="utf-8")
    assert gamelog_events(log, st, rules, 1.0) == ["WAKE plague: A plague spreads. -> look"]


def test_wake_check_integration(tmp_path):
    clk = FakeClock(1_790_840_000.0)
    tools = ToolsDir(tmp_path / "tools", clk)
    (tmp_path / "tools").mkdir()
    store = Store(tmp_path / "s.db")
    log = tmp_path / "gamelog.txt"
    log.write_text("hello\n", encoding="utf-8")
    assert wake_check(tools, store, clk, gamelog=str(log)) == []
    with log.open("a") as f:
        f.write("Reg, Carpenter has been found dead, dehydrated.\n")
    out = wake_check(tools, store, clk, gamelog=str(log))
    assert len(out) == 1 and out[0].startswith("WAKE unit/death: Reg |")
    assert wake_check(tools, store, clk, gamelog=str(log)) == []
    with log.open("a") as f:
        f.write("A ghost.\n")
    assert wake_check(tools, store, clk, gamelog=str(log), rules_cfg={"enabled": False}) == []


def test_pause_hold_wakes(tmp_path):
    clk = FakeClock(1_790_840_000.0)
    (tmp_path / "tools").mkdir()
    tools = ToolsDir(tmp_path / "tools", clk)
    store = Store(tmp_path / "s.db")
    wake_check(tools, store, clk)
    (tmp_path / "tools" / "pause.hold").write_text("trade", encoding="utf-8")
    out = wake_check(tools, store, clk)
    assert len(out) == 1 and out[0].startswith("WAKE pause:")


# ---------------------------------------------------------------- Lua watchers (static checks; no Lua runtime needed)
LUA = Path(__file__).resolve().parent.parent / "lua" / "claude"
WACHTEN = ["stresswacht", "hospitalwacht", "geisterwacht", "aemterwacht", "binwacht", "schmelzwacht"]


@pytest.mark.parametrize("name", WACHTEN + ["wachen"])
def test_lua_watcher_generic(name):
    import re
    t = (LUA / f"{name}.lua").read_text(encoding="utf-8")
    assert not re.search("[A-Za-z]:[/" + chr(92) * 2 + "]|/Users/|dwarf-fortress/", t), "hard-wired path"
    assert t.count("(") == t.count(")") and t.count("{") == t.count("}")
    if name != "wachen":
        assert (name == "binwacht" or "util.home()" in t) and "'start'" in t and "'stop'" in t


def test_wachen_default_list_scripts_exist():
    import re
    t = (LUA / "wachen.lua").read_text(encoding="utf-8")
    block = t[t.index("local LIST"):t.index("local function start_all")]
    for script in re.findall(r"'(\w+) [\w ]+'", block):
        assert (LUA / f"{script}.lua").exists(), script
    assert "WACHEN_LIST" in (LUA / "config.lua").read_text(encoding="utf-8")
