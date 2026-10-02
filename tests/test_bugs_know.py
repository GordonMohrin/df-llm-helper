"""Regression tests for the knowledge / agents / reports / fair-play bug reports (Bugs/BUG-300..330)."""
import json
import shutil
from pathlib import Path

import pytest

from df_llm_helper.cli import main
from df_llm_helper.fairplay import ExceptionRegistry, FairPlayError, parse_expires
from helpers import ROOT

FIX = ROOT / "fixtures" / "run5"


@pytest.fixture
def env(tmp_path):
    """Isolated config: own data copy, scopes, tools, state.db, register."""
    data = tmp_path / "data"
    shutil.copytree(ROOT / "data", data, ignore=shutil.ignore_patterns("state.db*", "*.local.jsonl"))
    (tmp_path / "tools" / "scopes").mkdir(parents=True)
    c = tmp_path / "cfg.yaml"
    c.write_text(f"paths:\n  tools: {tmp_path / 'tools'}\n  scopes: {tmp_path / 'tools' / 'scopes'}\n"
                 f"  state_db: {tmp_path / 's.db'}\n  data: {data}\n  exceptions: {data / 'exceptions.jsonl'}\n"
                 f"  gamelog: {FIX / 'logs' / 'gamelog_selected.txt'}\n", encoding="utf-8")
    return tmp_path, str(c)


def run(capsys, *args):
    rc = main([str(a) for a in args])
    o = capsys.readouterr()
    return rc, o.out, o.err


# ---------------------------------------------------------------- BUG-315 / 316 / 317: exception register
def test_bug315_add_prints_the_entry_just_written(env, capsys):
    tmp, c = env
    (tmp / "data" / "exceptions.local.jsonl").write_text(
        '{"ts": "2026-10-02T06:35:42Z", "action": "FP10", "objects": ["189175", "3738"], "reason": "local", '
        '"player_consent": "synthetic quote", "max_uses": 5}\n', encoding="utf-8")
    rc, out, _ = run(capsys, "--config", c, "exception", "add", "FP08", "--objects", "187405, 187429",
                     "--reason", "E18 picks", "--ja", "yes, do it")
    assert rc == 0 and "Exception registered: FP08 ['187405', '187429'] (in exceptions.jsonl)" in out
    rc, out, _ = run(capsys, "--config", c, "exception", "add", "L31", "--reason", "dig", "--ja", "yes")
    assert rc == 0 and out.startswith("Exception registered: L31 []")


@pytest.mark.parametrize("bad", ["2026-13-45", "2026-02-30", "30.09.2026", "tomorrow", "2026-1-1"])
def test_bug316_invalid_expires_refused(tmp_path, bad):
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    with pytest.raises(FairPlayError):
        reg.add("FP11", "r", "q", expires=bad)
    assert not (tmp_path / "ex.jsonl").exists()


def test_bug316_date_only_valid_through_end_of_day(tmp_path):
    p = tmp_path / "ex.jsonl"
    ExceptionRegistry(p).add("FP11", "r", "q", expires="2026-10-02")
    assert ExceptionRegistry(p, now_iso="2026-10-02T12:00:00Z").allows("FP11")
    assert ExceptionRegistry(p, now_iso="2026-10-02T23:59:59Z").allows("FP11")
    assert not ExceptionRegistry(p, now_iso="2026-10-03T00:00:00Z").allows("FP11")
    assert parse_expires("2026-10-02T10:00:00Z") < parse_expires("2026-10-02")


@pytest.mark.parametrize("rule", ["FP0", "L99", "FP14", "fp08", "FP08;rm", None, ""])
def test_bug316_unknown_rule_ids_refused(tmp_path, rule):
    with pytest.raises(FairPlayError):
        ExceptionRegistry(tmp_path / "ex.jsonl").add(rule, "r", "q")


def test_bug316_known_rule_ids_and_objects(tmp_path):
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    for r in ("FP01", "FP13", "L01", "L30", "L31"):
        assert reg.add(r, "r", "q").action == r
    with pytest.raises(FairPlayError):
        reg.add("FP13", "r", "q", objects=[" ", "a b", "ä"])
    with pytest.raises(FairPlayError):
        reg.add("FP13", "r", "q", max_uses=0)
    assert reg.add("FP13", "r", "q", objects=[" 12 ", "34"]).objects == ["12", "34"]


