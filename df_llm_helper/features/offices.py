"""FEATURE-001: offices watch (`python -m df_llm_helper offices`).

Are the fortress offices (nobles menu) filled by someone who can do the job? Run 5, year 120/121: the broker was dead
and the mayor holding the office was in a strange mood (a caravan was missed); after the siege captain of the guard,
militia commander and chief medical dwarf were assigned to dead units, manager/bookkeeper/broker were empty.

- status:  one `claude/pilot_offices status` call (read only) -> per required office (offices.required, MAYOR when the
           fort has one) the state ok / empty / dead / unfit (mood, child, stress, wounded, prisoner, depot unreachable,
           not a soldier) and a successor with a score (skills for the job, not in a squad, healthy, low stress, not a
           busy doctor while patients exist). Six offices get six distinct candidates.
- --apply: only with an exception-register entry OFFICES (player consent; appointing is a nobles-menu action but
           changes the fort): `claude/aemter vacate <CODE>` + `claude/aemter assign <CODE> <unit>` for dead/unfit holders,
           `assign` alone for empty offices (aemter logs the old state to tools/out/aemter-log.json). Elected offices
           (MAYOR) are never assigned. Without --apply only the commands are printed.
- watch:   one evaluation with the state-change rule: a changed set of problems writes ONE warning for the digest
           (crit for dead/empty -> exactly one wake line, warn for unfit); an unchanged state stays silent.
- trade precheck (trade_precheck): before PAUSE the trade automaton asks for the broker; dead, unusable (mood,
           prisoner, child, wounded, depot unreachable) or empty without any candidate -> the trade fails at once with
           the offices message instead of timing out in BROKER (BUG-221/222).
Lua part: lua/pilot_offices.lua (LIVE-UNTESTED).
"""
from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path

__all__ = ["KEY", "DEFAULTS", "STATUS_CMD", "ELECTED", "holder_state", "score", "required_codes", "OfficeRow",
           "evaluate", "summary_line", "office_lines", "apply_commands", "track", "broker_problem", "trade_precheck",
           "Offices", "register", "check_hook"]

KEY = "offices"
STATUS_CMD = "claude/pilot_offices status"
DEFAULTS = {
    "required": ["MANAGER", "BOOKKEEPER", "BROKER", "CAPTAIN_OF_THE_GUARD", "MILITIA_COMMANDER", "CHIEF_MEDICAL_DWARF"],
    "mayor_if_present": True,       # MAYOR is required when the fort has the position (elected: never assigned)
    "stress_max": 75000,            # holder/candidate above this is about to snap (claude/gesund: ~75000 tantrum)
    "every_s": 300,                 # check_hook interval (~1200 game ticks at normal speed are far shorter)
    "apply_states": ["empty", "dead"],   # --apply fills these; unfit holders only with --replace-unfit
    "on_demand": [],                # offices that may stay empty (e.g. ["BROKER"] when handel prep appoints per caravan)
    "trade_precheck": True,
    "in_check": True,
}
ELECTED = frozenset({"MAYOR"})
SOLDIER_OFFICES = frozenset({"CAPTAIN_OF_THE_GUARD", "MILITIA_COMMANDER"})
CIVIL_OFFICES = frozenset({"MANAGER", "BOOKKEEPER", "BROKER", "CHIEF_MEDICAL_DWARF"})
WEAPONS = ("AXE", "SWORD", "MACE", "HAMMER", "SPEAR", "CROSSBOW")
# skill weights per office (job_skill names, nominal level 0..20)
WEIGHTS = {
    "MANAGER": {"ORGANIZATION": 3, "JUDGING_INTENT": 1},
    "BOOKKEEPER": {"RECORD_KEEPING": 3, "ORGANIZATION": 1},
    "BROKER": {"NEGOTIATION": 3, "APPRAISAL": 2, "JUDGING_INTENT": 2},
    "CAPTAIN_OF_THE_GUARD": {"LEADERSHIP": 3, "MELEE_COMBAT": 1, "DISCIPLINE": 1, "MILITARY_TACTICS": 1},
    "MILITIA_COMMANDER": {"LEADERSHIP": 3, "MILITARY_TACTICS": 2, "MELEE_COMBAT": 1, "DISCIPLINE": 1},
    "CHIEF_MEDICAL_DWARF": {"DIAGNOSE": 3, "SURGERY": 2, "SET_BONE": 2, "SUTURE": 1, "DRESS_WOUNDS": 1},
}
# broker states that make a trade impossible (stress alone does not stop him from trading)
BROKER_BLOCKING = ("mood", "prisoner", "child", "wounded", "depot unreachable")


