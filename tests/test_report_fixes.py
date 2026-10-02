"""Regression tests for the report/knowledge/fair-play review against the live game (2026-10-02).

Each test pins one defect found while running the commands against the real fortress:
far-away hostiles counted as danger, mock runs polluting the live state, journal dates, shorten() on dates,
archive overwrite, exception typos, L08 false positive, tempo status, KB id search, noisy digest/wake/cost lines.
"""
from datetime import date, timedelta

import pytest

from conftest import FIX
from df_llm_helper.agents import cost_report
from df_llm_helper.brief import build_brief, load_scopes
from df_llm_helper.cli import main
from df_llm_helper.clock import FakeClock
from df_llm_helper.config import DEFAULTS, force_overrides, load_config, mock_overrides
from df_llm_helper.digest import DigestState, build_digest
from df_llm_helper.fairplay import ExceptionRegistry, FairPlayError
from df_llm_helper.journal import Journal, infer_first_day, is_chronicle_event
from df_llm_helper.kb import KB
from df_llm_helper.lint import lint_source
from df_llm_helper.memory import compact_file, restore, shorten
from df_llm_helper.rules import build_context
from df_llm_helper.store import Store
from df_llm_helper.wake import NOISE_TAGS
from helpers import ROOT, snap_for

TH = DEFAULTS["thresholds"]


# ---------------------------------------------------------------- danger: hostiles far away (caverns)
def test_far_hostiles_are_not_danger_but_unknown_distance_is():
    s = snap_for(enemies=3)
    s.alerts.enemies_near = 0                       # claude/config: feinde_nah = 0 (forgotten beasts in the caverns)
    assert not s.danger
    t, st = build_digest(s, DigestState(), th=TH)
    assert "Danger" not in t
    assert "3 hostiles on the map, none near" in t
    t2, _ = build_digest(s, st, th=TH, now_hhmm="10:00")
    assert "Hostiles far" not in t2                   # info is shown once, never as 'still open'
    s.alerts.enemies_near = None                      # distance unknown -> conservative
    assert s.danger
    s.alerts.enemies_near = 2
    assert s.danger


# ---------------------------------------------------------------- mock runs never touch the live state
def test_mock_overrides_isolate_state_and_explicit_config_wins(tmp_path):
    ov = mock_overrides()
    assert ov["paths"]["state_db"].endswith("state.db") and "mock" in ov["paths"]["state_db"]
    try:
        force_overrides(ov)
        cfg = load_config(tmp_path / "none.yaml")
        assert "mock" in str(cfg.path("state_db")) and "mock" in str(cfg.path("tools"))
    finally:
        force_overrides(None)
    cfg = load_config(tmp_path / "none.yaml")
    assert "mock" not in str(cfg.path("state_db"))
    # main() with an explicit --config does not force anything
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  state_db: {tmp_path / 's.db'}\n  tools: {tmp_path / 't'}\n  scopes: {tmp_path / 't'}\n",
                 encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "digest"]) == 0
    assert (tmp_path / "s.db").exists()


# ---------------------------------------------------------------- journal
def test_first_day_is_derived_from_day_changes():
    log = ("info 22:00:00 [A] x\ninfo 23:30:00 [A] x\ninfo 01:00:00 [A] x\ninfo 12:00:00 [A] x\n"
           "info 03:00:00 [A] x\ninfo 08:00:00 [A] x\n")
    assert infer_first_day(log, date(2026, 10, 2)) == date(2026, 10, 2) - timedelta(days=2)
    assert infer_first_day("info 10:00:00 [A] x\n", date(2026, 10, 2)) == date(2026, 10, 2)


def test_game_date_only_from_a_nearby_snapshot():
    st = Store()
    st.add_snapshot(1000.0, "g", {"date": "26. Felsite, Jahr 117"})
    j = Journal(st, {})
    assert j._game_date(1100.0) == "26. Felsite, Jahr 117"
    assert j._game_date(1000.0 + 86400) is None       # yesterday's event must not get today's game date


def test_combat_aftermath_and_animal_births_are_noise():
    for tag in ("NOT_STUNNED", "REGAIN_CONSCIOUSNESS", "UNIT_PROJECTILE_SLAM", "LOSE_EMOTION", "BIRTH_ANIMAL"):
        assert not is_chronicle_event("KRITISCH", tag) and not is_chronicle_event("info", tag), tag
        assert NOISE_TAGS.match(tag) or tag == "BIRTH_ANIMAL"
    assert is_chronicle_event("info", "BIRTH_CITIZEN") and is_chronicle_event("KRITISCH", "CITIZEN_DEATH")


