"""`dfpilot leiter` (Neuausrichtung 1, P1; EHRGEIZ-MECHANIK section 2; docs/v2/NEU1-wertung.md): the Engpass-Leiter.

Six tracks with levels I-III, computed from the kernel state and the events only (never from a file the player writes):
gates (Volk II needs Wehr II, Volk III needs Wehr III + Ruestung II), an acute floor (siege, lockdown, a citizen dying,
an open perimeter: the duty, never a build), a lock per avoidable death cause until the tool sees the cause fixed, a
track blocked only with tool evidence, the fort's and the run's records and a session balance (`--start`, `--sitzung`).
Three lines go into `brief` (LEITER / NAECHST / OFFEN-GESPERRT), the LEITER line into `status`.

<save>/leiter.json (tool file, kind `leiter`) keeps what the state alone cannot show: the best levels, the one-year hold
clocks (drink >= 170 d, stress < 10 %) and the session start. The player cannot write it (the fair-play hook blocks file
writes under dfllm-runtime/); it holds only values this module computed."""
from __future__ import annotations

import json
import re
import time
from pathlib import Path

from . import files, paths, schema, wertung
from .events import DAY, SEASON, YEAR, fmt_tick

TRACKS = ["versorgung", "wehr", "ruestung", "volk", "wohl", "ausbau"]
NAME = {"versorgung": "Versorgung", "wehr": "Wehr", "ruestung": "Ruestung", "volk": "Volk", "wohl": "Wohl",
        "ausbau": "Ausbau"}
PRIO = ["wehr", "versorgung", "ruestung", "wohl", "ausbau", "volk"]   # tie order of the weakest track
ROMAN = ["0", "I", "II", "III"]
MAX = 3 * len(TRACKS)
LEITER_FILE = "leiter.json"
FOOD_I, DRINK_I, DRINK_II = 60, 60, 170
VOLK = (30, 50, 80)
RUESTUNG_FULL = (6, 10)
STRESS_III = 10
PHASES = (3, 5, 7)
DYING_DAYS = 3              # PATIENT_DYING within this many days is an acute floor
THIRST_DRINK_D, THIRST_DYING = 3, 50000   # as brief.thirst_items (BUG-402)
# avoidable death class -> the track it locks (old age never locks; siege only when the fort stood on R0)
LOCKS = {"durst_hunger": "versorgung", "patient": "wohl", "stimmung": "wohl", "graben_wasser": "ausbau",
         "belagerung": "volk"}
# the templates whose `breach:*` block or empty `bp sites` blocks a track's next step
SITE_TPLS = ("seal", "fortcore", "traps", "farms", "workshops", "hospital", "tombs", "cistern", "refuge_drink")


def _i(v) -> int | None:
    return v if isinstance(v, int) and not isinstance(v, bool) else None


def _o(v) -> dict:
    return v if isinstance(v, dict) else {}


def place(tpl: str, extra: str = "") -> str:
    return f"dfllm cmd bp.place tpl={tpl} site=S1" + (f" {extra}" if extra else "")


def want(token: str) -> str:
    return "dfllm cmd trade.want '" + json.dumps({"add": [token]}, separators=(",", ":")) + "'"


# ---------------------------------------------------------------- tracks: (raw level, need of the next level, command,
# template or trade token of the command, time_only)
def t_versorgung(s: dict, mem: dict, now: int) -> tuple:
    st = _o(s.get("stock"))
    food, drink = _i(st.get("food_d")), _i(st.get("drink_d"))
    if food is None or drink is None:
        return 0, "keine Vorratszahlen (state stock)", "dfllm status", None, True
    dcmd, dkey = ((want("drink"), "trade:drink") if st.get("bshort")
                  else (place("workshops", "only=Still"), "tpl:workshops"))
    if food < FOOD_I or drink < DRINK_I:
        if drink < DRINK_I:
            return 0, f"Trinken {drink}/{DRINK_I} d" + (f" ({st['dwhy']})" if st.get("dwhy") else ""), dcmd, dkey, False
        return 0, f"Essen {food}/{FOOD_I} d", place("farms"), "tpl:farms", False
    if drink < DRINK_II:
        return 1, f"Trinken {drink}/{DRINK_II} d" + (f" ({st['dwhy']})" if st.get("dwhy") else ""), dcmd, dkey, False
    held = held_days(mem, "drink", now)
    if held < YEAR // DAY:
        return 2, f"Trinken >= {DRINK_II} d ein Jahr halten ({held}/{YEAR // DAY} d)", "weiter brauen", None, True
    return 3, "", "", None, False