# ------------------------------------------------------------------ pure rules
def holder_state(code: str, h: dict | None, cfg: dict) -> tuple[str, str]:
    """(state, reason) of an office holder: ok | empty | dead | unfit (reason mood/child/prisoner/wounded/stress/
    depot unreachable/not a soldier)."""
    if not h:
        return "empty", ""
    if h.get("dead") or not h.get("alive", False):
        return "dead", ("gone" if h.get("gone") and not h.get("dead") else "")
    if h.get("adult") is False:
        return "unfit", "child"
    if h.get("prisoner"):
        return "unfit", "prisoner"
    if h.get("mood"):
        return "unfit", "mood"
    if h.get("patient") or h.get("cant_stand"):
        return "unfit", "wounded"
    if int(h.get("stress") or 0) > int(cfg.get("stress_max", 75000)):
        return "unfit", "stress"
    if code == "BROKER" and h.get("depot_reach") is False:
        return "unfit", "depot unreachable"
    if code in SOLDIER_OFFICES and not (h.get("squad") or h.get("squad_leader")):
        return "unfit", "not a soldier"
    return "ok", ""


def score(u: dict, code: str, cfg: dict, *, patients: int = 0) -> float | None:
    """Successor score for an office; None = not eligible (dead, child, prisoner, mood, patient, stress above the
    limit, not a citizen, in a squad for a civil office). Higher is better; pure (tested without the game)."""
    if not u.get("alive", True) or u.get("adult") is False or u.get("prisoner") or u.get("mood"):
        return None
    if u.get("patient") or u.get("cant_stand") or u.get("citizen") is False:
        return None
    stress = int(u.get("stress") or 0)
    if stress > int(cfg.get("stress_max", 75000)):
        return None
    if code in CIVIL_OFFICES and u.get("squad"):
        return None                                    # drafted soldiers stay soldiers
    sk = u.get("skills") or {}
    s = float(sum(w * int(sk.get(k) or 0) for k, w in WEIGHTS.get(code, {}).items()))
    if code in SOLDIER_OFFICES:
        s += max((int(sk.get(w) or 0) for w in WEAPONS), default=0)
        s += 5 if u.get("squad") else -3
        s += 3 if u.get("squad_leader") else 0
    if code == "BROKER" and u.get("depot_reach") is False:
        return None
    if code in ("MANAGER", "BOOKKEEPER") and u.get("pick"):
        s -= 6                                         # no heavy labor: keep the miners digging
    if code != "CHIEF_MEDICAL_DWARF" and patients > 0 and int(u.get("care") or 0) > 0:
        s -= 4                                         # a caretaker stays with the patients
    s -= max(0, stress) / 25000.0
    s -= 0.5 * min(int(u.get("wounds") or 0), 6)       # scars count too (care.py): small penalty only
    return round(s, 2)


def required_codes(data: dict, cfg: dict) -> list[str]:
    codes = list(cfg.get("required") or [])
    present = {p.get("code") for p in _list(data.get("positions"))}
    if cfg.get("mayor_if_present", True) and "MAYOR" in present and "MAYOR" not in codes:
        codes.append("MAYOR")
    return codes


@dataclass
class OfficeRow:
    code: str
    state: str                       # ok | empty | dead | unfit | n/a (position not available in this fort yet)
    reason: str = ""
    holder: dict | None = None
    suggest: dict | None = None      # {"id", "name", "prof", "score"}
    on_demand: bool = False

    @property
    def problem(self) -> bool:
        return self.state in ("empty", "dead", "unfit") and not (self.state == "empty" and self.on_demand)

    def text(self) -> str:
        if self.state == "unfit":
            return f"{self.code} unfit ({self.reason}{', ' + _who(self.holder, True) if self.holder else ''})"
        if self.state == "dead":
            return f"{self.code} {'gone' if self.reason == 'gone' else 'dead'} ({_who(self.holder, True)})"
        return f"{self.code} {self.state}" + (" (on demand)" if self.on_demand and self.state == "empty" else "")


