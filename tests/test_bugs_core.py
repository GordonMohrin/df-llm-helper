"""Regression tests for the core bug reports Bugs/BUG-100 .. BUG-199 (fixtures from Bugs/evidence/)."""
from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

from df_llm_helper.cli import main
from df_llm_helper.clock import FakeClock
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from df_llm_helper.wake import wake_check

HERE = Path(__file__).resolve().parent
HOME = HERE.parent
FIX = HOME / "fixtures" / "run5"
EVID = HOME / "Bugs" / "evidence"


@pytest.fixture
def clk():
    return FakeClock(1_790_840_000.0)


def run(capsys, *args):
    rc = main([str(a) for a in args])
    o = capsys.readouterr()
    return rc, o.out, o.err


def mkcfg(tmp_path: Path, extra: str = "") -> Path:
    (tmp_path / "tools" / "scopes").mkdir(parents=True, exist_ok=True)
    c = tmp_path / "cfg.yaml"
    c.write_text(f"paths:\n  tools: '{tmp_path / 'tools'}'\n  scopes: '{tmp_path / 'tools' / 'scopes'}'\n"
                 f"  state_db: '{tmp_path / 'state.db'}'\n  gamelog: '{tmp_path / 'gamelog.txt'}'\n"
                 f"  exceptions: '{tmp_path / 'ex.jsonl'}'\n" + extra, encoding="utf-8")
    return c


# ---------------------------------------------------------------- BUG-100 wake blind after 5000 lines
@pytest.mark.parametrize("filler", [100, 6000])
def test_bug100_wake_sees_new_line_in_long_log(tmp_path, clk, filler):
    tools = ToolsDir(tmp_path, clk)
    tools.events_log.write_text("".join(f"info 10:00:00 [X] filler {i}\n" for i in range(filler)), encoding="utf-8")
    store = Store()
    assert wake_check(tools, store, clk) == []                 # baseline
    tools.append_event("CRITICAL", "A forgotten beast has come!", "FEATURE_BEAST")
    out = wake_check(tools, store, clk)
    assert out == ["WAKE critical [FEATURE_BEAST]: A forgotten beast has come! -> python -m df_llm_helper digest"]
    assert wake_check(tools, store, clk) == []


def test_bug100_wake_rotated_log_and_old_state(tmp_path, clk):
    tools = ToolsDir(tmp_path, clk)
    tools.events_log.write_text("info 10:00:00 [X] a\ninfo 10:00:01 [X] b\n", encoding="utf-8")
    store = Store()
    store.set("wake.state", {"initialized": True, "events_n": 1, "seen": {}})   # state of the old version
    tools.append_event("CRITICAL", "Ambush!", "AMBUSH_SNATCHER")
    assert len(wake_check(tools, store, clk)) == 1                              # only the line after line 1+1
    tools.events_log.write_text("CRITICAL 11:00:00 [CITIZEN_DEATH] Urist died.\n", encoding="utf-8")   # rotated
    assert wake_check(tools, store, clk) == [
        "WAKE critical [CITIZEN_DEATH]: Urist died. -> python -m df_llm_helper digest"]
    with tools.events_log.open("a", encoding="utf-8") as f:
        f.write("CRITICAL 11:00:01 [GUARD] half")                               # line still being written
    assert wake_check(tools, store, clk) == []
    with tools.events_log.open("a", encoding="utf-8") as f:
        f.write(" line\n")
    assert wake_check(tools, store, clk) == ["WAKE critical [GUARD]: half line -> python -m df_llm_helper digest"]


# ---------------------------------------------------------------- BUG-116 wake noise tags + mojibake
def test_bug116_wake_noise_tags_and_mojibake(tmp_path, clk):
    tools = ToolsDir(tmp_path, clk)
    tools.events_log.write_text("info 10:00:00 [X] start\n", encoding="utf-8")
    store = Store()
    wake_check(tools, store, clk)
    sample = (EVID / "BUG-116" / "sample_events_from_live_log.txt").read_text(encoding="utf-8")
    with tools.events_log.open("a", encoding="utf-8") as f:
        f.write(sample if sample.endswith("\n") else sample + "\n")
    out = wake_check(tools, store, clk)
    assert len(out) == 2 and all("[CITIZEN_DEATH]" in x for x in out)     # only the two deaths wake
    assert "\u00eeton Uristelbel" in out[0] and "Reg Sefolfikod" in out[1]   # mojibake repaired
    assert not any(t in "".join(out) for t in ("VOMIT", "RESOLVE_SHARED", "DODGE_FLYING", "NO_BREAK_GRIP",
                                                 "MASTERPIECE", "├"))