def test_lessons_find_repeated_death_causes():
    st = Store()
    j = Journal(st, {})
    for i in range(3):
        j.add(100.0 + i * 5000, "Death", "CITIZEN_DEATH", f"Unit {i}, Miner has been found dead, dehydrated.",
              who=f"Unit {i}", outcome="has been found dead, dehydrated")
    j.add(900.0, "Death", "CITIZEN_DEATH", "Solo, Miner has been struck down.", who="Solo",
          outcome="has been struck down")
    ls = j.lessons()
    assert [x.key for x in ls] == ["Death died | dehydrated"] and ls[0].count == 3


# ---------------------------------------------------------------- memory / briefing
def test_shorten_keeps_dates_and_times_together():
    line = "- von bau, 01.10. 13:40: " + "Gasse 44 Kacheln gebaut, " * 12
    s = shorten(line, 110)
    assert s.startswith("- von bau, 01.10. 13:40") and len(s) > 30 and s.endswith("…")
    assert shorten(s) == s                                  # idempotent


def test_archive_is_never_overwritten_and_second_compaction_is_quiet(tmp_path):
    p = tmp_path / "trinken.md"
    text = "# Status\n" + "\n".join(f"- Zeile {i}. " + "x" * 120 for i in range(60)) + "\n## Durchlauf 1\n" \
        + "\n".join(f"- alt {i}. " + "y" * 120 for i in range(60)) + "\n## Durchlauf 2\n- neu\n"
    p.write_text(text, encoding="utf-8")
    orig = p.read_bytes()
    r1 = compact_file(p, stamp="20260101T000000")
    assert r1["changed"]
    r2 = compact_file(p, stamp="20260101T000000")           # same second, already compact
    assert not r2["changed"] and "archive" not in r2
    p.write_bytes(orig + b"\n## Durchlauf 3\n" + b"- z. " * 200 + b"\n")
    r3 = compact_file(p, stamp="20260101T000000")           # changed again, same stamp -> second archive
    arch = sorted((tmp_path / "archive").glob("trinken.*.md"))
    assert len(arch) == (2 if r3["changed"] else 1)
    assert arch[0].read_bytes() == orig                     # the first original survives
    assert restore(p).name == arch[-1].name


def test_memory_all_skips_rule_and_registry_files(tmp_path, capsys):
    sc = tmp_path / "scopes"
    sc.mkdir()
    big = "# X\n## Status\n" + "- a. " + "z" * 200 + "\n" + ("## Durchlauf 1\n- b. " + "q" * 400 + "\n") * 8
    for n in ("trinken.md", "handel-regeln.md", "REGISTRY.md", "inbox-bau.md"):
        (sc / n).write_text(big, encoding="utf-8")
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  scopes: {sc}\n  tools: {tmp_path}\n  state_db: {tmp_path / 's.db'}\n", encoding="utf-8")
    assert main(["--config", str(c), "memory", "compact", "all", "--dry-run"]) == 0
    out = capsys.readouterr().out
    assert "trinken.md" in out and "inbox-bau.md" in out
    assert "handel-regeln.md" not in out and "REGISTRY.md" not in out


def test_briefing_has_no_double_bullets():
    sd = load_scopes(ROOT / "data" / "scopes.yaml")
    s = snap_for()
    ctx, _ = (build_context(s, cfg=DEFAULTS), s)
    txt = build_brief("trinken", scopes_def=sd, ctx=ctx, snap=s, kb=None,
                      memory_text="# t\n## Offen\n- 1. Halle graben\n- 2. Still bauen\n", inbox_lines=["- von bau, 01.10. 13:40: x"],
                      th=TH)
    assert "- - " not in txt and "- 1. Halle graben" in txt


# ---------------------------------------------------------------- fair play
def test_exception_register_rejects_typos(tmp_path):
    reg = ExceptionRegistry(tmp_path / "e.jsonl")
    for bad in ("XX99", "fp08", "FP", "", "L"):
        with pytest.raises(FairPlayError):
            reg.add(bad, "r", "yes")
    with pytest.raises(FairPlayError):
        reg.add("FP08", "r", "yes", expires="tomorrow")
    with pytest.raises(FairPlayError):
        reg.add("FP08", "r", "yes", max_uses=0)
    reg.add("L31", "ok", "yes", max_uses=2, expires="2026-12-31")
    assert len(reg.entries) == 1


def test_l08_ignores_squad_order_target_but_still_catches_teleport():
    order = ("local o = df.squad_order_movest:new()\n"
             "o.pos.x, o.pos.y, o.pos.z = plan.target.x, plan.target.y, plan.target.z\n")
    assert lint_source(order) == []
    assert [f.rule for f in lint_source("local u = unit\nu.pos.x = 5\n")] == ["L08"]


