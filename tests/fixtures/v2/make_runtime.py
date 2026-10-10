"""Regenerates tests/fixtures/v2/runtime (WP2): a realistic kern runtime folder per CONTRACTS §8-§9.

Run `python tests/fixtures/v2/make_runtime.py` after a contract change and commit the output; it is
checked by tests/test_cli_files.py::test_fixture_runtime_validates. The bp files come from WP3's bp.emit.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))
from df_llm_helper import schema  # noqa: E402

RT = ROOT / "tests" / "fixtures" / "v2" / "runtime"
SAVE = RT / "region7"
Y = 403200
WALL = 1791676800


def dump(doc):
    return json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def w(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")


def ev(n, tick, typ, msg, d=None):
    cls = schema.EVENTS[typ][0]
    return {"n": n, "tick": tick, "type": typ, "cls": cls, "msg": msg, "d": d or {}}


y3 = 3 * Y
old = []
n = 8650
for i, (typ, msg, d) in enumerate([
    ("SEASON", "winter y2", {"year": 2, "season": 3}),
    ("MIGRANTS", "7 migrants arrived", {"n": 7}),
    ("PROJECT_STAGE", "fortcore s1.build 80%", {"proj": "fortcore", "stage": "s1.build", "pct": 80}),
    ("STOCK_LOW", "drink 41 days < 170", {"key": "drink_d", "days": 41, "min": 170}),
    ("MOOD_START", "Urist McCarver: fey mood (Craftsdwarfs)", {"unit": 1201, "kind": "fey", "need": "", "ok": 1}),
    ("MOOD_END", "Urist McCarver: artifact made", {"unit": 1201, "kind": "fey", "need": "", "ok": 1}),
    ("PROJECT_DONE", "fortcore stage 1 done", {"proj": "fortcore", "tpl": "fortcore"}),
    ("PHASE", "P1 -> P2", {"from": "P1", "to": "P2"}),
    ("YEAR_REVIEW", "year 2 ended: review the plan", {"year": 2}),
]):
    n += 1
    old.append(ev(n, y3 - 40000 + i * 4000, typ, msg, d))

cur = []
n = 8700
seq = [
    (y3 + 0, "SEASON", "spring y3", {"year": 3, "season": 0}),
    (y3 + 600, "BOOT", "boot region7 (boots 4)", {"save": "region7", "v": 2, "boots": 4}),
    (y3 + 2400, "PHASE", "P2 -> P3", {"from": "P2", "to": "P3"}),
    (y3 + 5000, "CARAVAN", "dwarven caravan arrived", {"phase": "arrive", "ratio": 0, "civ": "Ostuk Udib"}),
    (y3 + 9000, "CARAVAN", "traded ratio 1.72", {"phase": "traded", "ratio": 172, "civ": "Ostuk Udib"}),
    (y3 + 15000, "MIGRANTS", "11 migrants arrived", {"n": 11}),
    (y3 + 20000, "PROJECT_STAGE", "y3s0b0 s1.dig 100%", {"proj": "y3s0b0", "stage": "s1.dig", "pct": 100}),
    (y3 + 26000, "ALERT_START", "2 visible hostiles", {"vis": 2}),
    (y3 + 26000, "MODE", "PEACE -> ALERT", {"from": "PEACE", "to": "ALERT", "why": "2 visible"}),
    (y3 + 29000, "ALERT_END", "quiet 1200 ticks", {"vis": 0}),
    (y3 + 29000, "MODE", "ALERT -> PEACE", {"from": "ALERT", "to": "PEACE", "why": "quiet"}),
    (y3 + 40000, "INVASION", "invasion armed", {"id": 31}),
    (y3 + 40020, "SIEGE_START", "41 visible invaders", {"vis": 41, "inv": 41, "great": 0, "why": "invaders"}),
    (y3 + 40020, "MODE", "PEACE -> SIEGE", {"from": "PEACE", "to": "SIEGE", "why": "41 invaders"}),
    (y3 + 40200, "LEVER", "O1 pull queued", {"bridge": "O1", "lever": 3021, "job": 88123}),
    (y3 + 40500, "GATE", "O1 up", {"bridge": "O1", "state": "up"}),
    (y3 + 40620, "SIEGE_STATUS", "41 vis, worn 93%, 8 on station", {"vis": 41, "worn": 93, "on_station": 8,
                                                                   "deaths": 0, "captures": 0}),
    (y3 + 52000, "CAPTURE", "goblin caught in a cage trap", {"unit": 5512, "race": "GOBLIN"}),
    (y3 + 70000, "DEATH", "Kib Ustuth died (struck down)", {"unit": 1388, "citizen": 1, "cause": "combat"}),
    (y3 + 80000, "MODE", "SIEGE -> RECOVERY", {"from": "SIEGE", "to": "RECOVERY", "why": "0 visible 2400t"}),
    (y3 + 88400, "SIEGE_END", "41 hostiles, 23 killed, 1 lost, sealed 40.0 d",
     {"hostiles": 41, "killed": 23, "lost": 1, "captures": 1, "sealed_ticks": 48000}),
    (y3 + 88400, "MODE", "RECOVERY -> PEACE", {"from": "RECOVERY", "to": "PEACE", "why": "quiet 8400"}),
    (y3 + 90000, "PROJECT_REQUEST", "tombs: 2 free < 7 needed", {"tpl": "tombs", "n": 6, "why": "free<need"}),
    (y3 + 90600, "SNAPSHOT_READY", "snapshot c201 (sites)", {"id": "c201", "path": "snap/c201.json",
                                                             "purpose": "sites"}),
    (y3 + 91000, "CMD", "bp.place ok", {"id": "c19a3f2b1c4e7", "verb": "bp.place", "ok": 1}),
    (y3 + 100800, "SEASON", "summer y3", {"year": 3, "season": 1}),
    (y3 + 101000, "KERNEL_SLOW", "runner 7 ms x3, factor 2", {"module": "runner", "ms": 7, "factor": 2}),
    (y3 + 104000, "STOCK_LOW", "drink 150 days < 170", {"key": "drink_d", "days": 150, "min": 170}),
    (y3 + 106000, "MOOD_START", "Zon Atir: secretive mood (Forge)", {"unit": 1422, "kind": "secretive",
                                                                      "need": "bars", "ok": 1}),
    (y3 + 106050, "MOOD_NEED", "Zon Atir needs iron bars", {"unit": 1422, "kind": "secretive", "need": "bar:iron",
                                                            "ok": 0}),
    (y3 + 108000, "DECISION_NEEDED", "D-07: visitor cap 30?", {"id": "D-07", "q": "set visitor_cap 30 (speed)?"}),
    (y3 + 110000, "CMD", "lever failed", {"id": "c19a40011aa2", "verb": "lever", "ok": 0}),
    (y3 + 112000, "SNAPSHOT_READY", "snapshot c200 (audit)", {"id": "c200", "path": "snap/c200.json",
                                                              "purpose": "audit"}),
    (y3 + 112600, "AUDIT", "audit fail: traps<30", {"ok": 0, "fails": ["traps<30"], "min_traps": 22}),
    (y3 + 113000, "READY_CHANGE", "R1 kept: traps<30", {"from": 1, "to": 1, "fail": ["traps<30"]}),
    (y3 + 115000, "PROJECT_BLOCKED", "y3s0b1 s1.build blocked 2 days: no_material",
     {"proj": "y3s0b1", "tpl": "workshops", "stage": "s1.build", "why": "no_material", "ticks": 2400}),
    (y3 + 118000, "ACT_FAIL", "act.workorder: bad item type", {"fn": "workorder", "err": "bad item type",
                                                               "module": "economy"}),
    (y3 + 121000, "PETITION", "temple petition (Armok)", {"kind": "temple"}),
    (y3 + 123000, "PROJECT_STAGE", "fortcore s2.build 64%", {"proj": "fortcore", "stage": "s2.build", "pct": 64}),
]
cur = [ev(0, tick, typ, msg, d) for tick, typ, msg, d in seq]
k = 0
while len(cur) < 112:                      # routine C events so that the last n is 8812 (= state.ev)
    k += 1
    pct = (k * 7) % 100
    cur.append(ev(0, y3 + 333 + k * 1680, "PROJECT_STAGE", f"y3s1b0 s1.dig {pct}%",
                  {"proj": "y3s1b0", "stage": "s1.dig", "pct": pct}))
cur.sort(key=lambda e: e["tick"])
for i, e in enumerate(cur):
    e["n"] = 8701 + i
assert cur[-1]["n"] == 8812, cur[-1]["n"]
for e in old + cur:
    errs = schema.validate("event", e)
    assert not errs, (e, errs)

w(SAVE / "events.1.jsonl", "".join(dump(e) + "\n" for e in old))
w(SAVE / "events.jsonl", "".join(dump(e) + "\n" for e in cur) + '{"cls":"C","d":{"id":"c9a1","path":"snap/')

state = {"v": 2, "seq": 812, "save": "region7",
         "t": {"y": 3, "tick": 123456, "season": 1, "tps": 462, "paused": False, "abs": y3 + 123456,
               "wall": WALL, "frame": 918273},
         "mode": "PEACE", "phase": "P3",
         "pop": {"cit": 52, "adults": 44, "cap": 55, "gate_cap": 55, "soldiers": 8},
         "ready": {"lvl": 1, "worn": 94, "cv": 13, "drill_age": 40000,
                   "audit": {"ok": 0, "age": 11456, "min_traps": 22}, "fail": ["traps<30"]},
         "stock": {"drink_d": 150, "food_d": 75, "meals": 6, "hosp_water": 1},
         "care": {"stressed_pct": 4, "naked": 0, "ghosts": 0, "corpses_old": 0, "tombs_free": 9, "moods": 1},
         "labor": {"starving": 0, "idle": 31}, "threat": {"vis": 0, "armed": 0},
         "proj": [["fortcore", "s2.build", 64, ""], ["y3s1b0", "s1.dig", 12, ""],
                  ["y3s0b1", "s1.build", 40, "no_material"]],
         "bridges": {"O1": "down", "B1": "down", "B2": "down"},
         "k": {"ms_s": 11, "gap_max_ms": 420, "slow": ["runner"], "faults": 0, "ms_max": 6},
         "owners": {"pause": None, "tempo": "mode"}, "ev": 8812,
         "mil": {"squads": 1, "soldiers": 8, "worn": 94, "cv": 13, "metal_pct": 40, "on_station": 0},
         "trade": {"caravan": 0, "ratio": 172, "done": 1}}
assert not schema.validate("state", state), schema.validate("state", state)
older = json.loads(json.dumps(state))
older.update(seq=811)
older["t"].update(tick=122560, abs=y3 + 122560, wall=WALL - 2, frame=918150)
older["ev"] = 8811
assert not schema.validate("state", older)
w(SAVE / "state.a.json", dump(older))
w(SAVE / "state.b.json", dump(state))
hb = {"v": 2, "wall": WALL, "frame": 918273, "tick": y3 + 123456, "paused": False, "mode": "PEACE", "seq": 812}
assert not schema.validate("heartbeat", hb)
w(SAVE / "heartbeat", dump(hb) + "\n")
w(RT / "ACTIVE", "region7\n")
rs = {"v": 2, "save": "region7", "wall": WALL - 3600, "active": 1,
      "orig": {"gfps": 250, "autosave": "SEASONAL", "visitor_cap": 300, "population_cap": 75, "timestream_fps": -1,
               "overlays": {"hotkeys.menu": True}}}
assert not schema.validate("restore", rs)
w(RT / "restore.json", dump(rs))

ob = {"id": "c19a3f2b1c4e7", "ok": True, "msg": "queued y3s1", "verb": "bp.place", "tick": y3 + 91000,
      "data": {"proj": "c19a3f2b1c4e7"}}
assert not schema.validate("outbox", ob)
w(SAVE / "outbox" / "c19a3f2b1c4e7.json", dump(ob))

plan = {"v": 2, "year": 3, "policy": {"option": "A", "pop_ceiling": 55, "beauty": "used_rooms"},
        "phase_target": "P4",
        "seasons": [{"build": [{"tpl": "workshops", "site": "S1"}, {"tpl": "hospital", "site": "S2"}],
                     "orders": {"import": ["library/furnace"]}},
                    {"build": [{"tpl": "bedrooms", "site": "S1", "p": {"n": 20, "tier": 500}}]},
                    {"build": [{"tpl": "tavern", "site": "S1"}]}, {"build": []}],
        "military": {"pct": 15, "squads": {"melee": 1, "xbow": 0}, "cv_min": 12},
        "supply": {"drink_d": 170, "food_d": 60, "mood_stock": 10},
        "orders": {"import": ["library/basic", "library/rockstock"]},
        "trade": {"want": ["bar:iron", "anvil", "cloth"], "sell": ["crafts"]}, "notes": "y3: P3 workshops, P4 living"}
assert not schema.validate("plan", plan), schema.validate("plan", plan)
w(SAVE / "plan.json", dump(plan))

# blueprint files of the applied plan, emitted by WP3's bp.emit (what `plan apply` wrote)
import importlib  # noqa: E402
bpe = importlib.import_module("df_llm_helper.bp.emit")
from df_llm_helper.cmd import Occupancy  # noqa: E402
occ = Occupancy()                          # applied projects never share or touch tiles (cmd.place)
for bid, site, anchor in (("y3s0b0", "S1", [45, 47, 120]), ("y3s0b1", "S2", [66, 47, 120]),
                          ("y3s1b0", "S1", [52, 60, 120]), ("y3s2b0", "S1", [70, 56, 120])):
    si, bi = int(bid[3]), int(bid[5])
    b = plan["seasons"][si]["build"][bi]
    assert b["site"] == site
    doc = dict(bpe.emit(b["tpl"], b.get("p") or {}, {"id": site, "anchor": anchor, "rot": 0}), id=bid)
    assert not schema.validate("bp", doc), schema.validate("bp", doc)
    assert not occ.clash(doc), (bid, occ.clash(doc))
    occ.add(doc)
    w(SAVE / "bp" / f"{bid}.json", dump(doc))

snap_a = {"v": 2, "id": "c200", "tick": y3 + 112000, "purpose": "audit", "bbox": [10, 20, 120, 15, 21, 121],
          "rows": {"z120": ["#..=.#", "#^.H.#"], "z121": ["??____", "CCC.CC"]},
          "bridges": {"B1": "up"}, "traps": [[11, 21, 120, "W", 3, 1]], "marks": {"damp": [[15, 21, 121]]}}
assert not schema.validate("snapshot", snap_a), schema.validate("snapshot", snap_a)
w(SAVE / "snap" / "c200.json", dump(snap_a))
# 40x30 rock around the core: an east-west corridor (y=45) with the civilian stair at x=60, a dining room
# north of it, solid rock south and below (where new rooms can be dug); hidden rock at the far south edge
W_, H_ = 40, 30
rows120, rows119 = [], []
for yy in range(30, 30 + H_):
    r = ["#"] * W_
    if yy == 45:
        r = ["#"] + ["."] * (W_ - 2) + ["#"]
        r[60 - 40] = "X"
    elif 38 <= yy <= 43:
        for xx in range(55, 66):
            r[xx - 40] = "S" if yy in (38, 43) or xx in (55, 65) else "."
        if yy == 43:
            r[60 - 40] = "+"
    if yy >= 57:
        r = ["?"] * W_
    rows120.append("".join(r))
    r119 = ["#"] * W_
    r119[60 - 40] = "X"
    rows119.append("".join(r119))
snap_s = {"v": 2, "id": "c201", "tick": y3 + 90600, "purpose": "sites", "bbox": [40, 30, 119, 79, 59, 120],
          "rows": {"z119": rows119, "z120": rows120}, "bridges": {}, "traps": []}
assert not schema.validate("snapshot", snap_s), schema.validate("snapshot", snap_s)
w(SAVE / "snap" / "c201.json", dump(snap_s))

lines = ["wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods"]
tick = y3 + 123456 - 24 * 30 * 460
for i in range(25):
    wall = WALL - (24 - i) * 30
    tps = 455 + (i * 7) % 20 if i != 12 else 310
    gap = 420 if i != 12 else 3600
    lines.append(f"{wall},{tick},PEACE,{tps},52,180,{9100 + i},{10 + i % 4},{gap},{1 if i == 12 else 0},"
                 f"sense={38 + i % 5};siege=9;gate=3;runner={100 + i * 2};economy=60;care=41;arbiter=12;perf=4")
    tick += 30 * tps
w(SAVE / "perf.csv", "\n".join(lines) + "\n")
w(SAVE / "commands.log",
  f"{WALL - 900}\t{y3 + 110000}\tinbox:c19a40011aa2:llm\tverb:lever\t{{\"bridge\":\"O1\",\"want\":\"up\"}}\tERR not in PEACE\n"
  f"{WALL - 800}\t{y3 + 112600}\treadiness\tact.popcap\t[55]\tok\n")
w(SAVE / "kern.log", f"{WALL - 700}\t{y3 + 101000}\twarn\trunner\tslow 7 ms (3x), factor 2\n")
# the kern manifest from the last `inspect manifest` reply (follow caches it): Z4 = the corridor of c201 and the
# dining room north of it, so bp.sites.rank finds room anchors there (it needs zones.Z4 for rooms)
man = {"v": 2, "zones": {"Z4": [[41, 45, 120, 78, 45, 120], [56, 39, 120, 64, 42, 120]]},
       "burrows": {"Kern+": {"role": "kern"}}, "stairs": {"civ": [[60, 45, 119, 120]]}}
assert not schema.validate("manifest", man), schema.validate("manifest", man)
w(SAVE / ".manifest.json", dump(man) + "\n")
# fortcore stage 1 was placed in year 1 (site 'same' for the later stages resolves to it)
w(SAVE / "bp" / ".placed-fortcore.json", dump({"anchor": [48, 30, 130], "bp": "y1s0b0", "from": "S1", "rot": 0}) + "\n")
print("ok", len(old), len(cur))
