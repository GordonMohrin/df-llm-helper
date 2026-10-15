"""FR-62 in doctor: DFHack's `repeat` counter is a cross-check, not a cost owner; the kernel limit follows the fort
size (mirror of lua/dfllm/util/sched.lua); an overrun names its top owners; the k.* parts are owners."""
import re
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import doctor

ROOT = Path(__file__).resolve().parent.parent
HEADER = "wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods"


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def write_perf(save, rows):
    lines = [HEADER]
    wall, tick = 1791676800, 1_000_000
    for tps, units, items, ms_s, mods in rows:
        lines.append(f"{wall},{tick},PEACE,{tps},5,{units},{items},{ms_s},400,0,{mods}")
        wall, tick = wall + 30, tick + 30 * tps
    (save / "perf.csv").write_text("\n".join(lines) + "\n", encoding="utf-8")


def test_budget_mirrors_sched_lua():
    src = (ROOT / "lua" / "dfllm" / "util" / "sched.lua").read_text(encoding="utf-8")
    units = int(re.search(r"S\.LOAD = \{units = (\d+)", src).group(1))
    m = re.search(r"S\.BUDGET = \{ms_s = (\d+), per_unit = (\d+), max = (\d+)\}", src)
    assert (units, int(m.group(1)), int(m.group(2)), int(m.group(3))) == \
        (doctor.LOAD_UNITS, doctor.KERN_MS_S, doctor.BUDGET_PER_UNIT, doctor.BUDGET_MAX)
    assert doctor.budget_for(-1) == 25 and doctor.budget_for(150) == 25
    assert doctor.budget_for(402) == 35 and doctor.budget_for(5000) == 40


def test_repeat_is_a_cross_check_not_a_module(save):
    # the live Run 9 rows: `repeat` (DFHack's counter for the whole frame callback) next to the real owners
    mods = "seal=1110;sense=480;economy=390;kern=330;baseline=90;care=90;reflex=51;repeat=2085"
    write_perf(save, [(432, 402, 18700, 86, mods)] * 20)
    lines, bad = doctor.diagnose(save)
    text = "\n".join(lines)
    mline = next(x for x in lines if x.startswith("modules ms/s:"))
    assert "repeat" not in mline and mline.startswith("modules ms/s: seal 37.0 sense 16.0 economy 13.0 kern 11.0")
    assert "DFHack repeat counter 69.5 ms/s: the whole dfllm frame callback" in text
    assert "kernel 86 ms/s avg, 86 max (limit 35 for 402 units)" in text
    over = next(b for b in bad if b.startswith("kernel "))
    assert over == "kernel 86 ms/s > 35 (402 units): top seal 37, sense 16, economy 13"
    tps = next(b for b in bad if b.startswith("PEACE median"))
    assert tps == "PEACE median 432 ticks/s < 450 (kernel 8.6 % of real time, 402 units, 18700 items)"


def test_large_fort_within_its_budget_and_kernel_parts(save):
    mods = "sense=270;k.state=40;k.io=30;k.inbox=20;k.persist=10;seal=120;economy=90;reflex=51;kern=60"
    write_perf(save, [(455, 402, 18700, 29, mods)] * 20)
    lines, bad = doctor.diagnose(save)
    assert not any(b.startswith("kernel ") for b in bad), bad
    mline = next(x for x in lines if x.startswith("modules ms/s:"))
    assert "k.state 1.3" in mline and "k.io 1.0" in mline
    assert not any("DFHack repeat counter" in x for x in lines)


def test_small_fort_keeps_the_base_limit(save):
    write_perf(save, [(460, 120, 5000, 27, "sense=500;seal=310")] * 20)
    lines, bad = doctor.diagnose(save)
    assert any("(limit 25);" in x for x in lines)
    assert "kernel 27 ms/s > 25: top sense 17, seal 10" in bad