def test_bug317_bad_lines_are_register_errors_not_crashes(tmp_path, capsys):
    p = tmp_path / "ex.jsonl"
    p.write_text('{"action":"FP08","reason":"ok line","player_consent":"yes"}\n[1,2]\n"just a string"\n', encoding="utf-8")
    reg = ExceptionRegistry(p)
    assert [e.action for e in reg.entries] == ["FP08"]
    assert sum("not a JSON object" in e for e in reg.errors) == 2
    p.write_bytes(b'\xef\xbb\xbf{"action":"FP08","reason":"BOM line","player_consent":"yes"}\n'
                  b'{"action":"L31","reason":"objects as a string","player_consent":"yes","objects":"123"}\n')
    reg = ExceptionRegistry(p)
    assert [e.action for e in reg.entries] == ["FP08"]                   # the BOM line is read
    assert any("objects must be a list" in e for e in reg.errors) and not reg.allows("L31")
    p.write_text('{"action":"L31","reason":"text","player_consent":"yes","max_uses":"2"}\n', encoding="utf-8")
    reg = ExceptionRegistry(p)
    assert reg.find("L31") is None and any("max_uses" in e for e in reg.errors)   # fail closed, no TypeError


# ---------------------------------------------------------------- BUG-318 / 319 / 320: linter
from df_llm_helper.lint import lint_command, lint_paths, lint_source  # noqa: E402


def _rules(src):
    return sorted({f.rule for f in lint_source(src)})


@pytest.mark.parametrize("src,rule", [
    ('local c = "reveal hell"\ndfhack.run_command(c)\n', "L04"),
    ("local border = u\nborder.pos.x = 5\n", "L08"),
    ("u.pos = {x=1, y=2, z=3}\n", "L08"),
    ("local tt = dfhack.maps.getTileType(1,2,3)\n" + "\n" * 40 + "local x = other_table.hidden\n", "L10"),
    ("blk.tiletype[1][1] = 5\n", "L17"),
    ("weapon.mat_type = 0\n", "L21"),
    ("dfhack.run_command('tiletypes-command', 'p any')\n", "L17"),
    ("dfhack.run_command('liquids')\n", "L18"),
    ("dfhack.run_command('cleaners')\n", "L25"),
    ("dfhack.run_command('teleport', '-x', '1')\n", "L08"),
])
def test_bug318_indirect_forms_detected(src, rule):
    assert rule in _rules(src)


@pytest.mark.parametrize("src", [
    "local teleporting_label = 1\n", "local tiletypes = {}\n", "local liquids = {}\n", "local cleaners = {}\n",
    "local recorder = {}\nrecorder.count = 1\n", "job.mat_type = 0\n",
    "local f = df.job_item:new()\nf.item_type = 1\nf.mat_type = -1; f.mat_index = -1\n",
])
def test_bug319_identifiers_not_reported(src):
    assert _rules(src) == []


def test_bug319_bare_command_lines_still_checked():
    assert [f.rule for f in lint_command("teleport -x 1")] == ["L08"]
    assert [f.rule for f in lint_command("tiletypes-here")] == ["L17"]
    assert [f.rule for f in lint_command("liquids")] == ["L18"]


def test_bug320_missing_path_and_utf16_are_errors(tmp_path, capsys):
    fs = lint_paths([tmp_path / "nonexist.lua", tmp_path / "nonexist_dir"])
    assert [f.level for f in fs] == ["error", "error"]
    u16 = tmp_path / "u16.lua"
    u16.write_bytes('dfhack.run_command("dig-now")\r\n'.encode("utf-16"))
    assert [f.rule for f in lint_paths([u16])] == ["L02"]
    nobom = tmp_path / "nobom.lua"
    nobom.write_bytes('dfhack.run_command("dig-now")'.encode("utf-16-le"))
    assert [(f.rule, f.level) for f in lint_paths([nobom])] == [("IO", "error")]
    assert main(["lint", str(tmp_path / "typo.lua")]) == 1


