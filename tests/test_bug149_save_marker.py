"""BUG-149 (live test i1, 2026-10-28): `supervise --saves` labelled every region2 save 'fort Wheelsblows'. A world save keeps
the site data of every fort dfllm adopted in that world (dfhack-entity-84 Wheelsblows, -90 Trussroads, ...), and
marker_of() took the first file in name order. Now the kernel writes the active fort into world data (`dfllm.active`) at
boot; marker_of() picks that fort's marker, and a folder of several forts without it is ambiguous: it matches any of its
forts and never names one by file order."""
import json
import os
from pathlib import Path

from dfpilot import supervise as sv

T0 = 1_791_600_000.0
WHEELS = ("region2-site84", 203409054, "Wheelsblows")
TRUSS = ("region2-site90", 200668472, "Trussroads")


def _put(p: Path, data: str, t: float) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(data, encoding="utf-8")
    os.utime(p, (t, t))


def _site(d: Path, eid: int, mk, t: float) -> None:
    m = {"v": 2, "adopted": mk[1], "save": mk[0], "fort": mk[2], "acceptance": 0, "baseline": 1, "boots": 3}
    _put(d / f"dfhack-entity-{eid}.dat", json.dumps([{"k": "autochop/config", "i": [1]}, {"k": "dfllm", "s": json.dumps(m)}],
                                                    indent="\t"), t)


def world_save(saves: Path, name: str, t: float, active=None) -> Path:
    d = saves / name
    _put(d / "unit-1.dat", "u" * 1000, t - 10)
    _site(d, 84, WHEELS, t - 5)
    _site(d, 90, TRUSS, t - 5)
    if active:
        _put(d / "dfhack-entity--30000.dat", json.dumps([{"k": sv.ACTIVE_KEY, "s": json.dumps(
            {"save": active[0], "fort": active[2]})}]), t - 5)
    _put(d / "world.sav", "w" * 20000, t)
    return d


def test_the_active_fort_wins_over_the_file_order(tmp_path):
    d = world_save(tmp_path, "autosave 2", T0, active=TRUSS)
    assert sv.marker_of(d) == list(TRUSS)                                 # main: Wheelsblows (entity 84 sorts first)
    e = sv.scan_saves(tmp_path, {}, T0 + 3600)[0]
    assert e["marker"] == list(TRUSS) and e["markers"] == [list(TRUSS)]
    assert sv.ident_of([e], "autosave 2") == list(TRUSS[:2])


def test_several_forts_without_the_active_key_name_none_of_them(tmp_path):
    d = world_save(tmp_path, "t1-trussroads", T0)
    mk = sv.marker_of(d)
    assert mk and mk[2] != "Wheelsblows" and mk[1] is None and "2 forts" in mk[2]
    e = sv.scan_saves(tmp_path, {}, T0 + 3600)[0]
    assert sorted(map(tuple, e["markers"])) == sorted([WHEELS, TRUSS])
    # the runtime key (the folder the kernel writes) says which fort it is; without it the fort is unknown
    assert sv.ident_of([e], "t1-trussroads", "region2-site90") == list(TRUSS[:2])
    assert sv.ident_of([e], "t1-trussroads") is None
    assert sv.same_fort(e, TRUSS) and sv.same_fort(e, WHEELS) and not sv.same_fort(e, ("region9", 5, "x"))


def test_the_restart_choice_does_not_call_trussroads_another_fort(tmp_path):
    world_save(tmp_path, "autosave 1", T0)
    saves = sv.scan_saves(tmp_path, {}, T0 + 3600)
    s, why = sv.pick_save(saves, T0 + 3600, active="autosave 1", since=None, ident=list(TRUSS[:2]))
    assert s is not None and s["name"] == "autosave 1", why               # main: "belongs to another fort"
    s, why = sv.pick_save(saves, T0 + 3600, active="autosave 1", since=None, ident=["region9", 5])
    assert s is None and "another fort" in why


def test_one_marker_stays_as_before(tmp_path):
    d = tmp_path / "solo"
    _put(d / "world.sav", "w", T0)
    _site(d, 110, ("region4", 1000, "Testfort"), T0)
    assert sv.marker_of(d) == ["region4", 1000, "Testfort"]