R0_CORE = ("no_outer", "no_inner", "bridge:", "levers:", "no_kern", "no_refuge")


def wehr_cmd(r: dict) -> tuple[str, str | None]:
    """The one command for the first R0 blocker (brief.line_unready lists them all)."""
    fails = [str(f) for f in r.get("fail") or []]
    if (_i(r.get("open")) or 0) > 0 or "open_perimeter" in fails:
        return place("seal", "at=last"), "tpl:seal"
    if any(f.startswith(R0_CORE) for f in fails):
        return "dfllm plan propose (fortcore vorn)", "tpl:fortcore"
    if any(f in ("audit", "audit_old") for f in fails):
        return "dfllm audit", None
    if "bypass" in fails:
        return place("seal", "at=audit"), "tpl:seal"
    if "traps_short" in fails:
        return place("traps"), "tpl:traps"
    if "refuge_dry" in fails:
        return place("refuge_drink"), "tpl:refuge_drink"
    if "mood_ws" in fails and isinstance(r.get("mws"), str) and r["mws"]:
        return r["mws"], "tpl:workshops"
    return "dfllm brief (SIEGE UNREADY next:)", None


def t_wehr(s: dict, mem: dict, now: int) -> tuple:
    r = s.get("ready")
    if not isinstance(r, dict) or _i(r.get("lvl")) is None:
        return 0, "keine Bereitschaft (state ready)", "dfllm status", None, True
    op = _i(r.get("open"))
    if op is None or op < 0:
        return 0, "Zugaenge ungeprueft", "dfllm audit", None, False
    if op > 0:
        return 0, f"{op} Zugang/Zugaenge ohne Tuer oder Bruecke", place("seal", "at=last"), "tpl:seal", False
    fails = [str(f) for f in r.get("fail") or []]
    if r["lvl"] < 1:
        cmd, key = wehr_cmd(r)
        return 1, "fehlt " + (",".join(fails[:4]) or "R0"), cmd, key, False
    short = [f for f in fails if f == "traps_short" or f.startswith("traps<")]
    if short or r.get("ts"):
        return 2, str(r.get("ts") or ",".join(short))[:80], place("traps"), "tpl:traps", False
    return 3, "", "", None, False


def t_ruestung(s: dict, mem: dict, now: int, metal_min: int = 50) -> tuple:
    m = s.get("mil")
    if not isinstance(m, dict):
        return 0, "keine Militaerzahlen (state mil)", "dfllm status", None, True
    kit = _o(m.get("kit"))
    sq, n, wpn, full = (_i(m.get("squads")) or 0, _i(kit.get("n")), _i(kit.get("weapon")), _i(kit.get("full")))
    if n is None or wpn is None or full is None:
        return 0, "keine Ausruestungszahlen (state mil.kit)", "dfllm status", None, True
    if sq < 1 or n < 1:
        return 0, "kein Trupp mit Soldaten", "dfllm plan propose (Phase stellt die Trupps)", None, False
    free = _o(m.get("free"))
    if wpn < n:
        fw = _i(free.get("weapon")) or 0
        return (0, f"{wpn}/{n} Soldaten mit Waffe" + (f", {fw} freie Waffen im Lager" if fw else ""), want("weapon"),
                "free:weapon" if fw >= n - wpn else "trade:weapon", False)
    if full < RUESTUNG_FULL[0]:
        fb = _i(free.get("body")) or 0
        return (1, f"{full}/{RUESTUNG_FULL[0]} voll ({n} Soldaten" + (f", {fb} freie Panzer im Lager)" if fb else ")"),
                want("armor"), "free:body" if fb >= min(n, RUESTUNG_FULL[0]) - full > 0 else "trade:armor", False)
    metal = _i(m.get("metal_pct")) or 0
    if full < RUESTUNG_FULL[1] or metal < metal_min:
        return (2, f"{full}/{RUESTUNG_FULL[1]} voll, Metall {metal}/{metal_min} %", want("armor:metal"),
                "trade:armor:metal", False)
    return 3, "", "", None, False


