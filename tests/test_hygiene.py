"""Spec v3-07 item hygiene: hard rules (property tests in Python and through the Lua script), batch cap,
diagnosis 'zone too far' -> zone D, digest line, block measurement, loop protection, CLI. Fixtures are SYNTHETIC."""
import json
import random
import shutil
import subprocess
from pathlib import Path

import pytest

from df_llm_helper.client import MockClient, Result
from df_llm_helper.clock import FakeClock
from df_llm_helper.features import hygiene as hy
from df_llm_helper.store import Store

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "fixtures" / "v3" / "hygiene"
LUA = shutil.which("lua5.4") or shutil.which("lua")
TYPES = ["BOULDER", "CORPSE", "CORPSEPIECE", "REMAINS", "MEAT", "FISH", "PLANT", "THREAD", "CLOTH", "GOBLET",
         "FIGURINE", "WEAPON", "ARMOR", "BAR", "WOOD", "BLOCKS", "SKIN_TANNED", "FOOD", "EGG"]


def fx(name):
    return (FIX / name).read_text(encoding="utf-8")


def rand_items(rng, n):
    out = []
    for i in range(n):
        t = rng.choice(TYPES)
        out.append({"id": i + 1, "type": t, "x": 90 + rng.randint(0, 20), "y": 100 + rng.randint(0, 20),
                    "z": 128 + rng.randint(0, 3), "dwarf": rng.random() < 0.2, "bone": rng.random() < 0.2,
                    "rotten": rng.random() < 0.5, "forbid": rng.random() < 0.1, "dump": rng.random() < 0.05,
                    "reach": rng.random() < 0.9, "hidden": rng.random() < 0.05, "outside": rng.random() < 0.1})
    return out


# ------------------------------------------------------------------ hard rules (acceptance 2 + 3)
@pytest.mark.parametrize("seed", range(40))
def test_property_boulders_and_dwarf_corpses_never_marked(seed):
    rng = random.Random(seed)
    items = rand_items(rng, rng.randint(0, 1500))
    cfg = {**hy.DEFAULTS, "mark_types": rng.sample(TYPES + ["CORPSE"] * 3, 6),   # even a hostile config
           "exclude_types": [], "keep_goods": [], "mark_batch": rng.randint(1, 5000)}
    picked = hy.select_marks(items, cfg, pending=rng.randint(0, 200))
    assert len(picked) <= hy.HARD_CAP
    for it in picked:
        assert it["type"] != "BOULDER"
        assert not (it["type"] in ("CORPSE", "CORPSEPIECE", "REMAINS") and (it["dwarf"] or it["bone"]))
        assert it["type"] not in hy.HARD_NEVER
        assert not it["forbid"] and not it["dump"] and not it["hidden"]


def test_config_cannot_unlock_boulders_or_goods():
    cfg = {**hy.DEFAULTS, "mark_types": ["BOULDER", "GOBLET", "THREAD", "CORPSE"], "exclude_types": [], "keep_goods": []}
    assert hy.effective_types(cfg) == ["CORPSE"]
    assert hy.select_marks([{"type": "BOULDER"}] * 50, cfg) == []


def test_dwarf_corpse_not_marked_other_corpse_marked():
    cfg = dict(hy.DEFAULTS)
    items = [{"type": "CORPSE", "dwarf": True}, {"type": "CORPSE", "dwarf": False}, {"type": "CORPSEPIECE", "bone": True}]
    assert hy.select_marks(items, cfg) == [items[1]]


def test_batch_never_above_300_and_respects_pending():
    items = [{"type": "CORPSE"}] * 900
    assert len(hy.select_marks(items, {**hy.DEFAULTS, "mark_batch": 5000, "pending_max": 5000})) == 300
    assert len(hy.select_marks(items, hy.DEFAULTS, pending=250)) == 50
    assert hy.select_marks(items, hy.DEFAULTS, pending=300) == []


# ------------------------------------------------------------------ the Lua script through a DFHack mock
def run_lua(tmp_path, items, *args, buildings=None, jobs=0):
    ip = tmp_path / "items.json"
    ip.write_text(json.dumps(items), encoding="utf-8")
    env = {"MOCK_ITEMS": str(ip), "MOCK_DUMPJOBS": str(jobs), "PATH": "/usr/bin:/bin"}
    if buildings is not None:
        bp = tmp_path / "b.json"
        bp.write_text(json.dumps(buildings), encoding="utf-8")
        env["MOCK_BUILDINGS"] = str(bp)
    r = subprocess.run([LUA, str(FIX / "hygiene_mock.lua"), str(ROOT / "lua" / "pilot_hygiene.lua"), *args],
                       capture_output=True, text=True, timeout=30, env=env)
    assert r.returncode == 0, r.stderr
    lines = r.stdout.strip().splitlines()
    return json.loads(lines[0]), json.loads(lines[-1].removeprefix("STATE "))


