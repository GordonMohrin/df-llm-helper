"""Spec 11 dashboard: HTML valid/offline/< 200 KB, values only from state.db, dark/narrow, warnings = digest,
map excerpt = fixture matrix (claude/area from fixtures/run5)."""
import html
import json
import re

from conftest import FIX
from dfpilot.client import MockClient
from dfpilot.clock import FakeClock
from dfpilot.config import DEFAULTS as CFG
from dfpilot.dashboard import (BUILDPLAN, DEFAULTS, LOCATIONS_CMD, collect, parse_locations, render, validate_html,
                               write_if_changed)
from dfpilot.digest import DigestState, build_digest
from dfpilot.store import Store
from helpers import snap_for

T0 = 1_790_000_000.0


def history_store(n=37, step=600, **kw):
    """6 hours of history (every 10 min), population grows, idle fluctuates; digest state as in the real check."""
    st = Store()
    state = DigestState()
    for i in range(n):
        snap = snap_for(pop=20 + i // 6, idle=3 + (i % 5), **kw)
        st.add_snapshot(T0 + i * step, snap.game_id, snap.facts())
        _, state = build_digest(snap, state, th=CFG["thresholds"])
    st.set("digest.state.all", state.to_dict())
    return st, snap


def test_html_valid_offline_small_and_dark_mode():
    """Acceptance 1 + 3."""
    st, _ = history_store()
    for i in range(400):                                                   # many events
        st.warn(T0 + i, "test", f"k{i}", "Event " * 20, "warn")
        st.log_action(T0 + i, "test", "r", "a", "x", "claude/x " * 10, False, True, "")
    text = render(collect(st, T0 + 37 * 600))
    assert validate_html(text) == []
    assert len(text.encode("utf-8")) < 200 * 1024
    assert "prefers-color-scheme:dark" in text and 'name="viewport"' in text and "max-width:480px" in text
    assert "<script" not in text and "http" not in text
    assert validate_html("<div><span></div>") and validate_html("<!doctype html><p>" + "x" * 210_000 + "</p>")


def test_values_only_from_state_db_no_placeholders():
    """Acceptance 2."""
    st, snap = history_store()
    d = collect(st, T0 + 37 * 600)
    text = render(d)
    last = d["last"]
    assert f">{last['pop']}<" in text and f">{last['idle_pct']} %<" in text
    assert text.count('class="spark"') >= 4
    for bad in ("None", "?", "TODO", "lorem", "XX"):
        assert bad not in re.sub(r"<style>.*?</style>", "", text), bad
    assert all(f"<h2>{h}" not in text for h in ("Build plan", "Trade", "Map", "Bottleneck"))   # no source, no section
    empty = render(collect(Store(), T0))
    assert "No snapshot yet" in empty and validate_html(empty) == []


def test_warnings_match_digest():
    """Acceptance 4: warnings are exactly those of the digest state."""
    st, snap = history_store(drink_days=8, enemies=3)
    alerts = st.get("digest.state.all")["alerts"]
    assert alerts
    text = render(collect(st, T0 + 37 * 600))
    sect = text.split("<h2>Warnings</h2>")[1].split("<h2>")[0]
    shown = re.findall(r"<li class=\"(\w+)\">", sect)
    assert len(shown) == len(alerts)
    for v in alerts.values():
        assert html.escape(v["text"]) in sect
    st2, _ = history_store(drink_days=80, enemies=0, corpses=0, stress_high=0)
    st2.set("digest.state.all", {"alerts": {}})
    t2 = render(collect(st2, T0 + 37 * 600))
    assert "No open warnings" in t2 and "<li class=\"red\"" not in t2


def test_map_reproduces_fixture_matrix(tmp_path, tools_dir, capsys):
    """Acceptance 5 (map excerpt; fixture fixtures/run5/area_z130.txt = claude/area 130 80 90 40 28)."""
    from dfpilot.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "dashboard", "map", "Core", "80", "90", "130", "40", "28"]) == 0
    out = tmp_path / "d.html"
    assert main(["--config", str(c), "--mock", str(FIX), "dashboard", "--out", str(out)]) == 0
    text = out.read_text(encoding="utf-8")
    pre = html.unescape(text.split("<h2>Map Core</h2><pre>")[1].split("</pre>")[0])
    assert pre == (FIX / "area_z130.txt").read_text(encoding="utf-8").rstrip("\n")
    assert "<h2>Build plan</h2>" in text and "Zone:Hospital" not in text and "Hospital (0/1)" in text
    assert "Crypt (20 graves) (50/20)" in text and "Trade depot (1/1)" in text
    assert "unchanged" not in capsys.readouterr().out
    assert main(["--config", str(c), "--mock", str(FIX), "dashboard", "--out", str(out), "--offline"]) == 0
    assert "unchanged" in capsys.readouterr().out                                       # same hash
    assert main(["--config", str(c), "--mock", str(FIX), "dashboard", "map", "x"]) == 2
    assert main(["--config", str(c), "--mock", str(FIX), "dashboard", "unmap", "Core"]) == 0


def test_sections_from_other_specs_and_hash(tmp_path):
    st, _ = history_store()
    st.set("bottleneck.line", "Bottleneck: Wood (0). Blocks: charcoal starter → coke")
    st.set("bottleneck.stock", {"wood": 0, "coke": 3, "coal": 16, "bars": {"IRON": 4}})
    st.set("caravan.state", {"phase": "waiting", "decision": "trade"})
    st.set("trade.boost", ["wood"])
    st.set("trade.boost_bottleneck", ["wood", "fuel"])
    st.set("forecast.series", [[1000.0 + d, 20, 100.0 - 8 * d, 300.0] for d in range(6)])
    st.log_action(T0 + 5, "mood", "mood", "release-cutgems", "jobs", "claude/pilot_mood release-cutgems --apply",
                  False, False, "")
    text = render(collect(st, T0 + 37 * 600))
    assert "Bottleneck: Wood (0)" in text and "Bars IRON" in text and "Buy first: wood, fuel" in text
    assert "Forecast: Food" in text and "(ERROR)" in text and validate_html(text) == []
    out = tmp_path / "x.html"
    assert write_if_changed(text, out, st) and not write_if_changed(text, out, st)
    assert write_if_changed(text + " ", out, st)
    assert len(BUILDPLAN) >= 10 and DEFAULTS["history_h"] == 6


def test_check_writes_dashboard(tmp_path, tools_dir):
    from dfpilot.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "check"]) == 0
    page = tools_dir / "out" / "dashboard.html"
    assert page.exists() and validate_html(page.read_text(encoding="utf-8")) == []


def test_locations_for_buildplan():
    """Live 01.10.: hospital/temple/tavern/guildhall are locations (abstract_building), not zones."""
    c = parse_locations("LIBRARY=1 TEMPLE=2 INN_TAVERN=2 HOSPITAL=3 GUILDHALL=11")
    assert c == {"Loc:LIBRARY": 1, "Loc:TEMPLE": 2, "Loc:INN_TAVERN": 2, "Loc:HOSPITAL": 3, "Loc:GUILDHALL": 11}
    st = Store()
    st.set("dashboard.buildings", {"counts": {**c, "Zone:Barracks": 1}, "ts": T0})
    text = render(collect(st, T0))
    for n in ("Hospital (3/1)", "Temple (2/1)", "Tavern (2/1)", "Guildhall (11/1)", "Barracks (1/1)"):
        assert n in text
    assert LOCATIONS_CMD.startswith('lua "') and "abstract_building_type" in LOCATIONS_CMD