# ---------------------------------------------------------------- BUG-300 / 301 / 321 / 325: runbooks
def test_bug300_show_lists_params_preconditions_rollback(capsys):
    rc, out, _ = run(capsys, "--mock", FIX, "runbook", "show", "rb01_e18_pick")
    assert rc == 0
    assert "Params:\n  squad_id (required: --param squad_id=<value>)" in out
    assert "Preconditions:\n  not danger" in out and "Rollback:\n 1. cmd: claude/mil workmode {squad_id} off --apply" in out
    assert "rb01c_e18_release" not in out                                 # BUG-321: no such runbook


def test_bug300_consent_runbook_can_be_previewed_not_run(capsys):
    rc, out, _ = run(capsys, "--mock", FIX, "runbook", "run", "rb01b_e18_foreign", "--dry-run", "--param", "item_ids=1,2")
    assert rc == 0 and "NOT approved" in out and "dry-run: nothing executed" in out
    rc, out, _ = run(capsys, "--mock", FIX, "runbook", "run", "rb01b_e18_foreign", "--param", "item_ids=1,2")
    assert rc == 1 and "refused" in out


def test_bug301_runbook_argument_errors(capsys):
    rc, _, err = run(capsys, "--mock", FIX, "runbook", "run", "rb21_flut", "--dry-run", "--param", "x")
    assert rc == 2 and "--param expects name=value, got 'x'" in err
    rc, _, err = run(capsys, "--mock", FIX, "runbook", "show")
    assert rc == 2 and "Runbook id missing" in err and "None" not in err
    rc, _, err = run(capsys, "--mock", FIX, "runbook", "show", "nope")
    assert rc == 2 and "Unknown runbook: 'nope'" in err


def test_bug321_no_stale_watcher_references(capsys):
    rc, out, _ = run(capsys, "--mock", FIX, "runbook", "show", "rb05_waechter_blind")
    assert "waechter --loop" in out and "Restart unpause-guard" not in out
    for kid in ("waechter_blind", "guard_start"):
        rc, out, _ = run(capsys, "--mock", FIX, "kb", "get", kid)
        assert "waechter --loop" in out
    assert "autopilot log" not in (ROOT / "docs" / "manual-v3" / "05-tools.md").read_text(encoding="utf-8")


def test_bug325_bom_yaml_and_bad_runbook_isolated(env, capsys):
    tmp, c = env
    rb = tmp / "data" / "runbooks"
    src = (rb / "rb09_aquifer.yaml").read_text(encoding="utf-8").replace("id: rb09_aquifer", "id: rb98_bom", 1)
    (rb / "rb98_bom.yaml").write_bytes(b"\xef\xbb\xbf" + src.encode("utf-8"))
    (rb / "rb99_broken.yaml").write_text("id: rb99\ntitle: x\n", encoding="utf-8")
    rc, out, err = run(capsys, "--config", c, "--mock", FIX, "runbook", "list")
    assert rc == 0 and "rb98_bom" in out and "rb01_e18_pick" in out
    assert "Runbook skipped: rb99_broken.yaml" in err
    sc = tmp / "data" / "scopes.yaml"
    sc.write_bytes(b"\xef\xbb\xbf" + sc.read_bytes())
    rc, out, _ = run(capsys, "--config", c, "--mock", FIX, "brief", "bau")
    assert rc == 0 and out.startswith("# Briefing bau")