def lua_items(rng, n):
    out = []
    for i, d in enumerate(rand_items(rng, n)):
        e = {k: d[k] for k in ("id", "type", "z", "bone", "rotten", "forbid", "hidden", "outside")}
        e["x"], e["y"] = 20 + i % 100, 20 + i // 100          # one item per tile (tile flags are per tile)
        e["reach"] = d["reach"]
        e["race"] = 572 if d["dwarf"] else 100
        out.append(e)
    return out


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
@pytest.mark.parametrize("seed", range(6))
def test_lua_property_never_marks_boulders_or_dwarves(tmp_path, seed):
    rng = random.Random(1000 + seed)
    items = lua_items(rng, 900)
    out, dumped = run_lua(tmp_path, items, "mark", "5000", "CORPSE,CORPSEPIECE,REMAINS,BOULDER,GOBLET,THREAD",
                          "--rotten", "--apply")
    assert out["marked"] <= 300 and len(dumped) == out["marked"]
    by = {i["id"]: i for i in items}
    for i in dumped:
        it = by[i]
        assert it["type"] not in hy.HARD_NEVER
        assert not (it["type"] in ("CORPSE", "CORPSEPIECE", "REMAINS") and (it["race"] == 572 or it["bone"]))
        assert not it["forbid"] and not it["hidden"]
    # Python mirror selects the same items (same order: world.items.all)
    mirror = hy.select_marks([{**it, "dwarf": it["race"] == 572} for it in items],
                             {**hy.DEFAULTS, "mark_batch": 5000, "pending_max": 5000,
                              "mark_types": ["CORPSE", "CORPSEPIECE", "REMAINS"]})
    assert [m["id"] for m in mirror] == dumped


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_dry_run_marks_nothing_and_status_is_read_only(tmp_path):
    items = [{"id": i, "type": "CORPSE", "x": 100, "y": 100 + i % 10, "z": 130} for i in range(1, 400)]
    out, dumped = run_lua(tmp_path, items, "mark", "300", "CORPSE", "--dry")
    assert out["marked"] == 0 and out["candidates"] == 300 and not dumped
    out, dumped = run_lua(tmp_path, items, "status", "0", "250")
    assert out["loose"] == 250 and out["next"] == 250 and out["done"] is False and not dumped
    out, _ = run_lua(tmp_path, items, "status", "250", "250")
    assert out["done"] is True and out["loose"] == 149


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_report_zones_and_jobs(tmp_path):
    out, _ = run_lua(tmp_path, [], "report", buildings=[
        {"id": 538, "x1": 130, "y1": 105, "x2": 132, "y2": 107, "z": 141},
        {"id": 495, "x1": 131, "y1": 106, "x2": 135, "y2": 110, "z": 141, "kind": "Stockpile"}], jobs=1)
    assert out["dump_jobs"] == 1
    assert out["dump_zones"][0]["id"] == 538 and out["dump_zones"][0]["under_stockpile"] is True


# ------------------------------------------------------------------ runner against MockClient
def client(clock, blocks, report, *, muell=None, mark=None, delay=0.0):
    m = MockClient(clock=clock)
    starts = {}
    for name in blocks:
        j = json.loads(fx(name))
        starts[j["start"]] = fx(name)

    def status(cmd):
        start = int(cmd.split()[2])
        txt = starts.get(start)
        if txt is None:
            return Result(ok=False, stdout="", stderr="unknown block", cmd=cmd)
        clock.sleep(delay)
        return Result.make(cmd, True, txt, elapsed_s=delay)
    m.prefix_handlers.append(("claude/pilot_hygiene status", status))
    m.set("claude/pilot_hygiene report", fx(report) if report else Result(ok=False, stdout="", cmd="r"))
    m.set("claude/gesund krypta", (ROOT / "fixtures" / "run5" / "gesund_krypta.txt").read_text(encoding="utf-8"))
    if muell:
        m.set("claude/muell status", fx(muell))
    m.prefix_handlers.append(("claude/pilot_hygiene mark", mark or (lambda c: json.dumps(
        {"ok": True, "applied": "--apply" in c, "marked": int(c.split()[2]) if "--apply" in c else 0,
         "candidates": int(c.split()[2]), "refused": {"boulder": 10000, "dwarf": 5, "bone": 3}}))))
    return m