# ---------------------------------------------------------------- BUG-112 output encoding / wake loses events
def test_bug112_wake_state_kept_when_printing_fails(tmp_path, clk):
    tools = ToolsDir(tmp_path, clk)
    tools.events_log.write_text("info 10:00:00 [X] start\n", encoding="utf-8")
    store = Store()
    wake_check(tools, store, clk)
    tools.append_event("CRITICAL", "Mebzuth has been found dead ☼", "CITIZEN_DEATH")

    def bad(_line):
        raise UnicodeEncodeError("charmap", "☼", 0, 1, "x")
    with pytest.raises(UnicodeEncodeError):
        wake_check(tools, store, clk, sink=bad)
    got = []
    wake_check(tools, store, clk, sink=got.append)
    assert len(got) == 1 and "Mebzuth" in got[0]


def test_bug112_cli_output_survives_cp1252_stdout(tmp_path):
    import os
    import subprocess
    import sys
    c = mkcfg(tmp_path)
    env = {k: v for k, v in os.environ.items() if k not in ("PYTHONUTF8", "PYTHONIOENCODING")}
    env["PYTHONIOENCODING"] = "cp1252"
    p = subprocess.run([sys.executable, "-m", "df_llm_helper", "--config", str(c), "--mock", str(FIX), "overlay",
                        "Test ☼ ok"], cwd=str(HOME), env=env, capture_output=True)
    assert p.returncode == 0, p.stderr
    assert "Test ☼ ok" in p.stdout.decode("utf-8")


# ---------------------------------------------------------------- BUG-103 explicit --config must exist
def test_bug103_missing_or_directory_config_is_an_error(tmp_path, capsys):
    rc, out, err = run(capsys, "--config", tmp_path / "tpyo-config.yaml", "digest")
    assert rc == 2 and "config file not found" in err and "Traceback" not in err
    rc, out, err = run(capsys, "--config", tmp_path, "digest")
    assert rc == 2 and "directory" in err
    rc, out, err = run(capsys, "--config", mkcfg(tmp_path), "--mock", tmp_path / "nope", "digest")
    assert rc == 2 and "fixture folder not found" in err                # BUG-120 D


# ---------------------------------------------------------------- BUG-104 mock isolation also with --config
def test_bug104_mock_isolated_even_with_explicit_config(tmp_path, monkeypatch, capsys):
    from df_llm_helper import config as C
    monkeypatch.setattr(C, "RUNTIME", tmp_path / "rt")
    live_tools = C.DEFAULTS["paths"]["tools"]
    c = tmp_path / "live-copy.yaml"                                      # same paths as the live installation
    c.write_text(f"paths:\n  tools: '{live_tools}'\n", encoding="utf-8")
    ov = C.mock_overrides(c)
    assert ov["paths"]["tools"].startswith(str(tmp_path / "rt" / "mock"))
    assert ov["paths"]["state_db"].startswith(str(tmp_path / "rt" / "mock"))     # default state.db = live one
    own = mkcfg(tmp_path / "own")                                        # own private paths are kept
    ov2 = C.mock_overrides(own)
    assert "tools" not in ov2["paths"] and "state_db" not in ov2["paths"]
    rc, _, _ = run(capsys, "--config", c, "--mock", FIX, "digest")
    assert rc == 0 and (tmp_path / "rt" / "mock" / "state.db").exists()


