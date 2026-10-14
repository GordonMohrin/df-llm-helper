"""Run watcher: measure the goals of the running fort against targets and say what to do NEXT.

    python tools/run_watch.py            one report
    python tools/run_watch.py --watch    every 3 minutes, as a Monitor target (quiet: prints only the focus line
                                          when nothing changed, the full table when a goal flipped or every 5th round)
    python tools/run_watch.py --journal  also append a season row to the run journal

Read only: `python -m df_llm_helper` (status, census) and tools/run_probe.lua (counts, visible tiles only).
The goals are the ones Gordon set (runs/ZIELE-GORDON.md, runs/ZIELE-PRIORITAETEN.md). GOALS is ordered by
priority; the FOCUS is the first goal that is not met. If the focus has not changed for 3 rounds the report says
ESCALATE: stop repeating the same step, find the cause (job diagnosis, material, labour, path).
The yearly quicksave is done here too (once per game year, spring).
"""
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DF = os.environ.get("DFLLM_DF", r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress")
RUN = os.path.join(DF, "hack", "dfhack-run.exe")
JOURNAL = os.environ.get("RUN_JOURNAL", r"C:\Users\admin\claude gordons projects\dwarf-fortress\runs\run-9-neues-fort\JOURNAL.md")
STATE = os.path.join(os.path.dirname(JOURNAL), ".watch_state.json")
CLI = [sys.executable, "-m", "df_llm_helper"]
REPO = os.path.dirname(HERE)

MOODABLE = ["W_Carpenters", "W_Masons", "W_Craftsdwarfs", "W_Mechanics", "W_Jewelers", "W_Leatherworks", "W_Clothiers",
            "W_Bowyers", "W_Still", "W_Kitchen", "W_MetalsmithsForge", "W_Loom"]


def run(cmd, timeout=90):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=REPO)
        return r.stdout
    except Exception as e:  # noqa: BLE001
        return ""


def probe():
    out = run([RUN, "lua", "-f", os.path.join(HERE, "run_probe.lua")], 90)
    m = {}
    for line in out.splitlines():
        k, _, v = line.partition("=")
        v = v.strip()
        if re.fullmatch(r"-?\d+", v):
            m[k] = int(v)
        else:
            m[k] = v
    return m


def status():
    txt = run(CLI + ["status"], 60)
    s = {"raw": txt}
    g = lambda p, d=None: (lambda mm: int(mm.group(1)) if mm else d)(re.search(p, txt))
    s["drink_d"] = g(r"drink (\d+)d")
    s["food_d"] = g(r"food (\d+)d")
    s["stress"] = g(r"stress (\d+)%")
    s["idle"] = g(r"idle (\d+)%")
    s["ghosts"] = g(r"ghosts (\d+)")
    s["corpses"] = g(r"corpses (\d+)")
    s["tombs"] = g(r"tombs (\d+)")
    s["traps"] = g(r"traps (\d+)")
    s["pop"] = g(r"pop (\d+)")
    s["cap"] = g(r"cap (\d+)")
    s["mode"] = (re.search(r"\b(PEACE|ALERT|SIEGE|BREACH|RECOVERY|DRILL)\b", txt) or [None, None])[1] if txt else None
    mm = re.search(r"\b(spr|sum|aut|win) d(\d+)", txt)
    s["season"] = mm.group(1) if mm else None
    s["sol"] = g(r"\((\d+)ad (\d+)sol\)", None)
    ms = re.search(r"\((\d+)ad (\d+)sol\)", txt)
    s["adults"] = int(ms.group(1)) if ms else None
    s["soldiers"] = int(ms.group(2)) if ms else None
    s["paused"] = "paused" in txt.split("\n")[0]
    return s


def census():
    out = run(CLI + ["cmd", "inspect", "what=census"], 60)
    try:
        j = json.loads(out[out.index("{"):])
        return j.get("i", {})
    except Exception:  # noqa: BLE001
        return {}