def _list(v) -> list:
    if isinstance(v, dict):                 # an empty Lua table may arrive as {}
        return list(v.values())
    return [x for x in v or [] if isinstance(x, dict)]


def _short(name) -> str:
    from ..care import short_name
    return short_name(name, 20)


def _first(name) -> str:
    return (_short(name).split() or ["?"])[0]


def _who(h: dict | None, first: bool = False) -> str:
    if not h:
        return "?"
    n = (_first(h.get("name")) if first else _short(h.get("name"))) if h.get("name") else ""
    return n or (f"unit {h['id']}" if h.get("id") is not None else f"histfig {h.get('hf', '?')}")


def evaluate(data: dict, cfg: dict) -> list[OfficeRow]:
    """All required offices with state and (for problems) a distinct successor each."""
    c = {**DEFAULTS, **(cfg or {})}
    by_code: dict[str, dict] = {}
    for p in _list(data.get("positions")):
        by_code.setdefault(str(p.get("code")), p)
    rows = []
    for code in required_codes(data, c):
        p = by_code.get(code)
        if p is None:
            rows.append(OfficeRow(code, "n/a"))
            continue
        st, why = holder_state(code, p.get("holder"), c)
        rows.append(OfficeRow(code, st, why, p.get("holder"), on_demand=code in (c.get("on_demand") or [])))
    # candidates: living citizens, not holding one of the offices that stay as they are
    cits = _list(data.get("citizens"))
    keep = {r.holder.get("id") for r in rows if r.state == "ok" and r.holder}
    used = set(keep)
    patients = int(data.get("patients") or 0)
    for r in rows:
        if not r.problem or r.code in ELECTED:
            continue
        best = None
        for u in cits:
            if u.get("id") in used or (r.holder and u.get("id") == r.holder.get("id")):
                continue
            if any(o != r.code for o in u.get("offices") or []):
                continue                                # holds another office already
            sc = score(u, r.code, c, patients=patients)
            if sc is None:
                continue
            key = (sc, -int(u.get("id") or 0))
            if best is None or key > best[0]:
                best = (key, u)
        if best:
            u = best[1]
            used.add(u.get("id"))
            r.suggest = {"id": u.get("id"), "name": _short(u.get("name")), "prof": u.get("prof") or "?",
                         "score": best[0][0]}
    return rows


def summary_line(rows: list[OfficeRow]) -> str:
    """'Offices: 6/6 filled' or 'OFFICES: BROKER dead (Adil), MANAGER empty -> suggest MANAGER 4621 Kol (Mechanic)'."""
    avail = [r for r in rows if r.state != "n/a"]
    probs = [r for r in avail if r.problem]
    filled = sum(1 for r in avail if r.state == "ok")
    if not probs:
        return f"Offices: {filled}/{len(avail)} filled"
    head = "OFFICES: " + ", ".join(r.text() for r in probs)
    one = len([r for r in probs if r.suggest]) == 1
    sug = [("" if one else f"{r.code} ") + f"{r.suggest['id']} {_first(r.suggest['name'])} ({r.suggest['prof']})"
           for r in probs if r.suggest]
    none = [r.code for r in probs if not r.suggest and r.code not in ELECTED]
    tail = (" -> suggest " + ", ".join(sug)) if sug else ""
    if none:
        tail += f"; no candidate for {', '.join(none)}"
    return head + tail


def office_lines(rows: list[OfficeRow]) -> list[str]:
    out = [summary_line(rows)]
    for r in rows:
        if r.state == "n/a":
            out.append(f"  {r.code}: position not available in this fort")
            continue
        holder = "-"
        if r.holder:
            holder = _who(r.holder)
            if r.holder.get("name") and r.holder.get("id") is not None:
                holder = f"{r.holder['id']} {holder}"
        s = f"  {r.code}: {r.state}" + (f" ({r.reason})" if r.reason else "") + f", holder {holder}"
        if r.suggest:
            s += f" -> {r.suggest['id']} {r.suggest['name']} ({r.suggest['prof']}, score {r.suggest['score']})"
        elif r.problem and r.code in ELECTED:
            s += " (elected: never assigned here)"
        out.append(s)
    return out