# ---------------------------------------------------------------- BUG-301 / 302 / 303 / 308: CLI arguments and files
def test_bug301_kb_bus_dashboard_brief_arguments(env, capsys):
    tmp, c = env
    base = ["--config", c, "--mock", FIX]
    rc, _, err = run(capsys, *base, "kb", "get")
    assert rc == 2 and "Usage" in err
    rc, _, err = run(capsys, *base, "kb", "get", "nonexistent")
    assert rc == 2 and "'nonexistent'" in err
    rc, _, err = run(capsys, *base, "kb", "search", "pickaxe", "-k", "-1")
    assert rc == 2 and "-k must be >= 1" in err
    rc, _, err = run(capsys, *base, "kb", "import")
    assert rc == 2
    (tmp / "binary.md").write_bytes(bytes(range(256)) * 3)
    (tmp / "empty.md").write_text("", encoding="utf-8")
    rc, out, err = run(capsys, *base, "kb", "import", tmp / "binary.md", tmp / "empty.md")
    assert rc == 2 and "not a text file" in err and "nothing written" in out
    assert not list((tmp / "data" / "kb").glob("imported_*"))
    rc, _, err = run(capsys, *base, "bus", "post", "", "--from", "a", "--to", "b")
    assert rc == 2 and "empty" in err
    rc, _, err = run(capsys, *base, "bus", "post", "x", "--to", "bau")
    assert rc == 2 and "--from" in err
    rc, _, err = run(capsys, *base, "bus", "read", "--to", "bau", "--limit", "-1")
    assert rc == 2
    rc, _, err = run(capsys, *base, "dashboard", "unmap", "nonexistent")
    assert rc == 1 and "No map named 'nonexistent'" in err
    rc, _, err = run(capsys, *base, "dashboard", "unmap")
    assert rc == 2 and "Usage" in err
    for b in ("0", "-5"):
        rc, _, err = run(capsys, *base, "brief", "bau", "--budget", b)
        assert rc == 2 and "--budget must be a positive" in err


def test_bug302_missing_or_directory_inputs_no_traceback(env, capsys):
    tmp, c = env
    base = ["--config", c, "--mock", FIX]
    (tmp / "dir_as_file").mkdir()
    for args in (("kb", "import", tmp / "nonexist.md"), ("bus", "import", tmp / "nonexist.md"),
                 ("agents", "lint-report", tmp / "nonexist.txt"), ("agents", "lint-report", tmp / "dir_as_file"),
                 ("replay", tmp / "nonexist.jsonl"), ("journal", "ingest", "--events", tmp / "dir_as_file")):
        rc, out, err = run(capsys, *base, *args)
        assert rc in (1, 2) and "Traceback" not in out + err, args


@pytest.mark.parametrize("enc", ["utf-8", "utf-8-sig", "utf-16", "cp1252"])
def test_bug303_lint_report_encodings(env, capsys, enc):
    tmp, c = env
    rep = tmp / f"r_{enc}.txt"
    rep.write_bytes("Result: Fässer gefüllt\nMeasurements: 3 -> 9\nChanged: still\nOpen: -\nRisk: -\n".encode(enc))
    rc, out, _ = run(capsys, "--config", c, "agents", "lint-report", rep)
    assert rc == 0 and out.strip() == "ok"


def test_bug308_scope_names_validated(env, capsys):
    tmp, c = env
    victim = tmp / "victim.md"
    victim.write_text("# x\n" + "## Durchlauf 1\n" + "text line\n" * 400, encoding="utf-8")
    before = victim.read_bytes()
    for args in (("memory", "compact", "../victim"), ("memory", "restore", "../victim"),
                 ("memory", "compact", "nonscope")):
        rc, _, err = run(capsys, "--config", c, *args)
        assert rc == 2 and "unknown scope" in err
    assert victim.read_bytes() == before
    rep = tmp / "r.txt"
    rep.write_text("x\n" * 40, encoding="utf-8")
    rc, _, err = run(capsys, "--config", c, "agents", "lint-report", rep, "--scope", "x/../../../escape")
    assert rc == 2 and not list(tmp.rglob("escape.md"))


# ---------------------------------------------------------------- BUG-304 / 305 / 306 / 307 / 326: agents, memory, brief
from df_llm_helper import agents as AG  # noqa: E402
from df_llm_helper.memory import compact_file, memory_age_note, restore, shorten  # noqa: E402


