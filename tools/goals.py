"""Goal list for a running fort: what a human player would want, checked over and over (Gordon, 11.10.2026).

    python tools/goals.py            one table: every goal, done or open, with the number behind it
    python tools/goals.py --watch    every 10 minutes: print goals that flipped, and the 3 most urgent open ones
    python tools/goals.py --json     the raw numbers

Read only. The numbers come from tools/goals_probe.lua (counts, no names, no hidden tiles) and from
`python -m df_llm_helper status`. Edit GOALS to add or change a goal: (id, tier, text, check, hint), check(m)
returns (done, detail). Tier 1 = survive, 2 = comfort, 3 = industry, 4 = defence, 5 = growth and prestige.
"""
import json
import os
import re
import subprocess
import sys
import time

DF = os.environ.get("DFLLM_DF", r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress")
RUN = os.path.join(DF, "hack", "dfhack-run.exe")
HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.join(DF, "dfllm-runtime", "goals.json")


def probe():
    r = subprocess.run([RUN, "lua", "-f", os.path.join(HERE, "goals_probe.lua")], capture_output=True, text=True,
                       timeout=90)
    m = {}
    for line in r.stdout.splitlines():
        k, _, v = line.partition("=")
        if v.lstrip("-").isdigit():
            m[k] = int(v)
    return m


def status():
    r = subprocess.run([sys.executable, "-m", "df_llm_helper", "status"], capture_output=True, text=True,
                       timeout=60, cwd=os.path.dirname(HERE))
    t = r.stdout
    s = {"raw": t}

    def num(rx, key):
        g = re.search(rx, t)
        if g:
            s[key] = int(g.group(1))

    num(r"drink (\d+)d", "drink_d")
    num(r"food (\d+)d", "food_d")
    num(r"stress (\d+)%", "stress")
    num(r"worn (\d+)%", "worn")
    num(r"pop (\d+) ", "pop")
    num(r"cap (\d+) ", "cap")
    num(r"\((\d+)ad (\d+)sol\)", "adults_k")
    g = re.search(r"\((\d+)ad (\d+)sol\)", t)
    if g:
        s["sol"] = int(g.group(2))
    g = re.search(r"R\d fail:(\S*)", t)
    s["fails"] = g.group(1) if g else ""
    s["drill_never"] = "drill never" in t
    return s


def caravans_traded(years=2):
    r = subprocess.run([sys.executable, "-m", "df_llm_helper", "events", "--since", "0"], capture_output=True, text=True,
                       timeout=60, cwd=os.path.dirname(HERE))
    return sum(1 for ln in r.stdout.splitlines() if " CARAVAN traded with" in ln)


def pct(a, b):
    return (100 * a // b) if b else 0


# (id, tier, text, check(m) -> (done, detail), hint)
GOALS = [
    ("food", 1, "Essen fuer 90 Tage", lambda m: (m["food_d"] >= 90, f'{m["food_d"]} Tage'),
     "Felder bepflanzt? Saat per Karawane, Tiere schlachten, Sammelzone"),
    ("drink", 1, "Getraenke fuer 90 Tage", lambda m: (m["drink_d"] >= 90, f'{m["drink_d"]} Tage'),
     "Brauauftrag freigegeben? Fass leer? Pflanzen zum Brauen?"),
    ("hurt", 1, "hoechstens 3 Verwundete", lambda m: (m["wounded"] <= 3, f'{m["wounded"]} verwundet'),
     "Hospital mit Wasser, Aerzte, Verbandszeug"),
    ("busy", 1, "mindestens 60 % arbeiten", lambda m: (pct(m["busy"], m["adults"]) >= 60,
                                                      f'{pct(m["busy"], m["adults"])} % ({m["busy"]} von {m["adults"]})'),
     "Steinbrueche, Raeume graben, Handelsware, Werkstaetten"),
    ("housed", 2, "jeder Erwachsene hat ein Schlafzimmer", lambda m: (m["housed"] >= m["adults"],
                                                                       f'{m["housed"]} von {m["adults"]}'),
     "bedrooms-Vorlage platzieren / Zonen zuweisen"),
    ("stress", 2, "Stress hoechstens 10 %", lambda m: (m["stress"] <= 10, f'{m["stress"]} %'),
     "Taverne, Tempel, schoene Wohnraeume, Tote begraben"),
    ("social", 2, "Taverne, Tempel, Speisesaal, Hospital vorhanden",
     lambda m: (all(m.get("zone_" + n, 0) for n in ("Tavern", "Temple", "Dining", "Hospital")),
                " ".join(f'{n}={m.get("zone_" + n, 0)}' for n in ("Tavern", "Temple", "Dining", "Hospital"))),
     "tavern/temple/dining/hospital planen"),
    ("library", 2, "eine Bibliothek", lambda m: (m.get("zone_Library", 0) > 0, f'{m.get("zone_Library", 0)}'),
     "Bibliothek-Zone + Buecherregale (Gelehrte bleiben)"),
    ("nobles", 2, "Adlige haben Buero, Schlafzimmer, Speisezimmer",
     lambda m: (m["mayor_exists"] == 0 or (m["mayor_office"] and m["mayor_bedroom"] and m["mayor_dining"]
                                          and m["bookkeeper_office"] and m["manager_office"]),
                f'Buergermeister buero={m["mayor_office"]} schlaf={m["mayor_bedroom"]} speise={m["mayor_dining"]}; '
                f'Buchhalter buero={m["bookkeeper_office"]}; Verwalter buero={m["manager_office"]}'),
     "Raeume bauen UND verzieren (Wert 500 beim Buergermeister)"),
    ("hall", 2, "Festhalle fuer besondere Anlaesse", lambda m: (m.get("zone_Festhalle", 0) > 0,
                                                              f'{m.get("zone_Festhalle", 0)}'),
     "hall-Vorlage in tiefer Ebene (bp.place hall)"),
    ("crypt", 2, "Krypta: mindestens 20 freie Graeber", lambda m: (m["tombs_free"] >= 20, f'{m["tombs_free"]} frei'),
     "tombs n=40 in tiefer Ebene"),
    ("tombs", 2, "mindestens 5 freie Graeber", lambda m: (m["tombs_free"] >= 5, f'{m["tombs_free"]} frei'),
     "tombs-Vorlage / Geister vermeiden"),
    ("metal", 3, "Erz gefunden oder 20 Metallbarren", lambda m: (m["ore_boulders"] > 0 or m["metal_bars"] >= 20,
                                                                f'{m["ore_boulders"]} Erz, {m["metal_bars"]} Barren'),
     "Suchstollen, Handel (bar:iron/bronze), Altmetall einschmelzen"),
    ("farms", 3, "mindestens 10 Felder mit Pflanze", lambda m: (m["farm_cropped"] >= 10,
                                                              f'{m["farm_cropped"]} von {m["farm_plots"]}'),
     "Felder + passende Saat; unterirdisch braucht Plump-Helmet-Saat"),
    ("trade", 3, "Karawane hat gehandelt (2 Jahre)", lambda m: (m["traded"] > 0, f'{m["traded"]}x'),
     "Handelsware (Kunsthandwerk), Depot erreichbar"),
    ("barracks", 4, "Kaserne mit Trainingsraum", lambda m: (m.get("zone_Kaserne", 0) > 0, f'{m.get("zone_Kaserne", 0)}'),
     "barracks-Vorlage (bp.place barracks)"),
    ("army", 4, "Soldaten: 10 % der Erwachsenen", lambda m: (m.get("sol", 0) * 10 >= m["adults"],
                                                           f'{m.get("sol", 0)} von {m["adults"]}'),
     "Trupp aufstellen, Ausruestung, Kaserne"),
    ("gear", 4, "Ausruestung hoechstens 20 % verschlissen", lambda m: (m.get("worn", 100) <= 20,
                                                                     f'{m.get("worn", "?")} %'),
     "Metall, Leder, Stoff -> Kleidung/Ruestung"),
    ("gates", 4, "Tore/Bruecken in Ordnung", lambda m: ("bridge" not in m["fails"] and "levers" not in m["fails"],
                                                       m["fails"] or "ok"),
     "Zugbruecke + Hebel am Aussentor (bp.place fortcore Stufen)"),
    ("drill", 4, "Alarm-Uebung bestanden", lambda m: (not m["drill_never"], "nie geuebt" if m["drill_never"] else "ok"),
     "dfllm cmd drill"),
    ("growth", 5, "Bevoelkerung ueber 80 % der Obergrenze", lambda m: (pct(m.get("pop", 0), m.get("cap", 1)) >= 80,
                                                                       f'{m.get("pop", 0)} von {m.get("cap", "?")}'),
     "Essen, Wohnraeume, Sicherheit vor mehr Zuzug"),
]


def collect():
    m = probe()
    s = status()
    m.update({k: v for k, v in s.items() if k != "raw"})
    m["traded"] = caravans_traded()
    return m


def evaluate(m):
    res = []
    for gid, tier, text, check, hint in GOALS:
        try:
            done, detail = check(m)
        except KeyError as e:
            done, detail = False, f"keine Zahl ({e})"
        res.append({"id": gid, "tier": tier, "text": text, "done": bool(done), "detail": detail, "hint": hint})
    return res


def table(res):
    lines = []
    for r in res:
        lines.append(f'{"[x]" if r["done"] else "[ ]"} T{r["tier"]} {r["text"]}: {r["detail"]}'
                     + ("" if r["done"] else f'  -> {r["hint"]}'))
    lines.append(f'{sum(r["done"] for r in res)} von {len(res)} Zielen erreicht')
    return "\n".join(lines)


def load_state():
    try:
        with open(STATE, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_state(res):
    try:
        os.makedirs(os.path.dirname(STATE), exist_ok=True)
        with open(STATE, "w", encoding="utf-8") as f:
            json.dump({r["id"]: r["done"] for r in res}, f)
    except OSError:
        pass


def watch(every=600):
    last = load_state()
    n = 0
    while True:
        try:
            res = evaluate(collect())
        except Exception as e:  # noqa: BLE001 - keep watching through a restart of DF
            print(f"goals: keine Messung ({type(e).__name__})", flush=True)
            time.sleep(60)
            continue
        flips = [r for r in res if last and last.get(r["id"]) is not None and last[r["id"]] != r["done"]]
        for r in flips:
            print(f'ZIEL {"erreicht" if r["done"] else "VERLOREN"}: {r["text"]} ({r["detail"]})', flush=True)
        if n % 6 == 0 or flips:
            open_ = sorted((r for r in res if not r["done"]), key=lambda r: r["tier"])[:3]
            print(f'ziele {sum(r["done"] for r in res)}/{len(res)}; als Naechstes: '
                  + " | ".join(f'T{r["tier"]} {r["text"]} ({r["detail"]})' for r in open_), flush=True)
        save_state(res)
        last = {r["id"]: r["done"] for r in res}
        n += 1
        time.sleep(every)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    if "--watch" in sys.argv:
        watch()
    else:
        result = evaluate(collect())
        print(json.dumps(result, ensure_ascii=False, indent=1) if "--json" in sys.argv else table(result))
        save_state(result)