def apply_commands(rows: list[OfficeRow], cfg: dict, *, replace_unfit: bool = False) -> list[str]:
    """claude/aemter commands for the problems --apply may fix (live 03.10.: vacate + assign for dead holders)."""
    states = set(cfg.get("apply_states") or DEFAULTS["apply_states"]) | ({"unfit"} if replace_unfit else set())
    out = []
    for r in rows:
        if not r.problem or not r.suggest or r.code in ELECTED or r.state not in states:
            continue
        if r.state in ("dead", "unfit"):
            out.append(f"claude/aemter vacate {r.code}")
        out.append(f"claude/aemter assign {r.code} {r.suggest['id']}")
    return out


def _sig(rows: list[OfficeRow]) -> str:
    probs = [[r.code, r.state, r.reason, (r.holder or {}).get("id")] for r in rows if r.problem]
    return json.dumps(probs, sort_keys=True)


def track(store, now: float, rows: list[OfficeRow], *, record: bool = True) -> tuple[bool, list[str]]:
    """State-change rule: (changed, lines). A changed problem set writes one warning (unique key per state, so the
    wake filter sees exactly one new row): crit when an office is dead/empty, warn when only unfit. Unchanged: []."""
    sig = _sig(rows)
    prev = store.get("offices.sig")
    if prev == sig:
        return False, []
    line = summary_line(rows)
    probs = [r for r in rows if r.problem]
    if record:
        store.set("offices.sig", sig)
        if probs:
            lvl = "crit" if any(r.state in ("dead", "empty") for r in probs) else "warn"
            key = "offices:" + hashlib.sha1(sig.encode("utf-8")).hexdigest()[:10]
            store.warn(now, "offices", key, line, lvl)
    if not probs and prev is None:
        return True, [line]                    # first run, all ok: one line, no warning
    return True, [line] if probs else [line + " (resolved)"]


def broker_problem(data: dict | None, cfg: dict) -> str:
    """'' when a trade can start, else the reason (the trade automaton fails early with it)."""
    if not isinstance(data, dict) or not data.get("ok"):
        return ""                                  # not readable: never block a trade on a missing script
    rows = [r for r in evaluate(data, {**cfg, "required": ["BROKER"]}) if r.code == "BROKER"]
    if not rows or rows[0].state in ("ok", "n/a"):
        return ""
    r = rows[0]
    if r.state == "unfit" and r.reason not in BROKER_BLOCKING:
        return ""
    if r.state == "empty" and r.suggest:
        return ""                                  # claude/handel prep appoints a broker when the caravan comes
    fix = (f"; candidate {r.suggest['id']} {_first(r.suggest['name'])}" if r.suggest else "; no candidate") + \
        " -> python -m df_llm_helper offices --apply (register entry OFFICES), then python -m df_llm_helper trade reset"
    return f"offices: {r.text()}{fix}"


def trade_precheck(client, cfg: dict | None, flow_state: str, status: dict | None) -> str:
    """Called by the trade automaton callers: only in IDLE with a caravan at the depot (one extra read call)."""
    c = {**DEFAULTS, **(cfg or {})}
    if not c.get("trade_precheck", True) or flow_state != "IDLE":
        return ""
    cars = [x for x in (status or {}).get("caravans") or [] if isinstance(x, dict)]
    if not any(x.get("state") == "AtDepot" for x in cars):
        return ""
    try:
        r = client.run(STATUS_CMD)
    except Exception:
        return ""
    return broker_problem(r.json if r.ok and isinstance(r.json, dict) else None, c)


