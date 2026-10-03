"""install-lua: copy the bundled Lua scripts into a DF folder, merge config.lua with the live values."""
import shutil
import subprocess

import pytest

from df_llm_helper.cli import main
from df_llm_helper.install_lua import apply_install, is_literal, merge_config, plan_install
from helpers import ROOT

LUAC = shutil.which("luac5.4")
LIVE = """--@ module = true
SURFACE_Z = 133                          -- live
FORT_X, FORT_Y, FORT_Z = 96, 96, 133
ZUFLUCHT = { rects = { {90, 90, 100, 100, 133} },
  probe = {96, 96, 133} }
NORMAL_FPS = 100
OLD_ONLY = { 1, 2 }
FORT_BOX = { x1 = FORT_X - 45 }
"""


def df_folder(tmp_path, live=LIVE):
    df = tmp_path / "DF"
    tgt = df / "hack" / "scripts" / "claude"
    tgt.mkdir(parents=True)
    (tgt / "config.lua").write_text(live, encoding="utf-8")
    (tgt / "stages.lua").write_text("-- my stages\n", encoding="utf-8")
    (tgt / "util.lua").write_text("-- old util\n", encoding="utf-8")
    return df, tgt


def test_is_literal():
    assert is_literal("A = { rects = { {1, 2, 3} }, probe = {1,2,3}, name = 'x' }")
    assert is_literal("A, B = nil, true")
    assert is_literal("A = { [3] = true, [4] = false }")
    assert not is_literal("A = { x1 = FORT_X - 45 }")
    assert not is_literal("A = reqscript('claude/util').home() .. '/x'")
    assert not is_literal("A = math.max(0, 3)")


def test_merge_keeps_live_literals_and_new_repo_keys():
    repo = (ROOT / "lua" / "claude" / "config.lua").read_text(encoding="utf-8")
    merged, notes = merge_config(repo, LIVE)
    assert "FORT_X, FORT_Y, FORT_Z = 96, 96, 133" in merged
    assert "probe = {96, 96, 133} }" in merged and "SURFACE_Z = 133" in merged
    assert "NORMAL_FPS = 100" in merged                                    # live tuning kept
    assert "PERIMETER_MINCOMP = 3000" in merged and "function in_sperr_box" in merged   # repo news
    assert "OLD_ONLY = { 1, 2 }" in merged and merged.index("OLD_ONLY") < merged.index("-- ---------------------------------------------------------------- DEFAULTS")
    assert "FORT_BOX = { x1 = FORT_X - 45 }" not in merged                  # computed live value: repo kept
    assert "new key PERIMETER_MINCOMP (repo default)" in notes


@pytest.mark.skipif(not LUAC, reason="luac5.4 missing")
def test_merged_windrings_config_compiles(tmp_path):
    repo = (ROOT / "lua" / "claude" / "config.lua").read_text(encoding="utf-8")
    live = (ROOT / "examples" / "windrings" / "config.lua").read_text(encoding="utf-8")
    merged, _ = merge_config(repo, live)
    f = tmp_path / "config.lua"
    f.write_text(merged, encoding="utf-8")
    assert subprocess.run([LUAC, "-p", str(f)], capture_output=True).returncode == 0
    assert "FORT_X, FORT_Y, FORT_Z = 96, 96, 133" in merged


def test_install_plan_and_apply(tmp_path):
    df, tgt = df_folder(tmp_path)
    plan = plan_install(ROOT, df)
    names = {d.name for _, d, _ in plan.copies}
    assert "util.lua" in names and "pilot_batch.lua" in names and "pilot_perimeter.lua" in names
    assert "config.lua" not in names and "stages.lua" not in names
    assert any("stages.lua: kept" in s for s in plan.skipped)
    assert not (tgt / "mil.lua").exists()                                  # plan writes nothing
    out = apply_install(plan, tmp_path / "bk")
    assert (tgt / "mil.lua").exists() and (tgt / "pilot_batch.lua").exists()
    assert (tgt / "stages.lua").read_text() == "-- my stages\n"
    assert "FORT_X, FORT_Y, FORT_Z = 96, 96, 133" in (tgt / "config.lua").read_text()
    bk = next((tmp_path / "bk").glob("lua-backup-*"))
    saved = {p.name for p in bk.rglob("*.lua")}
    assert {"util.lua", "config.lua"} <= saved and "mil.lua" not in saved
    assert "backup" in out[0]
    again = plan_install(ROOT, df)
    assert all(w == "same" for _, _, w in again.copies)                    # idempotent


def test_install_follows_script_paths(tmp_path):
    df, tgt = df_folder(tmp_path)
    extra = tmp_path / "myscripts"
    (extra / "claude").mkdir(parents=True)
    (df / "dfhack-config").mkdir()
    (df / "dfhack-config" / "script-paths.txt").write_text(f"# comment\n+{extra}\n", encoding="utf-8")
    plan = plan_install(ROOT, df)
    assert extra / "claude" in plan.targets and len(plan.targets) == 2


def test_install_cli(tmp_path, capsys):
    df, tgt = df_folder(tmp_path)
    assert main(["install-lua", "--df", str(df)]) == 0
    out = capsys.readouterr().out
    assert "plan only" in out and not (tgt / "mil.lua").exists()
    assert main(["install-lua", "--df", str(df), "--apply", "--backup", str(tmp_path / "bk")]) == 0
    assert (tgt / "mil.lua").exists()
    assert main(["install-lua", "--df", str(tmp_path / "nothing")]) == 2
    assert "not a Dwarf Fortress folder" in capsys.readouterr().err


def test_bug226_install_creates_the_runtime_folder_and_the_rules_template_once(tmp_path):
    df, _ = df_folder(tmp_path)
    plan = plan_install(ROOT, df)
    rules = df / "df-llm-helper-runtime" / "tools" / "scopes" / "handel-regeln.md"
    assert any(ln.startswith(f"Trade rules {rules}: new") for ln in plan.lines())
    apply_install(plan, tmp_path / "bk")
    assert rules.read_text(encoding="utf-8") == (ROOT / "data" / "trade" / "handel-regeln.md").read_text(encoding="utf-8")
    assert (df / "df-llm-helper-runtime" / "tools" / "out").is_dir()
    rules.write_text("my own rules", encoding="utf-8")
    plan = plan_install(ROOT, df)
    assert any("kept (existing rules file)" in ln for ln in plan.lines())
    apply_install(plan, tmp_path / "bk2")
    assert rules.read_text(encoding="utf-8") == "my own rules"