# (id, text, check(m,s,c) -> (ok, detail), next-step hint)
def goals(m, s, c):
    def b(k):
        return m.get("b." + k, 0)

    mood_have = [w for w in MOODABLE if b(w) or m.get("b.F_" + w[2:], 0)]
    mood_missing = [w[2:] for w in MOODABLE if w not in mood_have]
    buf = {k: c.get(k, 0) for k in ("boulders", "blocks", "wood", "gems", "cloth", "leather", "thread")}
    buf_low = [f"{k} {v}" for k, v in buf.items() if v < 20]
    adults = s.get("adults") or m.get("adults", 0)
    G = []
    G.append(("thirst/hunger", "Niemand verdurstet/verhungert (Hunger < 65000, Durst < 40000)",
              lambda: (m.get("max_hunger", 0) < 65000 and m.get("max_thirst", 0) < 40000,
                       f"Hunger max {m.get('max_hunger')}, Durst max {m.get('max_thirst')}"),
              "Wer hungert/dürstet? Essen/Getränke erreichbar? Lager, Fässer, Pfad prüfen"))
    G.append(("drink", "Trinken >= 30 Tage", lambda: ((s["drink_d"] or 0) >= 30, f"{s['drink_d']} d"),
              "Destille läuft? Brauauftrag frei? Pflanzen/Samen? Handel Getränke"))
    G.append(("food", "Essen >= 30 Tage", lambda: ((s["food_d"] or 0) >= 30, f"{s['food_d']} d"),
              "Farmfelder alle Jahreszeiten bepflanzt? Samen? Sammeln, Handel, Küche"))
    G.append(("water", "Wasserquelle (Probe-Raum) vorhanden", lambda: (m.get("wet_tiles", 0) > 0, f"{m.get('wet_tiles')} nasse Felder"),
              "Probe-Raum in der Aquifer-Schicht (z113) graben"))
    G.append(("dead", "Lose Leichen 0 und Geister 0", lambda: ((s["corpses"] or 0) == 0 and (s["ghosts"] or 0) == 0,
                                                              f"Leichen {s['corpses']}, Geister {s['ghosts']}"),
              "Särge/Gräber, Bestattung priorisieren"))
    G.append(("graves", "Freie Gräber >= 5", lambda: ((s["tombs"] or 0) >= 5, f"{s['tombs']} frei"), "Särge + Grabzonen"))
    G.append(("stress", "Stress <= 10 %", lambda: ((s["stress"] or 0) <= 10, f"{s['stress']} %"),
              "Schlafzimmer, Taverne, Tempel, Speisesaal, Tote weg"))
    G.append(("idle", "Leerlauf <= 30 %", lambda: ((s["idle"] or 0) <= 30, f"{s['idle']} %"),
              "Backlog auffüllen: Bau, Glätten/Gravur, Handelswaren, Bergbau; Bau-Aufträge freigeben"))
    G.append(("office", "Manager-Büro mit Möbeln", lambda: (m.get("b.Z_Office", 0) >= 1 and b("Table") + b("Chair") >= 2,
                                                         f"Büro-Zone {m.get('b.Z_Office', 0)}, Tische {b('Table')}, Stühle {b('Chair')}"),
              "Tisch+Stuhl in der Büro-Zone; ohne Büro werden keine Aufträge freigegeben"))
    G.append(("stockpiles", "Lager >= 6", lambda: (b("Stockpile") >= 6, f"{b('Stockpile')}"), "quickfort #place: Essen, Stein, Holz, Barren, Möbel, Edelsteine"))
    G.append(("workshops", "Werkstatt für jedes Mood-Handwerk (12)", lambda: (len(mood_missing) == 0, f"fehlen: {', '.join(mood_missing) or '-'}"),
              "fehlende Werkstätten bauen (quickfort wX, in den Kern)"))
    G.append(("buffer", "Puffer >= 20 je Rohstoff", lambda: (not buf_low, "niedrig: " + (", ".join(buf_low) or "-")),
              "Steinbruch, Holz, Edelsteine schleifen, Handel"))
    G.append(("beds", "Bett für jeden Erwachsenen + 4", lambda: (b("Bed") >= adults + 4, f"{b('Bed')} Betten / {adults} Erwachsene"),
              "ConstructBed-Aufträge, Betten in Zimmer setzen"))
    G.append(("defense", "Fallengang: Zugbrücken >= 4, Hebel >= 4, Fallen >= 20",
              lambda: (b("Bridge") >= 4 and b("T_Lever") >= 4 and (b("T_StoneFallTrap") + b("T_WeaponTrap") + b("T_CageTrap")) >= 20,
                       f"Brücken {b('Bridge')}, Hebel {b('T_Lever')}, Fallen {b('T_StoneFallTrap') + b('T_WeaponTrap') + b('T_CageTrap')}, Mechanismen {m.get('mechanisms')}"),
              "Mechanismen (aus Stein) bestellen; Brücken/Hebel dann Fallen"))
    G.append(("military", "Soldaten >= 15 % der Erwachsenen, Armbrüste/Bolzen",
              lambda: ((s.get("soldiers") or 0) * 100 >= 15 * max(adults, 1), f"{s.get('soldiers')} Soldaten / {adults} Erwachsene, Armbrüste {m.get('crossbows')}"),
              "Bowyer + Armbrüste aus Holz, Trupp aufstellen, Training"))
    G.append(("rooms", "Speisesaal, Taverne, Tempel, Hospital, Bibliothek mit Zonen",
              lambda: (all(m.get("b.Z_" + z, 0) >= 1 for z in ("Dining", "Tavern", "Temple", "Hospital")) or False,
                       f"Zonen: " + ", ".join(f"{z} {m.get('b.Z_' + z, 0)}" for z in ("Dining", "Tavern", "Temple", "Hospital", "Library"))),
              "Zonen setzen und Räume möblieren (nach Betten/Tischen)"))
    G.append(("growth", "Bevölkerung wächst (>= 30)", lambda: ((s["pop"] or 0) >= 30, f"{s['pop']} (Cap {s['cap']})"),
              "Cap anheben nach Fundament; Essen/Wohnraum"))
    return G