def test_bug304_prompt_has_each_block_once_and_marks_long_task(env, capsys):
    tmp, c = env
    rc, out, _ = run(capsys, "--config", c, "--mock", FIX, "agents", "prompt", "trinken", "--task", "Check the barrels")
    heads = [ln for ln in out.splitlines() if ln.startswith("## ")]
    assert rc == 0 and len(heads) == len(set(heads))
    assert "## Report format (mandatory, <= 12 lines, otherwise truncated)" in heads and "## Report" not in heads
    assert "Report <= 10 lines" not in out and "claude/" in out.split("## Commands", 1)[1]   # scope commands kept
    long = "word " * 150
    rc, out, _ = run(capsys, "--config", c, "--mock", FIX, "agents", "prompt", "bau", "--task", long, "--force")
    assert "[task shortened: 400 of 749 characters]" in out


def test_bug305_table_and_warning_use_the_same_output():
    ac = AG.AgentCost("a", calls=75, output=429239, out_est=172448)
    assert ac.out_tokens == 429239
    rows_lines = AG.cost_report([], {})[1]
    assert rows_lines[0].split()[4] == "Out~"


def test_bug306_restore_dry_run_changes_nothing(env, capsys):
    tmp, c = env
    sc = tmp / "tools" / "scopes"
    shutil.copy(FIX / "scopes_sample" / "militaer.md", sc / "militaer.md")
    assert run(capsys, "--config", c, "memory", "compact", "militaer")[0] == 0
    compacted = (sc / "militaer.md").read_bytes()
    rc, out, _ = run(capsys, "--config", c, "memory", "restore", "militaer", "--dry-run")
    assert rc == 0 and "(dry-run)" in out and "would restore" in out
    assert (sc / "militaer.md").read_bytes() == compacted
    assert restore(sc / "militaer.md", dry_run=True) is not None


def test_bug307_cp1252_memory_keeps_umlauts_and_size_is_real(tmp_path):
    p = tmp_path / "essen.md"
    body = "# Kopf\n## Offen\n- Fässer prüfen\n" + "".join(
        f"## Durchlauf {i}\n" + "Zeile ä ö ü ß text, lang genug damit gekürzt wird und noch mehr\n" * 30 for i in range(6))
    p.write_bytes(body.replace("\n", "\r\n").encode("cp1252"))
    res = compact_file(p, stamp="20261002T000000")
    data = p.read_bytes()
    assert res["changed"] and res["after"] == len(data)
    text = data.decode("utf-8")
    assert "�" not in text and "Fässer prüfen" in text and "\r\n" in text and "\n" not in text.replace("\r\n", "")


def test_bug326_shorten_keeps_content_after_a_label_and_flags_old_memory():
    ln = ("2. Hauptthread: fps <= 50 oder Schrittbetrieb (`claude/advance N`); `claude/mil enemies`, `claude/mil status` "
          "(ALLE Bürger+Soldaten prüfen, nicht nur den Feind), Flags danach löschen.")
    s = shorten(ln, 160)
    assert s.startswith("2. Hauptthread: fps <= 50 oder Schrittbetrieb") and len(s) <= 161
    assert shorten("- Status: x " + "y" * 200, 110).startswith("- Status: x")
    assert memory_age_note("Durchlauf 6 (J102 Opal 7, Pop 36)", 118).startswith("Memory is old: newest game year named in it is 102")
    assert memory_age_note("Durchlauf 6 (J117 Opal 7)", 118) is None
    assert memory_age_note("no dates", 118) is None


def test_bug326_brief_shows_memory_age(env, capsys):
    tmp, c = env
    (tmp / "tools" / "scopes" / "essen.md").write_text("# Essen\n## Offen\n- Fässer prüfen\n## Durchlauf 6 (J90 Opal 7)\n- x\n",
                                                      encoding="utf-8")
    rc, out, _ = run(capsys, "--config", c, "--mock", FIX, "brief", "essen")
    assert rc == 0 and "## Memory age" in out and "named in it is 90" in out


# ---------------------------------------------------------------- BUG-309 / 310 / 311 / 330: journal
from datetime import date  # noqa: E402

from df_llm_helper.journal import Journal, classify_tag, is_chronicle_event  # noqa: E402
from df_llm_helper.store import Store  # noqa: E402


