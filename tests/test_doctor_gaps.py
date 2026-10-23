"""BUG-070 in doctor: every frame gap > 3 s is attributed (a DF save, our module, unknown) from the perf.csv fields
`gap:<cause>` (ms) and `gapn:<cause>` (count); DF's own save freeze is not a kernel problem, ours and the unknown ones are.
Run 13 y483: 13 gaps > 3 s, max 172,094 ms, and the old doctor line only said "(autosave?)"."""
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import doctor

HEADER = "wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods"


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def write_rows(save, rows):
    lines, wall, tick = [HEADER], 1791676800, 1_000_000
    for gap_max, gaps3, mods in rows:
        lines.append(f"{wall},{tick},PEACE,460,5,150,3000,12,{gap_max},{gaps3},{mods}")
        wall, tick = wall + 30, tick + 30 * 460
    (Path(save) / "perf.csv").write_text("\n".join(lines) + "\n", encoding="utf-8")


def test_gaps_are_split_by_cause_and_df_saves_are_no_kernel_problem(save):
    write_rows(save, [(172094, 9, "sense=40;gap:save=210000;gapn:save=9"),
                      (6000, 3, "sense=40;gap:runner=4500;gapn:runner=1;gap:external=7000;gapn:external=2"),
                      (400, 0, "sense=40")])
    lines, bad = doctor.diagnose(save)
    text = "\n".join(lines)
    assert "frame gaps > 3 s by cause: save 9 (210 s)" in text and "runner 1 (4 s)" in text and "external 2 (7 s)" in text
    # the cause fields are no cost owners
    assert "gap:" not in next(x for x in lines if x.startswith("modules ms/s:"))
    assert "kernel module runner" in " ".join(bad) or any("runner" in b and "frame gap" in b for b in bad)
    gap_bad = [b for b in bad if "frame gap" in b]
    assert len(gap_bad) >= 1 and "ours" in gap_bad[0] and "unknown" in gap_bad[0], gap_bad
    assert not any(b.startswith("9 frame gap") for b in bad)           # DF's save gaps alone are not listed as a fault


def test_a_save_freeze_over_a_minute_is_named(save):
    write_rows(save, [(172094, 1, "gap:save=172094;gapn:save=1")])
    lines, bad = doctor.diagnose(save)
    assert any("DF save freeze 172 s" in b and "15 s" in b for b in bad), bad


def test_only_save_gaps_are_not_a_problem(save):
    write_rows(save, [(24000, 1, "gap:save=24000;gapn:save=1")])
    lines, bad = doctor.diagnose(save)
    assert not any("frame gap" in b for b in bad), bad
    assert any("save 1 (24 s)" in x for x in lines)


def test_rows_of_an_older_kernel_without_the_fields_stay_unattributed(save):
    write_rows(save, [(25000, 2, "sense=40")])
    lines, bad = doctor.diagnose(save)
    assert any("2 frame gap(s) > 3 s" in b and "unknown" in b for b in bad), bad