# ------------------------------------------------------------------ runner
class Offices:
    def __init__(self, client, store, clock, cfg: dict | None = None, registry=None):
        self.client, self.store, self.clock, self.registry = client, store, clock, registry
        self.cfg = {**DEFAULTS, **(cfg or {})}

    def read(self) -> dict | None:
        r = self.client.run(STATUS_CMD)
        j = r.json if r.ok and isinstance(r.json, dict) else None
        return j if j and j.get("ok") else None

    def apply(self, rows: list[OfficeRow], *, apply: bool, replace_unfit: bool = False) -> list[str]:
        cmds = apply_commands(rows, self.cfg, replace_unfit=replace_unfit)
        if not cmds:
            return ["Nothing to assign" + (" (unfit holders: --replace-unfit)" if any(
                r.problem and r.state == "unfit" for r in rows) and not replace_unfit else "")]
        if not apply:
            return [f"[dry] {c}" for c in cmds] + ["(plan only - add --apply; needs a register entry OFFICES)"]
        if self.registry is None or not self.registry.allows("OFFICES"):
            return ["Refused: assigning offices needs the player's consent in the register: python -m df_llm_helper "
                    "exception add OFFICES --local --reason 'fill dead/empty offices' --ja '<quote>'"] + \
                   [f"[dry] {c}" for c in cmds]
        now = self.clock.now().epoch
        out = []
        for c in cmds:
            r = self.client.run(c)
            j = r.json if isinstance(r.json, dict) else {}
            ok = bool(r.ok and not j.get("error"))
            self.store.log_action(now, "offices", "offices", "assign", c.split()[2], c, False, ok,
                                  str(j.get("error") or j.get("done") or "")[:200])
            out.append(("ok   " if ok else "ERROR ") + c + (f" ({j.get('error')})" if j.get("error") else ""))
            if not ok and c.split()[1] == "vacate":
                out.append("stopped: vacate failed, the office is left as it was")
                break
        return out


# ------------------------------------------------------------------ CLI + check
def _cmd(args) -> int:
    if args.file:
        try:
            data = json.loads(Path(args.file).read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as e:
            print(f"offices: --file not readable ({e})")
            return 2
        cfg = dict(DEFAULTS)
        rows = evaluate(data, cfg)
        print(json.dumps([r.__dict__ for r in rows], ensure_ascii=False) if args.json else "\n".join(office_lines(rows)))
        return 1 if any(r.problem for r in rows) else 0
    from ..cli import _pilot          # lazy: no cli import at module level (import cycles)
    p = _pilot(args)
    o = Offices(p.client, p.store, p.clock, p.cfg.get(KEY, {}), registry=getattr(p.client, "registry", None))
    data = o.read()
    if data is None:
        print(f"offices: {STATUS_CMD} not readable (pilot_offices installed? python -m df_llm_helper install-lua)")
        return 2
    rows = evaluate(data, o.cfg)
    if args.json:
        print(json.dumps([r.__dict__ for r in rows], ensure_ascii=False))
    elif args.action == "watch":
        _, lines = track(p.store, p.clock.now().epoch, rows, record=True)
        print("\n".join(lines) if lines else "Offices: no change")
    else:
        print("\n".join(office_lines(rows)))
    if args.apply or args.dry_plan:
        print("\n".join(o.apply(rows, apply=bool(args.apply), replace_unfit=bool(args.replace_unfit))))
    return 1 if any(r.problem for r in rows) else 0


def register(sub) -> None:
    s = sub.add_parser("offices", help="offices watch (nobles menu): holders alive and fit, successors, --apply")
    s.add_argument("action", nargs="?", default="status", choices=["status", "watch"])
    s.add_argument("--apply", action="store_true",
                   help="assign suggested successors via claude/aemter (register entry OFFICES required)")
    s.add_argument("--plan", dest="dry_plan", action="store_true", help="print the aemter commands --apply would send")
    s.add_argument("--replace-unfit", action="store_true", help="--apply also replaces unfit holders (mood, stress ...)")
    s.add_argument("--file", default=None, help="recorded pilot_offices status JSON instead of the game")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=_cmd)


def check_hook(pilot, report, dry: bool) -> list[str]:
    cfg = {**DEFAULTS, **(pilot.cfg.get(KEY, {}) or {})}
    now = pilot.clock.now().epoch
    last = pilot.store.get("offices.last")
    if last is not None and now - float(last) < float(cfg["every_s"]):
        return []
    if not dry:
        pilot.store.set("offices.last", now)
    data = Offices(pilot.client, pilot.store, pilot.clock, cfg).read()
    if data is None:
        return []                       # script missing: `offices` itself says so
    _, lines = track(pilot.store, now, evaluate(data, cfg), record=not dry)
    return lines