def _jcfg(tmp, extra=""):
    c = tmp / "j.yaml"
    c.write_text(f"paths:\n  tools: {tmp / 'tools'}\n  scopes: {tmp / 'tools' / 'scopes'}\n  state_db: {tmp / 's.db'}\n"
                 f"  gamelog: {tmp / 'g'}\njournal:\n  chronik: {tmp / 'chronik.md'}\n  metrics: {tmp / 'm.csv'}\n"
                 f"  postmortem: {tmp / 'pm.md'}\n{extra}", encoding="utf-8")
    return str(c)


def test_bug309_chronik_append_is_idempotent(tmp_path, capsys):
    (tmp_path / "tools" / "scopes").mkdir(parents=True)
    c = _jcfg(tmp_path)
    log = ROOT / "fixtures" / "run5_live" / "events_run3.log"
    assert main(["--config", c, "--mock", str(FIX), "journal", "ingest", "--events", str(log), "--date", "2026-09-30"]) == 0
    assert main(["--config", c, "--mock", str(FIX), "journal", "chronik", "--append"]) == 0
    first = (tmp_path / "chronik.md").read_text(encoding="utf-8")
    capsys.readouterr()
    assert main(["--config", c, "--mock", str(FIX), "journal", "chronik", "--append"]) == 0
    assert "nothing new" in capsys.readouterr().out
    assert (tmp_path / "chronik.md").read_text(encoding="utf-8") == first


@pytest.mark.parametrize("level,tag,chron,typ", [
    ("KRITISCH", "QUOTA_FILLED", False, None), ("KRITISCH", "DODGE_FLYING_OBJECT", False, None),
    ("KRITISCH", "FEATURE_DISCOVERY", True, "Info"), ("info", "NAMED_ARTIFACT", False, "Info"),
    ("KRITISCH", "CITIZEN_DEATH", True, "Death"), ("info", "ARTIFACT_BEGUN", True, "Mood"),
    ("info", "MERCHANTS_EMBARKED", True, "Caravan"), ("info", "D_MIGRANTS_ARRIVAL", True, "Population"),
    ("KRITISCH", "BUILDING_DESTROYED_OR_TOPPLED", True, "Emergency"), ("KRITISCH", "MEGABEAST_ARRIVAL", True, "Attack"),
])
def test_bug310_chronicle_classification(level, tag, chron, typ):
    assert is_chronicle_event(level, tag) is chron
    if typ:
        assert classify_tag(tag, level) == typ


def test_bug311_out_cannot_overwrite_project_files(tmp_path, capsys):
    (tmp_path / "tools" / "scopes").mkdir(parents=True)
    c = _jcfg(tmp_path)
    for target in ("data/exceptions.jsonl", "config.yaml", "df_llm_helper/cli.py", "../x.md"):
        with pytest.raises(SystemExit, match="refused"):
            main(["--config", c, "--mock", str(FIX), "journal", "postmortem", "--out", target])
    from df_llm_helper.config import RUNTIME
    out = RUNTIME / "test-bug311" / "pm.md"
    try:
        assert main(["--config", c, "--mock", str(FIX), "journal", "postmortem", "--out", str(out)]) == 0
        assert out.is_file()
    finally:
        shutil.rmtree(RUNTIME / "test-bug311", ignore_errors=True)


def test_bug330_ingest_utf16_garbage_and_bad_date(tmp_path, capsys):
    (tmp_path / "tools" / "scopes").mkdir(parents=True)
    c = _jcfg(tmp_path)
    lines = "KRITISCH 10:20:00 [CITIZEN_DEATH] Urist has been found dead, dehydrated.\ninfo 10:21:00 [X] y\n"
    (tmp_path / "u16.log").write_bytes(lines.encode("utf-16"))
    assert main(["--config", c, "--mock", str(FIX), "journal", "ingest", "--events", str(tmp_path / "u16.log"),
                 "--date", "2026-10-03"]) == 0
    assert capsys.readouterr().out.startswith("1 chronicle events in the log, 1 new")
    assert main(["--config", c, "--mock", str(FIX), "journal", "ingest", "--events", c, "--date", "2026-10-04"]) == 1
    assert "0 of" in capsys.readouterr().out
    for bad in ("30.09.2026", "2026-13-45"):
        assert main(["--config", c, "--mock", str(FIX), "journal", "ingest", "--events", str(tmp_path / "u16.log"),
                     "--date", bad]) == 2
        assert "YYYY-MM-DD" in capsys.readouterr().err


