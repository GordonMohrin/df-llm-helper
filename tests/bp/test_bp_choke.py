"""Audit findings say what to build where (Run 10: `bypass: edge->Z3/Z4 avoids the trap hall (reaches 139,128,117)`
and `refuge: on the attack path` named no fix): the wall tile on the foreign part of the route, which the seal
template takes (at=audit)."""
import copy
import json

from dfpilot import bp, cmd, files
from dfpilot.bp import defense

from bp_fixtures import FORT, L, dig, fort_docs, mutation, shortcut, terrain, tiny

ZR = -2 - 3 - 3                       # fortcore refuge level (depth 3, refuge 3)


def audit_of(extra, base=None):
    w = bp.as_built(fort_docs() + extra, base=base)
    return w, bp.audit(w.snapshot(), w.manifest)


def test_shortcut_bypass_names_the_wall_beside_z3():
    w, res = audit_of([mutation([dig(shortcut())])])
    x, y, z = L(-5, 38, -2)                                    # the shortcut's last tile, diagonal to the gatehouse
    (f,) = [f for f in res["fails"] if f.startswith("bypass")]
    assert f.startswith(f"bypass: wall {x},{y},{z} floor -> ") and "(+more)" not in f and len(f) <= 60
    w.set(x, y, z, "C")                                        # the wall the finding asks for
    assert not bp.audit(w.snapshot(), w.manifest)["bypass"]
    found = [x for x in bp.validate(fort_docs() + [mutation([dig(shortcut())])]) if x.code == "bypass"]
    assert found and found[0].msg == f                         # the validator says the same


def refuge_tunnel():
    """Run 10's shape: a way down to the refuge level outside the fort (a stair from the surface, a tunnel into the
    refuge room); attackers reach the refuge and then Z4 up the civilian stair."""
    tun = [L(u, 45, ZR) for u in range(-16, -4)]
    col = [L(-17, 45, w) for w in range(ZR, 1)]
    cells = [(x, y, z, "u" if z == FORT[2] + ZR else "j" if z == FORT[2] else "i") for x, y, z in col]
    return mutation([dig(tun), ("m.st", "dig", cells)])


def test_refuge_route_names_the_tunnel_tile_and_one_wall_fixes_both():
    w, res = audit_of([refuge_tunnel()], base=terrain().snapshot())
    x, y, z = L(-5, 45, ZR)
    civ = L(0, 45, ZR + 1)
    assert f"bypass: wall {x},{y},{z} floor -> {civ[0]},{civ[1]},{civ[2]}" in res["fails"]
    assert f"refuge: on the attack path, wall {x},{y},{z} floor" in res["fails"]
    assert res["min_traps"] == 35                              # counted as if the named wall stood (traps item)
    w.set(x, y, z, "C")
    res = bp.audit(w.snapshot(), w.manifest)
    assert res["ok"] and not res["bypass"] and res["refuge_sep"], res["fails"]


def test_no_wall_is_proposed_on_the_attack_side_itself():
    m = {"v": 2, "refuge": {"anchor": list(L(0, 10, -2)), "burrow": "Tiefe+"}}     # refuge in the bailey
    _, res = audit_of([mutation([], m)])
    assert "refuge: on the attack path (reachable without passing Z4)" in res["fails"]


def test_a_ramp_choke_gets_its_wall_on_the_top():
    # smoothed rock ('S'): nobody climbs around the ramp
    snap = tiny([["......S", "SSSSSrS", "SSSSSSS", "SSSSSSS"], ["______S", "SSSSSvS", "SSSS..S", "SSSSSSS"]])
    man = {"v": 2, "zones": {"Z2": [[0, 0, 0, 0, 0, 0]], "Z4": [[4, 2, 1, 5, 2, 1]]}, "edge": [[0, 0, 0]]}
    res = bp.audit(snap, man)
    assert "bypass: wall 5,1,0 ramp -> 5,2,1" in res["fails"], res["fails"]
    capped = copy.deepcopy(snap)                               # the seal's wall on the ramp top closes it
    capped["rows"]["z1"][1] = "SSSSSCS"
    assert not bp.audit(capped, man)["bypass"]
    assert [p["at"] for p in defense.seal_pieces({"at": "5,1,0 ramp wall"})] == [[5, 1, 1]]


def test_seal_takes_the_audit_walls(tmp_path):
    save = tmp_path / "save"
    w, res = audit_of([refuge_tunnel()], base=terrain().snapshot())
    files.write_json_atomic(save / "snap" / "c1.json", {**w.snapshot(purpose="sites"), "id": "c1"})
    ev = {"n": 3, "tick": 10, "type": "AUDIT", "cls": "B", "msg": "audit failed",
          "d": {"ok": 0, "fails": [f[:60] for f in res["fails"]], "min_traps": 0}}
    (save / "events.jsonl").write_text(json.dumps(ev) + "\n", encoding="utf-8")
    x, y, z = L(-5, 45, ZR)
    assert cmd.last_audit_walls(save) == [f"{x},{y},{z} floor wall"]
    at, _ = cmd.seal_openings(save, "audit")
    assert at == f"{x},{y},{z} floor wall"
    doc = cmd.place(save, "seal", {"at": "audit"}, "S1", "c7")
    (cell,) = [c for st in doc["stages"] for ch in st["chunks"] for c in ch["cells"]]
    assert cell[3] == "Cw"
    built = bp.as_built(doc, base=copy.deepcopy(w.snapshot()))
    built.manifest = w.manifest
    assert bp.audit(built.snapshot(), built.manifest)["ok"]
