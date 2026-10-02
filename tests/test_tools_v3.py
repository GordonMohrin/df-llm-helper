"""Spec v3-05 tool/pick manager (`python -m df_llm_helper tools`): acceptance criteria 1-5, FP08 gate, after-load, selection property.
All `claude/pilot_tools status` / `claude/pickfix --apply` responses are SYNTHETIC (fixtures/v3/tools, fixture gap)."""
import copy
import json
import random
import shutil
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.config import load_config
from df_llm_helper.fairplay import ExceptionRegistry
from df_llm_helper.features import tools as T
from df_llm_helper.lint import lint_file
from df_llm_helper.store import Store

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "fixtures" / "v3" / "tools"
PICKFIX = T.DEFAULTS["pickfix_cmd"]


def load(name):
    return json.loads((FIX / name).read_text(encoding="utf-8"))


class FakeFort:
    """Stateful stand-in for the game: work detail assign sets MINE, pickfix grants min(miners, picks) work picks."""

    def __init__(self, status, pickfix_effect=True):
        self.s = copy.deepcopy(status)
        self.pickfix_calls = 0
        self.effect = pickfix_effect

    def status(self, cmd):
        return json.dumps(self.s)

    def assign(self, cmd):
        uid = int(cmd.split()[2])
        for c in self.s["citizens"]:
            if c["id"] == uid:
                c["mine"], c["idle"] = True, False
        return json.dumps({"ok": True})

    def pickfix(self, cmd):
        self.pickfix_calls += 1
        if self.effect:
            miners = [c for c in self.s["citizens"] if c["mine"] and not c["child"]]
            ww = min(len(miners), self.s["picks_total"])
            for c in miners[:ww]:
                c["pick"] = True
            self.s["picks_free"] = self.s["picks_total"] - ww
            self.s["work_picks"] = ww
        out = dict(load("pickfix_apply.json"), work_weapons=self.s["work_picks"])
        return json.dumps(out)


def registry(tmp_path, reason="pick fix: per-unit pickup flag (uniform.pickup_flags.update)", objects=None):
    reg = ExceptionRegistry(tmp_path / "exceptions.jsonl")
    if reason is not None:
        reg.add("FP08", reason, "Ja, Pick-Fix mit Flag ist ok (player, 01.10.)", objects=objects)
    return reg


def manager(fort, tmp_path, *, reg="default", cfg=None, store=None, clock=None):
    clock = clock or FakeClock(1_790_000_000)
    if reg == "default":
        reg = registry(tmp_path)
    m = MockClient({T.STATUS_CMD: fort.status, PICKFIX: fort.pickfix}, registry=reg, clock=clock)
    m.prefix_handlers.append(("claude/workdetail assign ", fort.assign))
    return T.ToolsManager(m, store or Store(), clock, cfg or {}), m


def writes(m):
    return [c for c in m.write_calls]


# ---- acceptance 1 + 2: E18 scenario
def test_e18_adds_18_miners_then_pickfix_gives_34(tmp_path):
    fort = FakeFort(load("status_e18.json"))
    tm, m = manager(fort, tmp_path)
    lines, show = tm.run()
    assigns = [c for c in m.calls if c.startswith("claude/workdetail assign ")]
    assert len(assigns) == 18 and all(c.endswith(" Miners true") for c in assigns)
    assert fort.pickfix_calls == 1 and fort.s["work_picks"] == 34           # acceptance 1: work_weapons=34
    assert m.calls.index(PICKFIX) > m.calls.index(assigns[-1])             # miners first, then pick fix
    assert show and any("-> work picks 34" in ln for ln in lines)
    acts = tm.store.actions()
    assert len([a for a in acts if a["rule"] == "tools_miners"]) == 18
    pf = [a for a in acts if a["rule"] == "tools_pickfix"]
    assert len(pf) == 1 and "work picks 15 < min(miners 34, picks 34), 19 free" in pf[0]["detail"]
    assert "FP08" in pf[0]["detail"]
    assert all(a["detail"] for a in acts)                                   # every action has a reason
    assert len(tm.store.get("tools.added_miners")) == 18


def test_e18_selection_excludes_soldiers_children_patients_hungry(tmp_path):
    """Acceptance 2."""
    st = load("status_e18.json")
    plan = T.evaluate(T.obs_from_status(st), T.DEFAULTS)
    ids = {c["id"] for c in plan["add_miners"]}
    assert len(ids) == 18
    assert all(4000 <= i < 4022 for i in ids)        # only the eligible civilians
    # highest mining skill first (6, 5, ...), then id
    skills = [c["mining_skill"] for c in plan["add_miners"]]
    assert skills == sorted(skills, reverse=True)