@pytest.fixture
def clock():
    return FakeClock(1_790_840_000.0)


def test_j109_digest_line_and_no_zone_proposal(clock):
    """Acceptance 1 + 5: 900+ corpses, no zone -> proposal with location; digest line <= 140 chars."""
    m = client(clock, ["status_j109_block0.json", "status_j109_block1.json"], "report_no_zone.json")
    h = hy.Hygiene(m, Store(), clock)
    lines, meas, _ = h.status()
    assert meas.loose == 12549 and meas.by_type["BOULDER"] == 10000 and meas.blocks == 2
    assert lines[0].startswith("loose stacks 12.5k: boulders 10k (ok), corpses 1.2k (no dump zone)")
    assert len(lines[0]) <= 140
    assert any("cause 'no dump zone'" in ln and "zone D z130 x86..88,y112..114" in ln for ln in lines)
    assert any("Goblets 410" in ln and "never dump" in ln for ln in lines)
    out = h.cycle(apply=True)
    assert "No dump zone: nothing marked" in out[-1]
    assert not [c for c in m.calls if "mark" in c and "--apply" in c]


def test_490_marks_one_job_zone_too_far_suggests_zone_d(clock):
    """Acceptance 4."""
    m = client(clock, ["status_490_marked.json"], "report_far_zone.json")
    lines, meas, rep = hy.Hygiene(m, Store(), clock).status()
    assert meas.pending == 490 and meas.centroid() == (98, 108, 129)
    cause, sug = hy.diagnose(meas, rep, hy.DEFAULTS)
    assert cause == "zone too far" and "zone D" in sug
    assert any("cause 'zone too far'" in ln and "zone D" in ln for ln in lines)


def test_diagnosis_other_causes():
    m = hy.Measurement(pending=100, sums=[9800, 10800, 12900])
    base = {"dump_zones": [{"x1": 96, "y1": 106, "x2": 98, "y2": 108, "z": 129}], "dump_jobs": 0, "idle": 5,
            "citizens": 50}
    assert hy.diagnose(m, {**base, "dump_jobs": 10}, hy.DEFAULTS) is None          # 10 % works
    under = {**base, "dump_zones": [{**base["dump_zones"][0], "under_stockpile": True}]}
    assert hy.diagnose(m, under, hy.DEFAULTS)[0] == "zone under a stockpile"
    assert hy.diagnose(hy.Measurement(pending=100, unreachable=60, sums=[9800, 10800, 12900]), base,
                       hy.DEFAULTS)[0] == "path blocked"
    assert hy.diagnose(m, {**base, "idle": 0}, hy.DEFAULTS)[0] == "haulers busy"
    assert hy.diagnose(m, base, hy.DEFAULTS)[0] == "unclear"
    assert hy.diagnose(hy.Measurement(), {"dump_zones": []}, hy.DEFAULTS) is None


def test_cycle_marks_at_most_300_and_loop_protection(clock):
    """Acceptance 1: zone exists, 900 corpses -> 300 per cycle; logged; at most max_marks_per_hour cycles."""
    m = client(clock, ["status_j109_block0.json", "status_j109_block1.json"], "report_far_zone.json")
    st = Store()
    h = hy.Hygiene(m, st, clock, {"mark_batch": 1000})
    out = h.cycle(apply=True)
    cmd = [c for c in m.calls if c.startswith("claude/pilot_hygiene mark")][-1]
    assert cmd.split()[2] == "300" and "--apply" in cmd and "BOULDER" not in cmd and "autodump" not in cmd
    assert "Marked 300 items" in out[-1] and "boulder 10000" in out[-1]
    acts = st.actions()
    assert acts[-1]["rule"] == "hygiene" and acts[-1]["action"] == "mark" and acts[-1]["dry_run"] == 0
    h.cycle(apply=True)
    out3 = h.cycle(apply=True)
    assert "Loop protection" in out3[-1]
    clock.advance(3601)
    assert "Marked" in h.cycle(apply=True)[-1]


def test_cycle_waits_while_marks_pending(clock):
    m = client(clock, ["status_490_marked.json"], "report_far_zone.json")
    out = hy.Hygiene(m, Store(), clock).cycle(apply=True)
    assert "490 marks still pending" in out[-1]