def t_volk(s: dict, mem: dict, now: int) -> tuple:
    cit = _i(_o(s.get("pop")).get("cit"))
    if cit is None:
        return 0, "keine Buergerzahl (state pop)", "dfllm status", None, True
    lvl = sum(1 for x in VOLK if cit >= x)
    if lvl >= 3:
        return 3, "", "", None, False
    hold = _o(s.get("pop")).get("hold")
    if isinstance(hold, str) and hold:
        return lvl, f"{cit}/{VOLK[lvl]} Buerger, Halt: {hold}", f"Halt beseitigen ({hold})", None, False
    return lvl, f"{cit}/{VOLK[lvl]} Buerger", "waechst mit Migranten", None, True


def t_wohl(s: dict, mem: dict, now: int) -> tuple:
    c, w = s.get("care"), s.get("water")
    if not isinstance(c, dict) or _i(c.get("ghosts")) is None or _i(c.get("corpses_old")) is None:
        return 0, "keine Pflegezahlen (state care)", "dfllm status", None, True
    g, co = c["ghosts"], c["corpses_old"]
    if g or co:
        free = _i(c.get("tombs_free")) or 0
        return (0, f"{g} Geister, {co} Tote unbestattet", "dfllm cmd tombs.repair" if free else place("tombs"),
                None if free else "tpl:tombs", False)
    w = _o(w)
    if not ((_i(w.get("hosp")) or 0) >= 1 and w.get("hosp_ok") == 1):
        if (_i(w.get("hosp")) or 0) >= 1:
            return 1, "Hospital ohne Wasser", "dfllm cmd inspect what=water_sources", None, False
        return 1, "kein Hospital mit Wasser", place("hospital"), "tpl:hospital", False
    pct = _i(c.get("stressed_pct"))
    held = held_days(mem, "stress", now)
    if pct is None or pct >= STRESS_III or held < YEAR // DAY:
        return 2, (f"Stress {pct if pct is not None else '?'} % < {STRESS_III} % ein Jahr ({held}/{YEAR // DAY} d)"), \
            "dfllm brief (stress)", None, pct is not None and pct < STRESS_III
    return 3, "", "", None, False


def _phase(s) -> int | None:
    ph = s.get("phase") if isinstance(s, dict) else s
    m = re.match(r"^P(\d)$", ph) if isinstance(ph, str) else None
    return int(m.group(1)) if m else None


def t_ausbau(s: dict, mem: dict, now: int) -> tuple:
    ph = _phase(s)
    if ph is None:
        return 0, "keine Phase (state phase)", "dfllm status", None, True
    lvl = sum(1 for x in PHASES if ph >= x)
    if lvl >= 3:
        return 3, "", "", None, False
    wait = _o(s.get("phw")).get("wait") or []
    return (lvl, f"Phase P{ph} -> P{PHASES[lvl]}" + (f", wartet: {','.join(str(x) for x in wait[:3])}" if wait else ""),
            "dfllm plan propose", None, False)