def test_e18_summary_and_free_location():
    obs = T.obs_from_status(load("status_e18.json"))
    plan = T.evaluate(obs, T.DEFAULTS)
    assert T.summary(obs, plan) == "Picks 15/34: pickfix needed"
    assert T.free_line(obs) == "Free picks 19: BIN (82,99,128) x19"
    assert obs.miners == 16 and obs.without_pick == 1


def _rand_citizen(rng, i):
    return {"id": i, "idle": rng.random() < 0.7, "squad": rng.random() < 0.2, "child": rng.random() < 0.15,
            "cant_stand": rng.random() < 0.1, "job": rng.choice([None, None, "Rest", "Haul"]),
            "wounds": rng.choice([0, 0, 2]), "hospital": rng.choice([None, None, None, 900]),
            "hunger": rng.randint(0, 60000), "thirst": rng.randint(0, 60000), "mine": rng.random() < 0.3,
            "pick": False, "mining_skill": rng.randint(0, 15)}


def test_property_never_soldiers_children_patients_hospital_hungry():
    rng = random.Random(7)
    for _ in range(300):
        cits = [_rand_citizen(rng, 1000 + k) for k in range(rng.randint(0, 60))]
        st = {"ok": True, "picks_total": rng.randint(0, 60), "picks_free": rng.randint(0, 20), "work_picks": 0,
              "dig_jobs": rng.randint(0, 800), "diggers_now": 0, "citizens": cits}
        plan = T.evaluate(T.obs_from_status(st), T.DEFAULTS)
        assert len(plan["add_miners"]) <= T.DEFAULTS["max_new_miners"]
        for c in plan["add_miners"]:
            assert c["idle"] and not c["squad"] and not c["child"] and not c["cant_stand"]
            assert c["job"] != "Rest" and c["hospital"] is None and not c["mine"]
            assert c["hunger"] <= 30000 and c["thirst"] <= 30000


# ---- acceptance 3
def test_no_free_picks_no_call_forge_proposal(tmp_path):
    fort = FakeFort(load("status_no_free.json"))
    tm, m = manager(fort, tmp_path)
    lines, show = tm.run()
    assert fort.pickfix_calls == 0 and not writes(m)
    assert show and any("no free pick" in ln for ln in lines)
    assert any(ln.startswith("Proposal: Forge 5 pick(s)") for ln in lines)   # 16 miners + 4 reserve - 15


# ---- acceptance 4: idempotence
def test_balanced_no_action_and_digest_line(tmp_path):
    fort = FakeFort(load("status_balanced.json"))
    tm, m = manager(fort, tmp_path)
    lines, show = tm.run()
    assert not writes(m) and not show
    assert lines[0] == "Picks 34/34, miners 34, digging 29, open dig jobs 256"


def test_second_run_after_fix_is_noop(tmp_path):
    fort = FakeFort(load("status_e18.json"))
    tm, m = manager(fort, tmp_path)
    tm.run()
    n = len(writes(m))
    tm.clock.advance(60)
    tm.run()
    assert len(writes(m)) == n


def test_same_observation_waits_for_effect(tmp_path):
    fort = FakeFort(load("status_e18.json"), pickfix_effect=False)
    tm, m = manager(fort, tmp_path, cfg={"max_new_miners": 0})
    tm.run()
    tm.clock.advance(30)
    lines, _ = tm.run()
    assert fort.pickfix_calls == 1 and any("waiting for the effect" in ln for ln in lines)


# ---- acceptance 5: loop guard
def test_loop_guard_max_6_per_hour(tmp_path):
    fort = FakeFort(load("status_e18.json"), pickfix_effect=False)
    tm, m = manager(fort, tmp_path, cfg={"repeat_block_s": 0, "max_new_miners": 0})
    for _ in range(10):
        lines, _ = tm.run()
        tm.clock.advance(60)
    assert fort.pickfix_calls == 6 and any("loop guard" in ln for ln in lines)
    tm.clock.advance(3600)
    tm.run()
    assert fort.pickfix_calls == 7


def test_miner_guard_max_per_hour(tmp_path):
    st = load("status_e18.json")
    fort = FakeFort(st)
    tm, m = manager(fort, tmp_path, cfg={"max_new_miners": 5})
    tm.run()
    tm.run()
    assert len([c for c in m.calls if c.startswith("claude/workdetail")]) == 5


# ---- fair play FP08
@pytest.mark.parametrize("reason,objects", [(None, None), ("foreign flag of embark tools", None),
                                            ("pick fix", ["123456"])])
def test_pickfix_refused_without_fp08_pick_entry(tmp_path, reason, objects):
    fort = FakeFort(load("status_e18.json"))
    tm, m = manager(fort, tmp_path, reg=registry(tmp_path, reason, objects))
    lines, _ = tm.run()
    assert fort.pickfix_calls == 0
    assert any("pickfix refused" in ln and "FP08" in ln for ln in lines)
    assert any(w["key"] == "tools:fp08" for w in tm.store.take_warnings())