# ---------------------------------------------------------------- BUG-113 tracebacks -> one-line errors
def test_bug113_io_and_input_errors_are_one_line(tmp_path, capsys):
    cfg = mkcfg(tmp_path)
    base = ["--config", cfg]
    (tmp_path / "empty.jsonl").write_text("", encoding="utf-8")
    (tmp_path / "list.json").write_text("[1, 2]", encoding="utf-8")
    (tmp_path / "noflds.json").write_text('{"own": [{"id": "a"}]}', encoding="utf-8")
    (tmp_path / "price.json").write_text('{"own": [{"id": "a", "name": "x", "category": "other", "price": 3}]}',
                                         encoding="utf-8")
    afile = tmp_path / "afile"
    afile.write_text("x", encoding="utf-8")
    cases = [
        (["replay", tmp_path / "nope.jsonl"], "not found"),
        (["replay", tmp_path], "directory"),
        (["plan", "blueprint", tmp_path / "nope.csv"], "not found"),
        (["plan", "trade"], "needs --json"),
        (["plan", "trade", "--json", tmp_path / "nope.json"], "not found"),
        (["plan", "trade", "--json", tmp_path / "list.json"], "top level"),
        (["plan", "trade", "--json", tmp_path / "noflds.json"], "missing field"),
        (["plan", "trade", "--json", tmp_path / "price.json"], "unknown field"),
        (["plan", "dig", "--area-file", tmp_path / "nope.txt", "--targets", "1,2"], "not found"),
        (["metrics", "--out", tmp_path / "no" / "dir" / "m.csv"], "not found"),
        (["metrics", "--out", tmp_path], "directory"),
        (["guard", "--loop", "--interval", "x"], None),                 # argparse rejects before any work
    ]
    for args, msg in cases:
        try:
            rc, out, err = run(capsys, *base, *args)
        except SystemExit as e:                                         # argparse usage error (exit 2)
            assert e.code == 2 and msg is None
            capsys.readouterr()
            continue
        assert rc == 2, (args, rc, out, err)
        assert "Traceback" not in err and err.startswith("Error: ") and msg in err, (args, err)
        assert len(err.strip().splitlines()) == 1
    rc, out, err = run(capsys, *base, "replay", tmp_path / "empty.jsonl")
    assert rc == 1 and "FAIL" in out and "no steps" in out
    # heartbeat with the tools path being a file
    hb = tmp_path / "hb.yaml"
    hb.write_text(f"paths:\n  tools: '{afile / 'sub'}'\n", encoding="utf-8")
    rc, out, err = run(capsys, "--config", hb, "heartbeat")
    assert rc == 2 and err.startswith("Error: ") and "Traceback" not in err


@pytest.mark.parametrize("extra,word", [("guard: 5\n", "mapping"), ("thresholds:\n  drink_days_crit: abc\n", "number")])
def test_bug113_config_wrong_types(tmp_path, capsys, extra, word):
    rc, out, err = run(capsys, "--config", mkcfg(tmp_path, extra), "--mock", FIX, "digest")
    assert rc == 2 and word in err and "Traceback" not in err


# ---------------------------------------------------------------- BUG-114 argument validation
def test_bug114_enable_and_ack_gate_validate(tmp_path, capsys):
    base = ["--config", mkcfg(tmp_path), "--mock", FIX]
    assert run(capsys, *base, "autopilot", "enable")[0] == 2
    rc, _, err = run(capsys, *base, "autopilot", "enable", "no_such_rule")
    assert rc == 2 and "unknown rule" in err
    for g in ([], ["-5"], ["61"]):
        rc, _, err = run(capsys, *base, "guard", "ack-gate", *g)
        assert rc == 2 and "gate" in err
    assert run(capsys, *base, "guard", "ack-gate", "60")[0] == 0
    st = Store(str(tmp_path / "state.db"))
    assert st.get("guard.state")["gates_acked"] == [60]
    assert st.db.execute("SELECT COUNT(*) FROM rule_state WHERE rule IS NULL OR rule='no_such_rule'").fetchone()[0] == 0
    rid = run(capsys, *base, "autopilot", "rules")[1].split(" ", 1)[0]
    assert run(capsys, *base, "autopilot", "enable", rid)[0] == 0


def test_bug114_plan_argument_validation(tmp_path, capsys):
    base = ["--config", mkcfg(tmp_path), "--mock", FIX]
    for args, msg in [(["plan", "armor", "--bars", "iron"], "name=number"),
                      (["plan", "armor", "--bars", "iron=-3"], "negative"),
                      (["plan", "armor", "--bars", "iron=x"], "not a number"),
                      (["plan", "supply", "--prod", "bogus=5"], "unknown resource"),
                      (["plan", "supply", "--growth", "-1"], "negative"),
                      (["plan", "dig", "--area-file", FIX / "area_z130.txt"], "--targets"),
                      (["plan", "dig", "--targets", "1,2"], "--area"),
                      (["plan", "dig", "--area-file", FIX / "area_z130.txt", "--targets", "1,2", "--picks", "0"], "at least 1"),
                      (["plan", "blueprint"], "at least one")]:
        rc, out, err = run(capsys, *base, *args)
        assert rc == 2 and msg in err, (args, err)


# ---------------------------------------------------------------- BUG-106 fail closed when the game is unreadable
def test_bug106_unreadable_game_blocks_tempo_and_planners(tmp_path, capsys):
    empty = tmp_path / "emptymock"
    empty.mkdir()
    base = ["--config", mkcfg(tmp_path), "--mock", empty]
    assert run(capsys, *base, "heartbeat")[0] == 0
    rc, out, _ = run(capsys, *base, "tempo", "status")
    assert "no_data" in out and "would be allowed" not in out and "pause state unknown" in out
    rc, out, _ = run(capsys, *base, "tempo", "on", "--dry-run")
    assert rc == 1 and "no_data" in out
    rc, out, _ = run(capsys, *base, "guard", "--dry-run")
    assert "time lapse allowed: False" in out and "no_data" in out
    for kind in ("armor", "supply"):
        rc, out, err = run(capsys, *base, "plan", kind)
        assert rc == 1 and "no data" in err and "stock 0" not in out