# ---------------------------------------------------------------- hold clocks (leiter.json "h")
def held_days(mem: dict, key: str, now: int) -> int:
    since = _i(_o(mem.get("h")).get(key))
    return max(0, (now - since) // DAY) if since is not None and isinstance(now, int) else 0


def update_holds(mem: dict, s: dict, now: int, evs: list[dict]) -> None:
    """Restart a clock on a sample below its line, on a gap of more than a season (or a clock going back) since the last
    sample, and (drink) on a STOCK_LOW drink_d event after its start."""
    h = mem.setdefault("h", {})
    last = _i(mem.get("ht"))
    gap_bad = last is None or now < last or now - last > SEASON
    st, c = _o(s.get("stock")), _o(s.get("care"))
    dd, pct = _i(st.get("drink_d")), _i(c.get("stressed_pct"))
    for key, ok in (("drink", dd is not None and dd >= DRINK_II), ("stress", pct is not None and pct < STRESS_III)):
        since = _i(h.get(key))
        if not ok:
            h[key] = None
        elif since is None or gap_bad:
            h[key] = now
        elif key == "drink" and any(e.get("type") == "STOCK_LOW" and _o(e.get("d")).get("key") == "drink_d"
                                    and (_i(e.get("tick")) or 0) > since for e in evs):
            h[key] = now
    mem["ht"] = now


# ---------------------------------------------------------------- locks, blocked, acute
def _level_at(evs: list[dict], etype: str, tick: int, now_val, conv) -> int | None:
    """The value an event-tracked level had at tick: the last change before it, else the 'from' of the first change
    after it, else the value now."""
    before = [e for e in evs if e.get("type") == etype and (_i(e.get("tick")) or 0) <= tick]
    if before:
        return conv(_o(before[-1].get("d")).get("to"))
    after = [e for e in evs if e.get("type") == etype and (_i(e.get("tick")) or 0) > tick]
    if after:
        return conv(_o(after[0].get("d")).get("from"))
    return conv(now_val)


def locks(s: dict, evs: list[dict], now: int, raw: dict, series: list[list[int]]) -> list[dict]:
    """Avoidable citizen deaths of the last game year whose cause the tool does not see fixed: {track, cls, tick, unit,
    cap, fix}. cap = the level the track may not rise above while locked."""
    st, w, c = _o(s.get("stock")), _o(s.get("water")), _o(s.get("care"))
    ready = _i(_o(s.get("ready")).get("lvl"))
    eps = wertung.sieges(evs, now)
    out: dict[str, dict] = {}
    for x in wertung.classified(evs, eps):
        if now - x["tick"] > YEAR:
            continue
        cls = x["cls"]
        track = LOCKS.get(cls)
        if track is None:
            continue
        old = now - x["tick"] > SEASON
        if cls == "durst_hunger":
            fixed = (_i(st.get("food_d")) or 0) >= FOOD_I and (_i(st.get("drink_d")) or 0) >= DRINK_I
            fix, cap = f"Essen und Trinken >= {FOOD_I} d", raw[track]
        elif cls == "patient":
            fixed = (_i(w.get("hosp")) or 0) >= 1 and w.get("hosp_ok") == 1
            fix, cap = "Hospital mit Wasser", min(raw[track], 1)
        elif cls == "stimmung":
            fixed = old and _i(c.get("moods")) == 0
            fix, cap = "keine offene Stimmung und eine Jahreszeit ohne Stimmungstod", min(raw[track], 1)
        elif cls == "graben_wasser":
            fixed = old
            fix = "eine Jahreszeit ohne Tod durch Graben/Wasser (nie an Wasser graben)"
            cap = _level_at(evs, "PHASE", x["tick"], s.get("phase"),
                            lambda v: sum(1 for p in PHASES if (_phase(v) or 0) >= p))
            cap = raw[track] if cap is None else min(raw[track], cap)
        else:                                          # belagerung: only when the fort stood on R0
            lv = _level_at(evs, "READY_CHANGE", x["tick"], ready, lambda v: _i(v) if _i(v) is not None else 0)
            if lv is None or lv >= 1:
                continue
            fixed = ready is not None and ready >= 1
            pop = wertung._pop_at(sorted(series), x["tick"]) if series else None
            cap = raw[track] if pop is None else min(raw[track], sum(1 for v in VOLK if pop >= v))
            fix = "R1 (Belagerungstote auf R0)"
        if fixed:
            continue
        prev = out.get(track)
        if prev is None or x["tick"] > prev["tick"]:
            out[track] = {"track": track, "cls": cls, "tick": x["tick"], "unit": x["unit"], "cap": cap, "fix": fix}
    return [out[t] for t in PRIO if t in out]


def blocked_evidence(save_dir: Path, s: dict, evs: list[dict], now: int, key: str | None, hours: int) -> str:
    """Tool evidence that the command's template / trade token cannot work now, '' without evidence."""
    if not key:
        return ""
    kind, _, what = key.partition(":")
    if kind == "free":                                  # the gear lies in the stock and the soldiers do not take it
        fr = _i(_o(_o(s.get("mil")).get("free")).get(what)) or 0
        return f"{fr} freie {what} im Lager, die Soldaten tragen sie nicht (state mil.free)" if fr else ""
    if kind == "trade":
        nb = _o(s.get("trade")).get("nb") or []
        if what in nb or what.split(":")[0] in nb:
            return f"Haendler hatten nie {what} (state trade.nb)"
        st = _o(s.get("stock"))
        if what.endswith(":metal") and st.get("metal") == "explore" and not (_i(st.get("ore")) or 0):
            return "kein Erz, Metallweg explore (state stock.metal)"
        return ""
    st = _o(s.get("stock"))
    if what == "traps" and st.get("mroute") == "no stone":
        return "keine Mechanismen: kein Stein (state stock.mroute)"
    for e in reversed(evs):
        t = _i(e.get("tick")) or 0
        if now - t > SEASON:
            break
        d = _o(e.get("d"))
        if e.get("type") == "PROJECT_BLOCKED" and d.get("tpl") == what and str(d.get("why", "")).startswith("breach:"):
            return f"{what} {d['why']} ({fmt_tick(t)})"
    if hours > 0:
        cut = time.time() - hours * 3600
        for p in (Path(save_dir) / "cli.log",):
            try:
                lines = p.read_text(encoding="utf-8", errors="replace").splitlines()[-400:]
            except OSError:
                continue
            for ln in reversed(lines):
                f = ln.split("\t")
                if len(f) < 5 or f[2] != "bp.sites":
                    continue
                try:
                    if int(f[0]) < cut:
                        break
                    tpl = json.loads(f[3]).get("tpl")
                except (ValueError, AttributeError):
                    continue
                if tpl == what:
                    if re.search(r"\bfree 0\b", f[4]):
                        return f"bp sites {what}: {f[4]}"
                    break
    return ""


def acute(s: dict, evs: list[dict], now: int) -> tuple[str, str] | None:
    """The acute floor: (duty, command) or None."""
    mode = s.get("mode")
    if mode in ("SIEGE", "BREACH"):
        return f"{mode}: der Kernel haelt den Lockdown, Pflicht nach PLAYBOOK, kein Ausbau", "dfllm status"
    if _o(s.get("alarm")).get("lock") == 1:
        return "Lockdown: Pflicht nach PLAYBOOK, kein Ausbau", "dfllm status"
    st, w = _o(s.get("stock")), _o(s.get("water"))
    dd = _i(st.get("drink_d"))
    if dd is not None and dd <= THIRST_DRINK_D and ((_i(w.get("thirst_max")) or 0) >= THIRST_DYING or any(
            e.get("type") == "DEATH" and _o(e.get("d")).get("cause") == "dehydrated"
            and now - (_i(e.get("tick")) or 0) < 28 * DAY for e in evs)):
        return f"Zwerge verdursten (Trinken {dd} d)", "dfllm cmd inspect what=reach"
    for e in reversed(evs):
        t = _i(e.get("tick")) or 0
        if now - t > DYING_DAYS * DAY:
            break
        if e.get("type") == "PATIENT_DYING":
            return f"Patient stirbt: {str(e.get('msg', ''))[:80]}", "dfllm events --cls A"
    r = _o(s.get("ready"))
    if mode == "PEACE" and ((_i(r.get("open")) or 0) > 0 or "open_perimeter" in (r.get("fail") or [])):
        return f"Perimeter offen ({r.get('pw') or str(r.get('open', '?')) + ' Zugaenge'})", place("seal", "at=last")
    return None


# ---------------------------------------------------------------- records (leiter.json)
def read_mem(save_dir: Path) -> dict:
    doc = files.read_json(Path(save_dir) / LEITER_FILE, retry=False)
    return doc if isinstance(doc, dict) and not schema.validate("leiter", doc) else {}


def run_key(save: str, rx: str) -> str:
    try:
        m = re.match(rx, save)
    except re.error:
        m = None
    return m.group(1) if m else save


def siblings(save_dir: Path, rx: str) -> list[tuple[str, dict]]:
    """(name, leiter.json) of the other save folders of the same run (same run key) in the runtime root."""
    me = Path(save_dir)
    key = run_key(me.name, rx)
    out = []
    try:
        dirs = [d for d in me.parent.iterdir() if d.is_dir() and d != me]
    except OSError:
        return []
    for d in dirs:
        if run_key(d.name, rx) == key and key != d.name:
            m = read_mem(d)
            if m:
                out.append((d.name, m))
    return out


# ---------------------------------------------------------------- the ladder
def compute(save_dir: Path, state: dict | None = None, evs: list[dict] | None = None, write: bool | None = None) -> dict:
    """The ladder now: {ok, sum, tracks: {t: {raw, eff, need, cmd, key, time, blocked, gate, lock}}, acute, locks,
    next, open, best, run_best, lost, prev, now, y}. write None = config leiter.records."""
    save_dir = Path(save_dir)
    cfg = wertung.config()["leiter"]
    s = state if state is not None else files.read_state(save_dir)
    if not isinstance(s, dict) or not isinstance(s.get("t"), dict):
        return {"ok": False, "why": "kein Zustand (state.a/b.json)"}
    t = s["t"]
    now = _i(t.get("abs"))
    if now is None:
        now = (_i(t.get("y")) or 0) * YEAR + (_i(t.get("tick")) or 0)
    if evs is None:
        evs = wertung.load_events(save_dir, 0, now - YEAR - SEASON)
    mem = read_mem(save_dir)
    update_holds(mem, s, now, evs)
    fns = {"versorgung": t_versorgung, "wehr": t_wehr, "volk": t_volk, "wohl": t_wohl, "ausbau": t_ausbau,
           "ruestung": lambda a, b, c: t_ruestung(a, b, c, cfg["ruestung_metal_pct"])}
    tr: dict[str, dict] = {}
    for k in TRACKS:
        raw, need, cmd, key, timeonly = fns[k](s, mem, now)
        tr[k] = {"raw": raw, "eff": raw, "need": need, "cmd": cmd, "key": key, "time": timeonly, "blocked": "",
                 "gate": "", "lock": None}
    if cfg["gates"]:                                      # Volk II needs Wehr II; Volk III needs Wehr III + Ruestung II
        v = tr["volk"]
        if v["raw"] >= 1 and tr["wehr"]["raw"] < 2:
            v["gate"] = "braucht Wehr II"
            v["eff"] = min(v["raw"], 1)
        elif v["raw"] >= 2 and (tr["wehr"]["raw"] < 3 or tr["ruestung"]["raw"] < 2):
            v["gate"] = "braucht Wehr III und Ruestung II"
            v["eff"] = min(v["raw"], 2)
    series = wertung.read_series(save_dir)
    lk = locks(s, evs, now, {k: tr[k]["eff"] for k in TRACKS}, series) if cfg["locks"] else []
    for x in lk:
        tr[x["track"]]["lock"] = x
        tr[x["track"]]["eff"] = min(tr[x["track"]]["eff"], x["cap"])
    for k in TRACKS:
        if tr[k]["eff"] < 3:
            tr[k]["blocked"] = blocked_evidence(save_dir, s, evs, now, tr[k]["key"], cfg["blocked_hours"])
    total = sum(tr[k]["eff"] for k in TRACKS)
    ac = acute(s, evs, now)
    cands = sorted((k for k in TRACKS if tr[k]["eff"] < 3 and not tr[k]["blocked"] and not tr[k]["gate"]),
                   key=lambda k: (tr[k]["time"], tr[k]["eff"], PRIO.index(k)))
    weakest = min((k for k in TRACKS if not tr[k]["blocked"]), key=lambda k: (tr[k]["eff"], PRIO.index(k)), default=None)
    # records
    y = _i(t.get("y")) or now // YEAR
    best = _o(mem.get("best"))
    blv = {k: max(_i(_o(best.get("lv")).get(k)) or 0, tr[k]["eff"]) for k in TRACKS}
    if total > (_i(best.get("sum")) or -1):
        best = {"sum": total, "t": now, "y": y}
    best["lv"] = blv
    mem["best"] = best
    mem["last"] = {"sum": total, "t": now, "wall": int(time.time())}
    mem.setdefault("born", int(time.time()))
    lost = [k for k in TRACKS if blv[k] > tr[k]["eff"]]
    sib = siblings(save_dir, cfg["run_key_re"])
    run_best = max([(best["sum"], best["y"], save_dir.name)] + [(_i(_o(m.get("best")).get("sum")) or 0,
                                                                  _i(_o(m.get("best")).get("y")) or 0, n) for n, m in sib])
    mem.setdefault("t0", now)
    young = 0 <= now - (_i(mem.get("t0")) or now) < YEAR       # a new fort (its first game year under the ladder)
    prev = max(((n, m) for n, m in sib if (_i(_o(m.get("last")).get("wall")) or 0) <= mem["born"]),
               key=lambda nm: _i(_o(nm[1].get("last")).get("wall")) or 0, default=None) if young else None
    if write if write is not None else cfg["records"]:
        mem["v"] = 2
        try:
            files.write_json_atomic(save_dir / LEITER_FILE, mem)
        except OSError:
            pass
    return {"ok": True, "sum": total, "tracks": tr, "acute": ac, "locks": lk, "cands": cands, "weakest": weakest,
            "best": best, "run_best": run_best, "lost": lost, "now": now, "y": y, "mem": mem,
            "prev": (prev[0], _i(_o(prev[1].get("last")).get("sum")) or 0) if prev else None}


def _lvl(k: str, tr: dict) -> str:
    return f"{NAME[k]} {ROMAN[tr[k]['eff']]}"


def lines(lz: dict) -> list[str]:
    """LEITER / NAECHST / OFFEN-GESPERRT."""
    if not lz.get("ok"):
        return [f"LEITER ?: {lz.get('why', '?')}"]
    tr = lz["tracks"]
    rb = lz["run_best"]
    other = f" {wertung.fort_key(rb[2])}" if rb[2] != lz.get("save", rb[2]) else ""
    l1 = f"LEITER {lz['sum']}/{MAX}" + (f" (Rekord {rb[0]} y{rb[1]}{other})" if rb[0] > lz["sum"] else "")
    if lz["weakest"]:
        l1 += f" | schwaechste: {_lvl(lz['weakest'], tr)}"
    if lz["lost"]:
        l1 += " | VERLOREN " + ", ".join(f"{NAME[k]} {ROMAN[lz['best']['lv'][k]]}" for k in lz["lost"])
    if lz.get("prev"):
        l1 += f" | Vorfort {wertung.fort_key(lz['prev'][0])} fiel auf {lz['prev'][1]}"
    if lz["acute"]:
        l2 = f"NAECHST Pflicht: {lz['acute'][0]} -> {lz['acute'][1]}"
    elif lz["locks"]:
        x = lz["locks"][0]
        k = x["track"]
        l2 = (f"NAECHST {NAME[k]} gesperrt ({wertung.LABEL[x['cls']]} {fmt_tick(x['tick'])}): {x['fix']}"
              + (f" -> {tr[k]['cmd']}" if tr[k]["cmd"] and not tr[k]["time"] else ""))
    elif lz["cands"]:
        k = lz["cands"][0]
        l2 = f"NAECHST {NAME[k]} {ROMAN[tr[k]['eff'] + 1]}: {tr[k]['need']} -> {tr[k]['cmd']}"
    else:
        l2 = "NAECHST -: jede Spur auf III, blockiert oder gesperrt"
    parts = []
    first = lz["cands"][0] if not lz["acute"] and not lz["locks"] and lz["cands"] else None
    rest = [k for k in lz["cands"] if k != first and not tr[k]["time"]]
    if rest:
        k = rest[0]
        parts.append(f"OFFEN {NAME[k]} {ROMAN[tr[k]['eff'] + 1]}: {tr[k]['need']} -> {tr[k]['cmd']}")
    for k in TRACKS:
        if tr[k]["lock"] and not (lz["locks"] and lz["locks"][0]["track"] == k and not lz["acute"]):
            parts.append(f"GESPERRT {NAME[k]} ({wertung.LABEL[tr[k]['lock']['cls']]}: {tr[k]['lock']['fix']})")
        if tr[k]["gate"]:
            parts.append(f"GESPERRT {NAME[k]} {ROMAN[tr[k]['eff'] + 1]} ({tr[k]['gate']})")
        if tr[k]["blocked"]:
            parts.append(f"BLOCKIERT {NAME[k]} {ROMAN[tr[k]['eff'] + 1]}: {tr[k]['blocked']} -> FR")
    return [l1, l2] + (([" | ".join(parts)]) if parts else ["OFFEN -"])


def brief_lines(save_dir: Path, state: dict | None = None) -> list[str]:
    """The three brief lines (config leiter.brief), never raising."""
    try:
        cfg = wertung.config()
        if not (cfg["leiter"]["on"] and cfg["leiter"]["brief"]):
            return []
        if cfg["wertung"]["series"]:
            wertung.update_series(save_dir, cfg)
        lz = compute(save_dir, state)
        lz["save"] = Path(save_dir).name
        return lines(lz)
    except Exception as e:                                # noqa: BLE001 - the brief must not die on the ladder
        return [f"LEITER ?: Fehler {type(e).__name__}: {e}"[:160]]


def status_line(save_dir: Path, state: dict | None = None) -> str:
    """The LEITER line for `status` (no pop series update, never raising)."""
    try:
        cfg = wertung.config()
        if not (cfg["leiter"]["on"] and cfg["leiter"]["brief"]):
            return ""
        lz = compute(save_dir, state)
        lz["save"] = Path(save_dir).name
        return lines(lz)[0]
    except Exception as e:                                # noqa: BLE001
        return f"LEITER ?: Fehler {type(e).__name__}: {e}"[:160]


# ---------------------------------------------------------------- session
def start_session(save_dir: Path) -> str:
    lz = compute(save_dir, write=False)
    if not lz.get("ok"):
        return f"leiter --start: {lz.get('why')}"
    mem = lz["mem"]
    kit = _o(_o((files.read_state(save_dir) or {}).get("mil")).get("kit"))
    mem["sess"] = {"t": lz["now"], "n": files.last_event_n(save_dir), "wall": int(time.time()), "sum": lz["sum"],
                   "lv": {k: lz["tracks"][k]["eff"] for k in TRACKS}, "full": _i(kit.get("full")) or 0}
    mem["v"] = 2
    files.write_json_atomic(Path(save_dir) / LEITER_FILE, mem)
    return f"SITZUNG Start {fmt_tick(lz['now'])}: Leiter {lz['sum']}/{MAX}"


def session_lines(save_dir: Path) -> tuple[list[str], int]:
    mem = read_mem(save_dir)
    ss = _o(mem.get("sess"))
    if _i(ss.get("t")) is None or _i(ss.get("n")) is None:
        return ["SITZUNG: keine gestartet (dfpilot leiter --start am Sitzungsbeginn)"], 1
    lz = compute(save_dir)
    if not lz.get("ok"):
        return [f"SITZUNG: {lz.get('why')}"], 1
    tr = lz["tracks"]
    ch = [f"{NAME[k]} {ROMAN[_i(_o(ss.get('lv')).get(k)) or 0]}->{ROMAN[tr[k]['eff']]}" for k in TRACKS
          if (_i(_o(ss.get("lv")).get(k)) or 0) != tr[k]["eff"]]
    kit = _o(_o((files.read_state(save_dir) or {}).get("mil")).get("kit"))
    f0, f1 = _i(ss.get("full")) or 0, _i(kit.get("full")) or 0
    if f0 != f1:
        ch.append(f"Ruestung {f0}/{RUESTUNG_FULL[0]}->{f1}/{RUESTUNG_FULL[0]}")
    evs = wertung.load_events(save_dir, ss["n"])
    ds = wertung.classified(evs, wertung.sieges(wertung.load_events(save_dir, 0, ss["t"] - SEASON), lz["now"]))
    by: dict[str, int] = {}
    for x in ds:
        by[x["cls"]] = by.get(x["cls"], 0) + 1
    dt = f"Tote {len(ds)}" + (f" ({wertung._top(by)})" if by else "")
    out = [f"SITZUNG {fmt_tick(ss['t']).split(' ')[0]}->{fmt_tick(lz['now']).split(' ')[0]}: Leiter {ss.get('sum', 0)}->"
           f"{lz['sum']} | " + (", ".join(ch) if ch else "keine Stufe bewegt") + f" | {dt}"]
    bl = [f"{NAME[k]} {ROMAN[tr[k]['eff'] + 1]} ({tr[k]['blocked']})" for k in TRACKS if tr[k]["blocked"]]
    if bl:
        out.append("blockiert: " + "; ".join(bl) + " -> FR")
    if lz["lost"]:
        out.append("VERLOREN " + ", ".join(f"{NAME[k]} {ROMAN[lz['best']['lv'][k]]}" for k in lz["lost"]))
    return out, 0


# ---------------------------------------------------------------- CLI
def run(args, save_dir: Path) -> int:
    cfg = wertung.config()
    if not cfg["leiter"]["on"]:
        print("leiter: off (config/wertung.json leiter.on)")
        return 2
    if args.start:
        print(start_session(save_dir))
        return 0
    if args.sitzung:
        out, rc = session_lines(save_dir)
        print("\n".join(out))
        return rc
    if cfg["wertung"]["series"]:
        wertung.update_series(save_dir, cfg)
    lz = compute(save_dir)
    lz["save"] = Path(save_dir).name
    if args.json:
        print(json.dumps({k: v for k, v in lz.items() if k != "mem"}, sort_keys=True, default=str))
        return 0 if lz.get("ok") else 1
    print("\n".join(lines(lz)))
    if lz.get("ok") and args.alle:
        for k in TRACKS:
            x = lz["tracks"][k]
            print(f"  {NAME[k]} {ROMAN[x['eff']]}" + (f" (roh {ROMAN[x['raw']]})" if x["raw"] != x["eff"] else "")
                  + (f": naechste Stufe {x['need']} -> {x['cmd']}" if x["eff"] < 3 else ""))
    return 0 if lz.get("ok") else 1


def add_parser(sub) -> None:
    p = sub.add_parser("leiter", help="Engpass-Leiter: six tracks I-III, the one next command, session balance")
    p.add_argument("--start", action="store_true", help="store the session start (tick, events, levels)")
    p.add_argument("--sitzung", action="store_true", help="the balance since --start")
    p.add_argument("--alle", action="store_true", help="also one line per track")
    p.add_argument("--json", action="store_true")