def test_pickfix_refused_without_registry(tmp_path):
    fort = FakeFort(load("status_e18.json"))
    tm, m = manager(fort, tmp_path, reg=None)
    tm.run()
    assert fort.pickfix_calls == 0


def test_fp08_max_uses_respected(tmp_path):
    reg = ExceptionRegistry(tmp_path / "e.jsonl")
    reg.add("FP08", "pick fix pickup flag", "ja", max_uses=1)
    assert T.fp08_entry(reg) is not None
    reg.consume("FP08")
    assert T.fp08_entry(reg) is None


# ---- dry run, after load, status
def test_dry_run_no_writes(tmp_path):
    fort = FakeFort(load("status_e18.json"))
    tm, m = manager(fort, tmp_path)
    lines, _ = tm.run(dry=True)
    assert not writes(m) and not tm.store.actions()
    assert any(ln.startswith(f"[dry] {PICKFIX}") for ln in lines)


def test_after_load_runs_pickfix_once(tmp_path):
    st = load("status_balanced.json")
    st["picks_total"], st["picks_free"] = 36, 2
    fort = FakeFort(st, pickfix_effect=False)
    tm, m = manager(fort, tmp_path)
    assert not tm.detect_loaded(5000) and not tm.detect_loaded(5100)
    assert tm.detect_loaded(4000)                          # report id dropped -> reloaded
    tm.run(after_load=True)
    tm.run()
    assert fort.pickfix_calls == 1
    assert "pick_after_load" in tm.store.actions()[-1]["detail"]


def test_check_hook_after_load_and_quiet_when_balanced(tmp_path):
    st = load("status_balanced.json")
    fort = FakeFort(st)
    tm, m = manager(fort, tmp_path)
    cfg = load_config(path=tmp_path / "none.yaml")
    pilot = SimpleNamespace(cfg=cfg, client=m, store=tm.store, clock=tm.clock)
    rep = SimpleNamespace(snapshot=SimpleNamespace(max_report_id=5000))
    assert T.check_hook(pilot, rep, False) == []
    st2 = copy.deepcopy(st)
    st2["picks_total"], st2["picks_free"] = 36, 2
    fort.s = st2
    rep.snapshot.max_report_id = 4000
    out = T.check_hook(pilot, rep, False)
    assert fort.pickfix_calls == 1 and any("pickfix ok" in ln for ln in out)


def test_status_lines(tmp_path):
    tm, _ = manager(FakeFort(load("status_e18.json")), tmp_path)
    out = tm.status()
    assert out[0] == "Picks 15/34: pickfix needed" and "BIN (82,99,128) x19" in out[1]
    tm2, _ = manager(FakeFort({"ok": False}), tmp_path)
    assert "not readable" in tm2.status()[0] and "not readable" in tm2.run()[0][0]


def test_config_defaults_and_cli_registration(capsys):
    cfg = load_config(path=Path("/nonexistent/x.yaml"))
    assert cfg.get("tools.reserve") == 4 and cfg.get("tools.workdetail") == "Miners"
    from df_llm_helper.cli import main
    with pytest.raises(SystemExit) as e:
        main(["tools", "--help"])
    assert e.value.code == 0 and "after-load" in capsys.readouterr().out


# ---- Lua
def test_pilot_tools_lua_lint_clean_and_parses():
    f = ROOT / "lua" / "pilot_tools.lua"
    assert lint_file(f) == []
    src = f.read_text(encoding="utf-8")
    assert "LIVE-UNTESTED" in src and "work_weapons =" not in src
    luac = shutil.which("luac5.4")
    if luac:
        assert subprocess.run([luac, "-p", str(f)], capture_output=True).returncode == 0


def test_local_register_file_is_merged(tmp_path):
    """A git-ignored exceptions.local.jsonl next to the register holds installation-specific consents (FP08)."""
    from df_llm_helper.fairplay import ExceptionRegistry
    from df_llm_helper.features.tools import fp08_entry
    main = tmp_path / "exceptions.jsonl"
    main.write_text('{"example": true, "action": "FP09", "reason": "x", "player_consent": "<q>"}\n', encoding="utf-8")
    assert fp08_entry(ExceptionRegistry(main)) is None
    (tmp_path / "exceptions.local.jsonl").write_text(
        '{"action": "FP08", "objects": [], "reason": "pick fix: pickup flag", "player_consent": "yes"}\n', encoding="utf-8")
    reg = ExceptionRegistry(main)
    assert fp08_entry(reg) is not None and reg.errors == []