def test_bug106_waechter_unreadable_is_an_error_and_not_alive(tmp_path, clk):
    from df_llm_helper.client import MockClient
    from df_llm_helper.config import load_config
    from df_llm_helper.waechter import Waechter
    tools = ToolsDir(tmp_path / "tools", clk)
    w = Waechter(MockClient({}, clock=clk), tools, clk, Store(), load_config(tmp_path / "none.yaml").data)
    with pytest.raises(RuntimeError, match="cannot read reports"):
        w.step()
    assert not (tmp_path / "tools" / "out" / "waechter.alive").exists()


# ---------------------------------------------------------------- BUG-107 plan armor: miners, worn weapons, full sets
def test_bug107_plan_armor_uses_mil_tabelle(tmp_path, capsys):
    fx = tmp_path / "fx"
    shutil.copytree(FIX, fx)
    (fx / "mil_tabelle.txt").write_text((EVID / "BUG-107" / "live_mil_tabelle_raw.txt").read_text(encoding="utf-8"),
                                        encoding="utf-8")
    rc, out, err = run(capsys, "--config", mkcfg(tmp_path), "--mock", fx, "plan", "armor", "--bars", "iron=32,bronze=31")
    assert rc == 0, err
    assert "now 21" in out                                          # 27 squad members - 6 pick carriers
    assert "6 pick carriers" in out and "UPPER BOUND" in out
    # 5 Schuetzen with 9/9 and the axe/crossbow carriers need no weapon: 21 - 15 armed = 6 weapons at most
    assert "27x" not in out and "21x weapon" not in out


# ---------------------------------------------------------------- BUG-108 plan supply explains the food number
def test_bug108_plan_supply_names_composition(tmp_path, capsys):
    rc, out, _ = run(capsys, "--config", mkcfg(tmp_path), "--mock", FIX, "plan", "supply")
    assert rc == 0 and "meals" in out and "raw plants" in out and "food_days" in out


# ---------------------------------------------------------------- BUG-110 plan blueprint map bounds
def test_bug110_blueprint_map_size_option(tmp_path, capsys):
    bad = HOME / "tests" / "blueprints_bad" / "bad_footprint_outside_map.csv"
    rc, out, _ = run(capsys, "--config", mkcfg(tmp_path), "plan", "blueprint", bad)
    assert rc == 0 and "E_BOUNDS) not checked" in out
    rc, out, _ = run(capsys, "--config", mkcfg(tmp_path), "plan", "blueprint", bad, "--map-size", "192x192")
    assert rc == 1 and "E_BOUNDS" in out


# ---------------------------------------------------------------- BUG-123 plan trade priorities + names
def test_bug123_trade_priorities_and_skipped_names(tmp_path, capsys):
    d = json.loads((EVID / "BUG-123" / "working_example_trade.json").read_text(encoding="utf-8"))
    f = tmp_path / "t.json"
    f.write_text(json.dumps(d), encoding="utf-8")
    rc, out, _ = run(capsys, "--config", mkcfg(tmp_path), "plan", "trade", "--json", f)
    assert rc == 0 and "not bought: Gem (gem)" in out
    d["priorities"] = ["gem", "food"]
    f.write_text(json.dumps(d), encoding="utf-8")
    rc, out, _ = run(capsys, "--config", mkcfg(tmp_path), "plan", "trade", "--json", f)
    assert rc == 0 and "x Gem (gem)" in out


# ---------------------------------------------------------------- BUG-124 loop output is flushed
def test_bug124_guard_loop_flushes(tmp_path):
    import os
    import subprocess
    import sys
    import time
    c = mkcfg(tmp_path)
    p = subprocess.Popen([sys.executable, "-m", "df_llm_helper", "--config", str(c), "--mock", str(FIX), "guard",
                          "--loop", "--interval", "0.2", "--dry-run"], cwd=str(HOME), stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, env={**os.environ, "PYTHONUNBUFFERED": ""})
    try:
        os.set_blocking(p.stdout.fileno(), False)
        got = b""
        t0 = time.time()
        while time.time() - t0 < 15 and b"Target fps" not in got:
            time.sleep(0.1)
            got += p.stdout.read() or b""
    finally:
        p.kill()
        p.wait()
    assert b"Target fps" in got