# ---------------------------------------------------------------- tempo
def test_tempo_status_is_display_only_and_off_honours_dry_run(capsys):
    assert main(["--mock", str(FIX), "tempo", "status"]) == 0
    out = capsys.readouterr().out
    assert out.startswith("Time lapse:") and "Guard:" in out
    assert main(["--mock", str(FIX), "tempo", "off", "--dry-run"]) == 0
    assert capsys.readouterr().out.startswith("[dry]")


# ---------------------------------------------------------------- knowledge base
def test_kb_finds_entries_by_id_and_german_water_words():
    kb = KB.load_dir(ROOT / "data" / "kb", current_run=5, stale_before=4)
    assert kb.search("wasser_quelle", k=3)[0].entry.id == "wasser_quelle"
    assert "wasser_quelle" in [h.entry.id for h in kb.search("wasser", k=4)]


# ---------------------------------------------------------------- noise in reports
def test_hunger_line_is_not_repeated_when_the_list_only_shuffles():
    h1 = {i: 41000 + i for i in range(1, 9)}
    h2 = {i: 41000 + i for i in range(3, 11)}               # two dwarves out, two in: same size, same worst bucket
    t1, st = build_digest(snap_for(hunger=h1), DigestState(), th=TH)
    assert "Hunger" in t1
    t2, _ = build_digest(snap_for(hunger=h2), st, th=TH)
    assert t2.startswith("No change")


def test_no_change_line_cuts_at_label_boundary():
    s = snap_for(drink_days=10, food_days=10, enemies=2, caravan_state="AtDepot", moods=["1"], corpses=2,
                 stress_high=2, hunger={1: 45000}, thirst={2: 45000})
    s.alerts.enemies_near = 2
    _, st = build_digest(s, DigestState(), th=TH)
    t, _ = build_digest(s, st, th=TH)
    assert t.startswith("No change")
    inner = t[t.index("(") + 1:t.rindex(")")]
    labels = {a for a in inner.split("open: ", 1)[1].split(", ") if not a.startswith("+")}
    assert all(len(x) > 2 for x in labels)                  # no half label like 'm'


def test_cost_warnings_are_capped(tmp_path):
    import json
    paths = []
    for i in range(9):
        f = tmp_path / f"agent-a{i}.jsonl"
        lines = [{"type": "assistant", "requestId": f"r{k}", "timestamp": f"2026-10-01T10:{k % 60:02d}:00Z",
                  "message": {"usage": {"input_tokens": 1, "output_tokens": 1}, "content": [{"type": "text", "text": "x"}]}}
                 for k in range(70)]
        f.write_text("\n".join(json.dumps(x) for x in lines), encoding="utf-8")
        paths.append(f)
    rows, out = cost_report(paths, {"warn_calls": 60, "warn_output_k": 40})
    assert sum("stuck?" in ln for ln in out) == 5 and out[-1].startswith("(+4 more")


def test_standing_feature_lines_are_reported_once_per_two_hours():
    from types import SimpleNamespace

    from df_llm_helper.cli import HOOK_REPEAT_MIN, _fresh_hook_lines
    clock = FakeClock(1_790_840_000.0)
    p = SimpleNamespace(clock=clock, store=Store())
    a = ["Hygiene: loose stacks 13.8k: boulders 11.8k (ok)", "!! Dwarf corpses 122 > free coffins 14: ghost risk"]
    assert _fresh_hook_lines(p, "hygiene", a) == a
    b = ["Hygiene: loose stacks 13.9k: boulders 11.9k (ok)", "!! Dwarf corpses 133 > free coffins 14: ghost risk"]
    assert _fresh_hook_lines(p, "hygiene", b) == []                  # only numbers moved
    clock.advance(60 * 60)
    assert _fresh_hook_lines(p, "hygiene", b) == []
    assert _fresh_hook_lines(p, "hygiene", b + ["Picks 28/37: pickfix needed"]) == ["Picks 28/37: pickfix needed"]
    clock.advance((HOOK_REPEAT_MIN - 59) * 60)
    assert len(_fresh_hook_lines(p, "hygiene", b)) == 2              # reminder after the repeat interval
    assert _fresh_hook_lines(p, "hygiene", b, record=False) == []    # dry run reads, never writes
    assert _fresh_hook_lines(p, "reach", b) == b                     # memory is per feature


def test_lint_command_reads_windows_paths(tmp_path):
    from df_llm_helper.lint import lint_command
    f = tmp_path / "x.lua"
    f.write_text("dfhack.run_command('reveal')\n")
    for cmd in (f"lua -f {f}", f'lua -f "{f}"'):
        assert [x.rule for x in lint_command(cmd)] == ["L04"], cmd
