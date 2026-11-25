"""BUG-868: the ladder shows a terrain block (heavy aquifer, water within 4 tiles) from the tool's own words and holds it four times as long as
another 'free 0'; `bp sites` logs its reason to cli.log."""
import json
import time

from dfpilot import leiter


def _log(tmp_path, ago_h, result):
    line = "\t".join([str(int(time.time() - ago_h * 3600)), "cli", "bp.sites", json.dumps({"tpl": "fortcore"}), result]) + "\n"
    (tmp_path / "cli.log").write_text(line, encoding="utf-8")


def test_terrain_block_holds_longer_and_names_the_reason(tmp_path):
    _log(tmp_path, 10, "ranked 0 free 0: no fortcore site: heavy aquifer at z120, water within 4 tiles")
    txt = leiter._state_blocked(tmp_path, {}, [], 0, "tpl:fortcore", 6)
    assert "no fortcore site: heavy aquifer" in txt, txt
    assert txt.startswith("bp sites fortcore:")


def test_a_plain_free_0_still_expires_after_the_window(tmp_path):
    _log(tmp_path, 10, "ranked 3 free 0: taken by y400s1")
    assert leiter._state_blocked(tmp_path, {}, [], 0, "tpl:fortcore", 6) == ""
    _log(tmp_path, 2, "ranked 3 free 0: taken by y400s1")
    assert "free 0" in leiter._state_blocked(tmp_path, {}, [], 0, "tpl:fortcore", 6)


def test_terrain_block_expires_after_four_windows(tmp_path):
    _log(tmp_path, 30, "ranked 0 free 0: no fortcore site: heavy aquifer")
    assert leiter._state_blocked(tmp_path, {}, [], 0, "tpl:fortcore", 6) == ""