def test_dry_cycle_sends_dry_command(clock):
    m = client(clock, ["status_j109_block0.json", "status_j109_block1.json"], "report_far_zone.json")
    out = hy.Hygiene(m, Store(), clock).cycle(apply=False)
    assert out[-1].startswith("[dry] would mark 300") and m.write_calls == []


def test_autodump_is_refused(clock):
    with pytest.raises(PermissionError):
        hy.Hygiene(MockClient(clock=clock), Store(), clock)._run("autodump")


def test_measurement_fast_and_block_size_adapts(clock):
    """Acceptance 5: total measurement <= 5 s; a slow block halves the block size for the next run."""
    m = client(clock, ["status_j109_block0.json", "status_j109_block1.json"], "report_no_zone.json", delay=0.4)
    st = Store()
    h = hy.Hygiene(m, st, clock)
    meas = h.measure()
    assert meas.elapsed_s <= 5.0 and meas.max_block_s <= 1.0 and st.get("hygiene.block") is None
    slow = client(clock, ["status_j109_block0.json", "status_j109_block1.json"], "report_no_zone.json", delay=1.5)
    hy.Hygiene(slow, st, clock).measure()
    assert st.get("hygiene.block") == 5000                           # two slow blocks: 20000 -> 10000 -> 5000


def test_fallback_to_muell_status(clock):
    m = client(clock, [], None, muell="muell_status_j109.json")
    lines, meas, _ = hy.Hygiene(m, Store(), clock).status()
    assert meas.by_type["BOULDER"] == 7808 and meas.loose == 9823
    assert any("fallback claude/muell status" in ln for ln in lines)


def test_growth_rate_in_digest(clock):
    st = Store()
    h = hy.Hygiene(client(clock, ["status_490_marked.json"], "report_far_zone.json"), st, clock)
    st.set("hygiene.history", [[clock.now().epoch - 3600, 11000]])
    assert h.status()[0][0].startswith("loose stacks 11.2k (+200/h)")


def test_digest_line_length_bound():
    m = hy.Measurement(loose=123456789, by_type={"BOULDER": 99999999, "GOBLET": 99999999, "THREAD": 99999999},
                       other_corpses=99999999)
    line = hy.digest_line(m, {"dump_zones": [{}], "dump_jobs": 99999999}, 123456789.0, hy.DEFAULTS)
    assert len(line) <= 140


def test_dwarf_corpses_vs_coffins(clock):
    h = hy.Hygiene(client(clock, [], None), Store(), clock)
    assert "14 coffins free" in h.crypt_lines(hy.Measurement(dwarf_corpses=5))[0]
    assert "ghost risk" in h.crypt_lines(hy.Measurement(dwarf_corpses=20))[0]


def test_check_hook_interval_and_warning(clock, cfg, tools_dir):
    from df_llm_helper.pilot import Pilot
    m = client(clock, ["status_j109_block0.json", "status_j109_block1.json"], "report_no_zone.json")
    p = Pilot(cfg, m, store=Store(), clock=clock)
    lines = hy.check_hook(p, None, False)
    assert lines[0].startswith("Hygiene: loose stacks 12.5k") and any("zone D" in ln for ln in lines)
    assert hy.check_hook(p, None, False) == []                      # interval (measure_every_s)
    assert not [c for c in m.calls if "--apply" in c]                # auto_mark off by default


def test_cli_status_with_fixture_client(clock, monkeypatch, capsys):
    import df_llm_helper.cli as cli
    from df_llm_helper.pilot import Pilot
    from df_llm_helper.config import load_config
    m = client(clock, ["status_490_marked.json"], "report_far_zone.json")
    monkeypatch.setattr(cli, "_pilot", lambda args: Pilot(load_config(overrides={}), m, store=Store(), clock=clock))
    assert cli.main(["hygiene", "zones"]) == 0
    out = capsys.readouterr().out
    assert "dump zone #538" in out and "proposal: zone D" in out
    assert cli.main(["hygiene", "mark"]) == 0
    assert "490 marks still pending" in capsys.readouterr().out
    assert not [c for c in m.calls if "--apply" in c]


def test_check_hook_failure_is_rate_limited(clock, cfg):
    from df_llm_helper.pilot import Pilot
    m = MockClient(clock=clock)
    p = Pilot(cfg, m, store=Store(), clock=clock)
    assert hy.check_hook(p, None, False)[0].startswith("Hygiene: measurement failed")
    assert hy.check_hook(p, None, False) == []