# ---------------------------------------------------------------- BUG-312 / 313 / 314 / 327: dashboard, guard, bus
def test_bug312_hash_per_file_and_directory_refused(env, capsys):
    tmp, c = env
    base = ["--config", c, "--mock", FIX, "dashboard", "--offline", "--out"]
    assert run(capsys, *base, tmp / "a.html")[0] == 0
    st = Store(str(tmp / "s.db"))
    st.set("dashboard.maps", {"Kaserne": "##\n.."})
    rc, out, _ = run(capsys, *base, tmp / "b.html")
    assert rc == 0 and "newly written" in out
    rc, out, _ = run(capsys, *base, tmp / "a.html")                     # a.html is stale: rewritten
    assert rc == 0 and "newly written" in out and "Map Kaserne" in (tmp / "a.html").read_text(encoding="utf-8")
    rc, out, _ = run(capsys, *base, tmp / "a.html")
    assert "unchanged" in out
    rc, _, err = run(capsys, *base, tmp)
    assert rc == 2 and "directory" in err


def test_bug313_crlf_map_is_single_spaced(env, capsys):
    from df_llm_helper.dashboard import render
    html = render({"maps": {"T": "z=130\r\n ##\r\n .."}}, {})
    assert "\r" not in html.split("<h2>Map T</h2>")[1]


def test_bug314_guard_warn_not_logged_as_warn_none(env, capsys):
    tmp, c = env
    assert run(capsys, "--config", c, "--mock", FIX, "check")[0] in (0, 1)
    st = Store(str(tmp / "s.db"))
    acts = [a["action"] for a in st.actions(200) if a["source"] == "guard"]
    assert not any("None" in a for a in acts)
    rc, out, _ = run(capsys, "--config", c, "--mock", FIX, "journal", "postmortem")
    assert "warn=None" not in out


def test_bug327_md_export_then_import_is_one_message(env, capsys):
    tmp, c = env
    assert run(capsys, "--config", c, "bus", "post", "Fässer knapp", "--from", "trinken", "--to", "bau", "--md",
               "--prio", "warn")[0] == 0
    rc, out, _ = run(capsys, "--config", c, "bus", "import")
    assert "inbox-bau.md: 0 new, 1 already present" in out
    rc, out, _ = run(capsys, "--config", c, "bus", "read", "--to", "bau")
    assert out.count("Fässer knapp") == 1


# ---------------------------------------------------------------- BUG-324 / 329: kb German words, selftest
@pytest.mark.parametrize("q,want", [("Händler hängt", "handel_ablauf"), ("Überschwemmung", "wasser_diagonal"),
                                    ("Grundwasser", "aquifer"), ("Küche", "kochschleife"), ("Flagge", "flags_stale"),
                                    ("Holzkohle", "koks_brennstoff"), ("Bestie", "bestie_megabestie"),
                                    ("Ruckeln", "timestream_sicherheit")])
def test_bug324_german_queries(q, want):
    from df_llm_helper.kb import KB
    kb = KB.load_dir(ROOT / "data" / "kb")
    assert want in [h.entry.id for h in kb.search(q, k=3)]


def test_bug329_selftest_checks_can_fail(monkeypatch):
    from df_llm_helper import selftest
    names = {n: (ok, info) for n, ok, info in selftest.quick_checks()}
    assert all(ok for ok, _ in names.values())
    assert any("with/without memory+inbox" in n for n in names)
    import df_llm_helper.runbooks as rbm
    monkeypatch.setattr(rbm, "diagnose", lambda rbs, ctx: [])
    names = {n: ok for n, ok, _ in selftest.quick_checks()}
    assert names["Diagnosis on fixtures"] is False
    with pytest.raises(SystemExit):
        selftest.main(["--quick", "--cov"])