def evaluate(G):
    rows = []
    for gid, text, fn, hint in G:
        try:
            ok, detail = fn()
        except Exception as e:  # noqa: BLE001
            ok, detail = False, f"? ({e})"
        rows.append((gid, text, bool(ok), detail, hint))
    return rows


def load_state():
    try:
        return json.load(open(STATE, encoding="utf-8"))
    except Exception:  # noqa: BLE001
        return {}


def save_state(st):
    try:
        json.dump(st, open(STATE, "w", encoding="utf-8"))
    except Exception:  # noqa: BLE001
        pass


def report(full=True, journal=False):
    s = status()
    if not s["raw"]:
        print("KEIN STATUS (Kernel/DF aus?)")
        return None
    m = probe()
    c = census()
    rel = run([RUN, "lua", "-f", os.path.join(HERE, "run_release.lua")], 60)
    mrel = re.search(r"released=(\d+)", rel)
    mcj = re.search(r"construct_jobs=(\d+)", rel)
    m["released"] = int(mrel.group(1)) if mrel else 0
    m["construct_jobs"] = int(mcj.group(1)) if mcj else 0
    G = goals(m, s, c)
    rows = evaluate(G)
    st = load_state()
    flips = []
    prev = st.get("ok", {})
    for gid, text, ok, detail, hint in rows:
        if gid in prev and prev[gid] != ok:
            flips.append((gid, ok))
    st["ok"] = {r[0]: r[2] for r in rows}
    focus = next((r for r in rows if not r[2]), None)
    fid = focus[0] if focus else None
    if st.get("focus") == fid:
        st["focus_rounds"] = st.get("focus_rounds", 0) + 1
    else:
        st["focus"], st["focus_rounds"] = fid, 1
    met = sum(1 for r in rows if r[2])
    year, tick = m.get("year"), m.get("tick", 0)
    season = ["Fruehling", "Sommer", "Herbst", "Winter"][min(3, int(tick) // 100800)] if isinstance(tick, int) else "?"
    print(f"== {m.get('year')} {season} | Pop {s['pop']}/{s['cap']} (Erw {s['adults']}, Sold {s['soldiers']}) | "
          f"Essen {s['food_d']}d Trinken {s['drink_d']}d | Stress {s['stress']}% Leerlauf {s['idle']}% | Ziele {met}/{len(rows)}"
          f"{' | PAUSIERT' if s.get('paused') else ''}"
          f" | Bau-Auftraege {m.get('construct_jobs')} (freigegeben {m.get('released')})")
    if full or flips:
        for gid, text, ok, detail, hint in rows:
            print(f"  [{'x' if ok else ' '}] {text}: {detail}")
    for gid, ok in flips:
        print(f"  >> {'ERREICHT' if ok else 'ROT'}: {gid}")
    if focus:
        esc = "  ** STILLSTAND seit %d Runden -> Ursache suchen, nicht wiederholen **" % st["focus_rounds"] if st["focus_rounds"] >= 3 else ""
        print(f"FOKUS: {focus[1]} ({focus[3]})\n  naechster Schritt: {focus[4]}{esc}")
    else:
        print("FOKUS: alle Ziele erreicht -> naechste Stufe (Wachstum, Prunkfort)")
    # yearly quicksave (spring, once per game year)
    if isinstance(year, int) and st.get("saved_year") != year and isinstance(tick, int) and tick < 100800 and not s.get("paused"):
        run([RUN, "quicksave"], 90)
        st["saved_year"] = year
        print(f"  Quicksave Jahr {year} ausgefuehrt")
    if journal and isinstance(year, int) and st.get("journal_key") != f"{year}{season}":
        st["journal_key"] = f"{year}{season}"
        row = (f"{year} {season} | Pop {s['pop']} | Food {s['food_d']}d | Drink {s['drink_d']}d | Stress {s['stress']}% | "
               f"Leerlauf {s['idle']}% | Ziele {met}/{len(rows)} | Fokus {fid}\n")
        try:
            open(JOURNAL, "a", encoding="utf-8").write(row)
        except Exception:  # noqa: BLE001
            pass
    save_state(st)
    return rows


def main():
    if "--watch" in sys.argv:
        n = 0
        while True:
            report(full=(n % 5 == 0), journal=True)
            n += 1
            sys.stdout.flush()
            time.sleep(180)
    else:
        report(True, "--journal" in sys.argv)


if __name__ == "__main__":
    main()
