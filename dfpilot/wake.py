"""`dfllm follow`: tail events.jsonl, rate-limit class-A wakes, print one wake line (<= 150 tokens) per wake.
`dfllm audit`: the follower's audit job, run once on demand (FR-65).

DESIGN §8 limits: <= 1 wake per type per 5 min, bursts merged within 60 s, <= 6 wakes per hour.
Held events are never dropped: they wait (merged) for the next allowed wake. BUG-240: URGENT_GAME kinds (YEAR_REVIEW,
MOOD_RISK, a drink/food decision, ...) wait at most one game day; the hourly limit prints one HELD line per 10 min.
BUG-238: one follow per save (<save>/.follow.lock; a second one exits unless --takeover). Class B/C events do
not wake; the follower acts on two of them without the LLM:
  SNAPSHOT_READY purpose=audit -> inspect manifest -> bp.topo.audit(snap, manifest) -> inbox `audit`
                                  (also with --no-auto: the audit changes nothing in the fort, it is the readiness
                                  gate's input; Run 10 ran `follow --no-auto` and stayed `audit never` for its whole
                                  life. --no-audit switches it off. Snapshots `dfllm audit` requested (ids AUDIT_PREFIX)
                                  are left to it)
  PROJECT_REQUEST tpl=tombs    -> snapshot purpose=sites -> best free site (cmd.place) -> bp.place
  PROJECT_REQUEST tpl=workshops -> the same (care asks when a strange mood finds no workshop); why=fishery (economy:
                                  raw fish and no fishery, Run 11) -> only the fishery (p.add Fishery, every moodable
                                  type skipped) at prio 1, also while the fort manifest still lists a destroyed one
                                  (BUG-038: the kernel asks only while none stands); why=mandatory (runner, FR-76:
                                  a reclaimed fort lacks Carpenters, Masons, Craftsdwarfs, Still or Kitchen) -> only
                                  the missing types of d.types, at prio 1; why=slabs (economy, BUG-133: ghosts
                                  and no mason's workshop, d.types [Masons]) -> the same; why=manager (BUG-231),
                                  why=missing (BUG-267), gear (BUG-270), well;
                                  why=mood with d.types (BUG-283: the shops a strange mood and its materials need) -> the same
  PROJECT_REQUEST tpl=farms why=food -> the same with p.plots = n (1-4) at prio 1 (economy asks when the farm
                                  tiles fall short of the citizens and food is low or falling; live L5)
  PROJECT_REQUEST tpl=bedrooms why=mood_rock|rock -> a bedrooms dig (p.n = n, 1-6) at prio 1: a strange mood waits
                                  for a boulder (care), or the free stone is below what the rock orders and walls
                                  want while the miners have nothing to dig (economy, Run 11)
  AUDIT (B) with a bypass wall -> Run 10 (the bypass finding stood for months, the 41 traps stayed unused): in PEACE,
                                  when the audit names a wall (bypass, refuge on the attack path; bp.topo.choke)
                                  that no seal project builds yet, the seal (tpl seal, p.at audit) is placed the
                                  same way (a player's blueprint, never refused for touching a project)
  PLAN_EXHAUSTED phase P0/P1   -> the phase's first proj deliverable without a project (plans/year1.json),
                                  placed the same way (S1, or 'same' for a later fortcore stage): the fort
                                  never idles while it waits for an LLM (live L0/L1: a year idled, a dwarf
                                  starved); the PLAN_EXHAUSTED wake still goes out, so the LLM reviews it
The outbox reply of every automatic command is read; a refusal or no reply within AUTO_TIMEOUT_S
wakes as AUTO_FAIL (a refused bp.place is rolled back). Unread replies are pruned after 10 min.
Only wake lines go to stdout (one line = one Monitor notification); details go to <save>/cli.log.
Supervisor alerts (<runtime>/supervise.json, each logged alert key) wake as SUPERVISE (STATUS §6.8, live L1). The key
`needs_click` (K2/BUG-099: the restart chain could not load the save, DF waits at the title screen) wakes as NEEDS_CLICK,
also for a follow that starts while the alarm stands (supervise's last pass, at most 10 minutes old, still carries it).
A failed `dfllm save` (<save>/quicksave.json with ok 0 newer than the last one seen; Run 10: a quicksave after a graphics
crash wrote nothing) wakes as QUICKSAVE_FAILED, also when it failed while follow was not running (within an hour).
`dfllm audit [--snap ID]`: request a fresh audit snapshot (or take an audit snapshot of this boot), then the same
manifest check, bp.topo.audit and `audit` verb as follow (by:'follow': the result is computed, never typed; the hook
still refuses a hand-written `dfllm cmd audit`); it prints the result and the kernel's reply.
"""
from __future__ import annotations

import inspect
import os
import re
import sys
import time
from pathlib import Path
from typing import Callable

from . import files, paths, schema
from . import plan as plan_mod
from .events import clip, est_tokens, fmt_tick

WAKE_TOKENS = 150
WAKE_TYPES = {t for t, (c, _, _) in schema.EVENTS.items() if c == "A"}
SYNTH = {"HB_STALE", "AUTO_FAIL", "SUPERVISE", "QUICKSAVE_FAILED", "NEEDS_CLICK", "PLAN_AUTO"}   # follower's own wake reasons (not kern events)
# Run 9: an army walked in while SIEGE_START/INVASION waited in the digest; they and the interrupts come right
# after BREACH and wake at once (URGENT: no merge wait, no hourly limit, one per type per URGENT_REPEAT_S)
PRIO = ["BREACH", "SIEGE_START", "INVASION", "INTRUDER", "ARRIVAL", "PREDATOR", "LOCKDOWN", "SIEGE_DEEP",
        "BRIDGE_DESTROYED", "GATE_FAIL",
        "TRANSFORM", "CURSED",                # BUG-115: a were-form among the citizens, then a curse (interrupts)
        "DEATHS_3PLUS", "NO_DEPOT", "CURSE_MOON",
        "NEEDS_CLICK",                        # K2: no fort runs at all; nothing else in the burst can be acted on first
        "PATIENT_DYING", "PATIENTS_OUT", "MOOD_CRITICAL",     # I1: a patient or a mood dwarf at the death line comes before the housekeeping types
        "DEATHS_PREVENTABLE", "KERN_FAULT", "HB_STALE", "SUPERVISE", "QUICKSAVE_FAILED",
        "PAUSED_BY_DF",                       # FR-94: the game stands (a load, a popup); one `dfllm cmd resume` runs it again
        "SIEGE_END",
        "DRILL_FAIL", "BURROW_SHRUNK", "SIEGE_UNREADY", "PERF_DEGRADED", "DECISION_NEEDED", "SEAL_STUCK",
        "PROJECT_BLOCKED", "PLAN_EXHAUSTED", "PLAN_AUTO", "YEAR_REVIEW", "AUTO_FAIL"]
URGENT = {"BREACH", "SIEGE_START", "INVASION", "LOCKDOWN"} | set(schema.INTERRUPTS)
URGENT_REPEAT_S = 60
_IRQ_NEXT = "dfllm ack; dfllm status (the kernel already locked down)"
NEXT = {"YEAR_REVIEW": "dfllm plan propose y.json, fix its ERROR lines, plan check, plan apply",
        "PLAN_EXHAUSTED": "dfllm plan propose",
        "SIEGE_START": "dfllm status (the kernel already locked down)", "INVASION": _IRQ_NEXT, "ARRIVAL": _IRQ_NEXT,
        "INTRUDER": _IRQ_NEXT, "PREDATOR": _IRQ_NEXT, "LOCKDOWN": _IRQ_NEXT, "DEATHS_3PLUS": "dfllm ack; dfllm brief",
        "NO_DEPOT": "dfllm ack; place a trade depot (bp.place)",
        # BUG-115 (Run 14 y707: a curse nobody read, 23 werecavies): the recipe is the brief's "## curse" section
        "CURSED": "tell Gordon at once; dfllm ack; dfllm cmd inspect what=curse; before the full moon lock ALL the cursed in "
                  "ONE room (burrow + forbidden door, by hand in DF); never kill a citizen without his yes",
        "TRANSFORM": "tell Gordon at once; dfllm ack; the were-form is an enemy among the citizens: keep the others away "
                     "(a locked door), kill only on his yes (DECISION_NEEDED curse_kill); inspect what=curse; watch the bitten",
        "CURSE_MOON": "tell Gordon: lock the cursed (ids in the line) in ONE room now, before the full moon "
                      "(burrow + forbidden door, by hand in DF)",
        # FR-94 (Run 14 note 100): the pause key, once per 60 s, only pause:df / pause:popup; the reply names the popups it read
        "PAUSED_BY_DF": "dfllm cmd resume (the reply names what it released and every popup it read); then dfllm status",
        "DECISION_NEEDED": "ask Gordon in chat, then config/decisions.yaml", "KERN_FAULT": "dfllm doctor",
        "PERF_DEGRADED": "dfllm doctor", "HB_STALE": "dfllm doctor", "AUTO_FAIL": "dfllm doctor",
        "SUPERVISE": "dfllm supervise --once --dry-run",
        # K2/BUG-099: the restart chain loaded nothing; the msg names the save, the DFHack version and the screen rows
        "NEEDS_CLICK": "tell Gordon at once (DF waits at the title screen, no fort runs): he clicks Continue and the save "
                       "named; or python tools/embark/embark.py load <save> after reading the rows; then dfllm doctor",
        # Run 10: the game is NOT saved; a restart would load the older save
        "QUICKSAVE_FAILED": "tell Gordon at once (the game is not saved); dfllm save again in 2 min or Esc > Save",
        "GHOSTS": "dfllm cmd inspect '{\"what\":\"tombs\"}', then tombs.repair",
        # FR-65: R0 in PEACE; close the listed ways in, build the missing fortcore pieces, then re-audit
        "SIEGE_UNREADY": "dfllm cmd inspect '{\"what\":\"entrances\"}'; dfllm cmd bp.place tpl=seal site=S1 at=last "
                         "(a door per open way in); then dfllm audit",
        # Run 11: seal at=last reads SEAL_LEAK (a wall per leak) and REFUGE_FAIL (its open entrances) too
        "SEAL_LEAK": "dfllm cmd inspect '{\"what\":\"entrances\"}'; dfllm cmd bp.place tpl=seal site=S1 at=last "
                     "(walls); tell Gordon",
        "REFUGE_FAIL": "dfllm cmd inspect '{\"what\":\"refuge\"}'; dfllm cmd bp.place tpl=seal site=S1 at=refuge "
                       "(its stair hatch and the line's tiles); next plan: refuge pieces first",
        # BUG-107: a potential refuge holds less food/drink than refuge.floor_pct % of the siege need; d.cmd is the existing
        # command that builds the store (stockroom in Kern+, refuge_drink in the refuge); d.total_f/total_d: if the whole fort
        # holds too little, make food/drink first
        "REFUGE_STOCK": "dfllm cmd inspect '{\"what\":\"refuge\"}'; send the line's d.cmd (stockroom / refuge_drink) when the "
                        "fort's own stock covers it, else food and drink first; tell Gordon",
        "HOSPITAL_DRY": "dfllm cmd inspect '{\"what\":\"water_sources\"}'",
        # BUG-034: the kernel already removed the dry hospital's zones; water (a cistern) comes before a new hospital
        "HOSPITAL_REMOVED": "tell Gordon; dfllm cmd inspect '{\"what\":\"water_sources\"}'; next plan: water before "
                            "a hospital (plan check refuses one without it)",
        # BUG-054: a patient at thirst 60,000; the kernel scales the Orderlies detail itself, the line names the state
        # BUG-104/106: the line names why no GiveWater job runs; what=hospital lists every gap of the wound care
        "PATIENT_DYING": "tell Gordon at once; dfllm cmd inspect '{\"what\":\"hospital\"}' (gaps), then water_sources "
                         "(hospital water, caregivers, GiveWater jobs); nothing by hand that the kernel does not do",
        "MOOD_RISK": "dfllm brief; supply the missing class (never cancel the mood)",
        # BUG-063: thirst past 50,000: the dwarf and his workshop are named; material first, the drink nook is the kernel's
        # BUG-282: also without a workshop, a material none in the fort, still waiting or near DF's insanity line (d.left
        # days); the kernel already asked for the shops (d.ask) and collect webs (d.webs)
        "MOOD_CRITICAL": "tell Gordon (unit, what is missing, days left); dfllm brief (MOOD line); supply the missing class "
                         "(trade.want, dig, butcher); never cancel the mood",
        # FR-64: >= 2 citizens dehydrated or starved within a month: access, not supply, as a rule
        "DEATHS_PREVENTABLE": "dfllm cmd inspect '{\"what\":\"reach\"}', then refuge; patients: water_sources",
        # BUG-015: a lockdown door that does not hold its forbidden flag (the kernel tries it once more itself)
        "LOCKDOWN_PARTIAL": "dfllm status; a wall or a second door for that opening (bp.place)",
        # BUG-023: tool detail members without pick/axe; the fair-play remedy is the player's (RULES 7); Run 11: d.bk/blk
        # name the blocker, key=tools gives every record of the diagnosis
        "TOOL_BLOCKED": "dfllm cmd inspect '{\"what\":\"workload\",\"key\":\"tools\"}' (d.bk names the blocker), "
                        "then tell Gordon what d.tell says (RULES 7; BUG-116: d.care = the hospital waiting for the pick)",
        # BUG-030: the kernel already acted (no pulls for a destroyed bridge; the deep defense); tell the player
        "BRIDGE_DESTROYED": "dfllm status; tell Gordon; the kernel rebuilds it in quiet PEACE, or replaces it by wall + "
                            "door after perimeter.stop_after losses to building destroyers (BUG-048: no question); "
                            "nothing tactical",
        # BUG-048: replaced = bridges now a wall + door; wait = lost bridges waiting for quiet PEACE
        "PERIMETER_BROKEN": "dfllm status; dfllm cmd inspect what=perimeter; tell Gordon; the kernel rebuilds lost "
                            "walls, doors and bridges in quiet PEACE; nothing tactical",
        "SIEGE_DEEP": "dfllm status (civilians in the refuge, squads in the core); tell Gordon; nothing tactical",
        # BUG-096/FR-80 (Run 14 note 70): the kernel paints Kern+ / the refuge again in quiet modes (d.fix repair | wait);
        # ask (no tile set known) comes with DECISION_NEEDED burrow_gone; off = burrow.guard.repair_per_day 0
        "BURROW_SHRUNK": "dfllm status (burrows: tiles, cause load|runtime, painted again); tell Gordon; d.cause load = "
                         "after a load, d.rid != d.id = made again; fix ask: paint it in the burrows screen",
        # Run 11: a dig broke into a cavern; the kernel plugs an explore shaft itself (failed/none: by hand)
        "CAVERN_PLUG": "tell Gordon (queued: the kernel walls the shaft; failed/none: a constructed wall by hand); "
                       "bp.cancel the explore without undo",
        # FR-98: the kernel's cavern sweep ended (it walls the shaft itself); seal_failed: the shaft is open
        "CAVERN_SWEEP_END": "tell Gordon (d.why, killed, lost); seal_failed: a constructed wall on d.pos by hand at once; "
                            "dfllm cmd inspect what=cavern; the next sweep waits a season (two after losses)",
        # Run 11 siege 8: an open seal built nothing for stuck_days; the other projects run again
        "SEAL_STUCK": "tell Gordon the open way in; dfllm cmd inspect '{\"what\":\"workload\"}' (material); no "
                      "material: logs, a stone dig; a refused tile: bp.cancel, then bp.place tpl=seal at=last or by hand; "
                      "d.wait (BUG-041): a job nobody has the labor for (Gordon: work details) or a piece no citizen "
                      "reaches (a wall on another tile); BUG-044: d.wait names who suspends a door's job (buildingplan: "
                      "the door item is missing; suspendmanager: jobs.release preventblocking=false; DF: the cancel "
                      "reason), a door still unbuilt 2 days later is replaced by a wall (SEAL_WALLED) when the citizens "
                      "keep another way"}
# FR-86: follow applied a minimal plan itself after plan.stale_apply_years years without a `plan apply`
NEXT["PLAN_AUTO"] = ("tell Gordon (nobody approved a plan for years; follow applied the minimal one: seal, tombs, hospital, "
                     "food/drink, refuge, no star phase; after each quiet year one phase more, BUG-132; `ERROR held back` "
                     "= what it left out: fix those); then dfllm plan propose y.json, plan check, plan apply replaces it")
SUPERVISE_EVERY_S = 15                         # supervise.json read cadence
SUPERVISE_FRESH_S = 3600                       # alerts logged longer ago than this never wake
CLICK_KEY = "needs_click"                      # supervise.CLICK_KEY (K2): the alarm for a save only a human can load now
CLICK_PASS_S = 600                             # a standing needs_click wakes a follow that starts late if supervise ran this recently
HB_STALE_S = 300
FOLLOW_HB_EVERY_S = 10                         # FR-29: follow's own heartbeat (<save>/.follow.hb)
AUTO_TIMEOUT_S = 60
TOMBS_COOLDOWN_S = 600
WAIVE_COOLDOWN_S = 3600                         # BUG-300: one phase.waive farms per hour of follow at most
CODE = files.code_stamp()                      # BUG-042: the dfpilot code this follow process imported
PLACE_KEYS = ("tombs", "workshops", "starter", "mood_rock", "rock", "farms", "seal", "fishery", "farmers",
              "mandatory", "slabs",           # automatic placements (one each); BUG-133: slabs = the masons for the ghosts
              "busy",                         # BUG-224: busy = one more Carpenters/Masons beside a full one
              "mood")                         # BUG-283: the shops a strange mood waits for (care's typed request)
SEAL_HINT = ("dfllm cmd bp.place tpl=seal site=S1 at=audit (walls the audit's bypass; follow places it itself "
             "unless --no-auto); then dfllm audit")
AUTO_REQUESTS = ("tombs", "workshops")            # PROJECT_REQUEST templates follow places itself
AUTO_PHASES = ("P0", "P1")                    # PLAN_EXHAUSTED auto-start only for the basic infrastructure
PRUNE_EVERY_S = 60
PLAN_CHECK_EVERY_S = 300                       # FR-86: how often follow looks at the age of the applied plan
PLAN_AUTO_KEYS = ("first_y", "tried_y", "applied_y")
AUDIT_PREFIX = "aud"                           # snapshot ids of `dfllm audit` (it audits them itself, follow does not)
AUDIT_SNAP_S = 180                             # `dfllm audit`: least seconds to wait for its fresh snapshot (BUG-160)
AUDIT_SNAP_BPS = 16000                         # BUG-160: snapshot bytes per second of scan, half the live rate (Trussroads:
                                               # 1.4 MB snapshot, 323k tiles in 40 s = ~35 KB/s)
AUDIT_SNAP_MAX_S = 900                         # BUG-160: never wait longer by default (a dead kernel)
AUDIT_SNAP_NOTE_S = 30                         # BUG-160: one progress line after this long without the snapshot
ERR_EVERY_S = 60                               # stderr 'poll error' at most once per minute


# BUG-240 (Run 15 Guildcleans y374: at timestream 500 a real hour is ~4 game years; after 6 wakes follow said nothing for
# about a game year while MOOD_RISK (the Fey mood that died), YEAR_REVIEW and SEAL_STUCK waited in gate.pending): these types
# are never held by the hourly limit longer than URGENT_GAME_TICKS of game time (merged first, one per type per
# URGENT_REPEAT_S); DECISION_NEEDED only for the ids in URGENT_DECISIONS (a fort running out of drink or food, a thirsty one)
URGENT_GAME = {"YEAR_REVIEW", "MOOD_RISK", "MOOD_CRITICAL", "DEATH", "STRANDED", "PATIENT_DYING"}
URGENT_DECISIONS = {"drink_low", "food_low", "thirst", "patient_thirst"}
URGENT_GAME_TICKS = schema.TICKS["DAY"]
HELD_NOTE_S = 600                              # BUG-240: the 'HELD' line for wakes the hourly limit holds, at most this often


def urgent_game(e: dict) -> bool:
    """BUG-240: an event of a kind that must not wait for the hourly limit longer than one game day."""
    t = e.get("type")
    if t == "DECISION_NEEDED":
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        return d.get("id") in URGENT_DECISIONS
    return t in URGENT_GAME


def _tick_of(v) -> int | None:
    return v if isinstance(v, int) and not isinstance(v, bool) else None


class WakeGate:
    """Pending class-A events -> at most one wake line per allowed slot."""

    def __init__(self, per_type_s: float = 300, merge_s: float = 60, quiet_s: float = 10, per_hour: int = 6):
        self.per_type_s, self.merge_s, self.quiet_s, self.per_hour = per_type_s, merge_s, quiet_s, per_hour
        self.pending: dict[str, dict] = {}     # type -> {c: count, n0: first n, e: latest event, t0: first game tick, ug}
        self.first = self.last = None          # wall time of the first / latest pending arrival
        self.type_last: dict[str, float] = {}  # type -> wall of its last wake
        self.wakes: list[float] = []           # walls of wakes (last hour)
        self.held_said = -1e18                 # BUG-240: wall of the last HELD line

    def add(self, e: dict, now: float) -> None:
        t = e["type"]
        p = self.pending.setdefault(t, {"c": 0, "n0": e.get("n"), "e": e})
        p["c"] += 1
        p["e"] = e
        if p["n0"] is None:
            p["n0"] = e.get("n")
        if urgent_game(e):                     # BUG-240: the game tick it first waited at
            p["ug"] = 1
            if _tick_of(p.get("t0")) is None:
                p["t0"] = _tick_of(e.get("tick"))
        self.first = now if self.first is None else self.first
        self.last = now

    def _game_due(self, now: float, tick) -> bool:
        """BUG-240: an URGENT_GAME pending type that has waited one game day (and did not wake within URGENT_REPEAT_S)."""
        cands = [(t, p) for t, p in self.pending.items() if p.get("ug") and _tick_of(p.get("t0")) is not None
                 and now - self.type_last.get(t, -1e18) >= URGENT_REPEAT_S]
        if not cands:
            return False
        cur = _tick_of(tick() if callable(tick) else tick)
        return cur is not None and any(cur - p["t0"] >= URGENT_GAME_TICKS for _, p in cands)

    def blocked(self, now: float, tick=None) -> str | None:
        """Why the pending burst cannot wake now (None = it can). An URGENT type wakes at once (no merge wait, no
        hourly limit) unless the same type woke within URGENT_REPEAT_S; it takes the rest of the burst along.
        BUG-240: `tick` (the current game tick, or a function that reads it) lets an URGENT_GAME type past the hourly
        limit and the type cooldown once it has waited URGENT_GAME_TICKS; without a tick only wall time counts."""
        if not self.pending:
            return "empty"
        if any(t in URGENT and now - self.type_last.get(t, -1e18) >= URGENT_REPEAT_S for t in self.pending):
            return None
        if now - self.last < self.quiet_s and now - self.first < self.merge_s:
            return "merging"
        self.wakes = [w for w in self.wakes if now - w < 3600]
        limit = len(self.wakes) >= self.per_hour
        cool = all(now - self.type_last.get(t, -1e18) < self.per_type_s for t in self.pending)
        if (limit or cool) and tick is not None and self._game_due(now, tick):
            return None
        if limit:
            return "hourly limit"
        if cool:
            return "type cooldown"
        return None

    def flush(self, now: float, tick=None) -> dict[str, dict] | None:
        if self.blocked(now, tick):
            return None
        out, self.pending, self.first, self.last = self.pending, {}, None, None
        self.wakes.append(now)
        for t in out:
            self.type_last[t] = now
        return out

    def held_note(self, now: float, state=None) -> str | None:
        """BUG-240: while the hourly limit holds a burst, one 'HELD' line at most every HELD_NOTE_S: how many events of which
        types wait and when the next wake slot opens (silence must never look like a quiet fort)."""
        if not self.pending or now - self.held_said < HELD_NOTE_S or self.blocked(now) != "hourly limit":
            return None
        self.held_said = now
        state = state() if callable(state) else state
        t = (state or {}).get("t") or {}
        when = fmt_tick(t.get("abs", t["y"] * schema.TICKS["YEAR"] + t["tick"])) if t.get("y") is not None else "?"
        types = sorted(self.pending, key=_prio)
        n = sum(p.get("c", 1) for p in self.pending.values())
        ns = [p["n0"] for p in self.pending.values() if isinstance(p.get("n0"), int)]
        wait = max(0, int((min(self.wakes) + 3600 - now) // 60) + 1) if self.wakes else 0
        kinds = ", ".join(f"{ty}{' x%d' % self.pending[ty]['c'] if self.pending[ty].get('c', 1) > 1 else ''}" for ty in types)
        line = (f"HELD {when} | {n} event{'s' if n != 1 else ''} held by the wake limit ({self.per_hour}/h): {kinds} | "
                f"next wake in ~{wait} min" + (f"; now: dfllm events --cls A --since {min(ns) - 1}" if ns else ""))
        return clip(line, WAKE_TOKENS)

    def to_json(self) -> dict:
        return {"pending": self.pending, "first": self.first, "last": self.last, "type_last": self.type_last,
                "wakes": self.wakes}

    def load(self, d: dict) -> None:
        if isinstance(d, dict):
            self.pending = d.get("pending") or {}
            self.first, self.last = d.get("first"), d.get("last")
            self.type_last = d.get("type_last") or {}
            self.wakes = d.get("wakes") or []
            for p in self.pending.values():    # BUG-240: a burst saved by an older follow carries no game tick yet
                if isinstance(p, dict) and isinstance(p.get("e"), dict) and urgent_game(p["e"]):
                    p["ug"] = 1
                    p.setdefault("t0", _tick_of(p["e"].get("tick")))


def _prio(t: str) -> int:
    return PRIO.index(t) if t in PRIO else len(PRIO)


def next_hint(etype: str, e: dict) -> str:
    """The wake line's `next:` for an event: NEXT[type]; a SIEGE_UNREADY whose audit fails name a wall (Run 10) gets
    the seal that builds it."""
    d = e.get("d") if isinstance(e.get("d"), dict) else {}
    if etype == "SIEGE_UNREADY" and any(_WALL.search(str(f)) for f in d.get("afails") or []):
        return SEAL_HINT
    if etype == "SIEGE_UNREADY" and "refuge_dry" in (d.get("fails") or []):
        return REFUGE_DRY_HINT
    if etype == "SIEGE_UNREADY" and "hospital_out" in (d.get("fails") or []):
        return HOSPITAL_OUT_HINT
    if etype == "SIEGE_UNREADY" and "office" in (d.get("fails") or []):
        return OFFICE_HINT
    if etype == "SIEGE_UNREADY" and "mood_ws" in (d.get("fails") or []):
        return MOOD_WS_HINT
    if etype == "DECISION_NEEDED" and d.get("id") == "manager_office":
        return MANAGER_HINT
    if etype == "DECISION_NEEDED" and d.get("id") == "bridge_rebuild":
        return rebuild_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "intruder_sortie":
        return sortie_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "confined_need":
        return need_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "kill_lone_intruder":
        return lone_hint(d)
    if etype == "PATIENTS_OUT":
        return patients_hint(d)
    if etype == "PAUSED_BY_DF" and d.get("deny"):
        return ("tell Gordon at once: a popup with a threat or curse word holds the game; resume refuses it, he reads and "
                "clicks it in DF (dfllm cmd inspect what=curse if it names a curse)")
    if etype == "DECISION_NEEDED" and d.get("id") == "curse_kill":
        return ("ask Gordon: a kill order on the were-form (dfllm cmd squad.sortie, approve:true is the logged decision; "
                "a squad and its target position) or keep them apart in a locked room; no answer = no kill")
    if etype == "PROJECT_BLOCKED" and d.get("park") is not None and d.get("proj"):
        return park_hint(d)
    return NEXT.get(etype, "dfllm brief")


def sortie_hint(d: dict) -> str:
    """BUG-065: an intruder holds a lockdown. A harmless one: the lockdown ends by itself at the limit, the sortie is the
    faster way; a dangerous one past the limit: the lockdown stays while it is near, the sortie is the way out."""
    cmd = d.get("cmd")
    how = f"; to send the squad: {cmd} (approve:true is a logged decision)" if cmd else "; no squad to send"
    if d.get("hl"):
        return f"tell Gordon{how}; otherwise the lockdown ends by itself at its limit (confine.max_days)"
    return (f"tell Gordon: the lockdown stays while this one is near{how} (only if the squad can win); "
            "dfllm status shows the cause")


def lone_hint(d: dict) -> str:
    """M3 (BUG-112, notes 94 and 96): a harmless lone intruder holds a SIEGE/BREACH for days. The kernel kills one inside Kern+
    itself after confine.kill_hours when a squad stands at sortie.worn; this is the question when it is still there."""
    cmd = d.get("cmd")
    how = f"; to send the squad now: {cmd} (approve:true is a logged decision)" if cmd else "; no squad to send"
    kill = f" (the kernel's own kill order: {d['kill']})" if d.get("kill") else ""
    return (f"tell Gordon{how}{kill}; otherwise the kernel releases it at confine.max_days when the soldiers stand at "
            "their stations (LOCKDOWN_END limit); dfllm events --type SORTIE says whether the soldiers arrived, killed it or "
            "stood beside it (not_attackable: DF does not treat it as an enemy)")


PATIENTS_OUT_HINT = ("patients lie outside the alert burrow and cannot walk there: only a rescue moves them. Tell Gordon; "
                     "recipe for the next peace: plan the hospital inside Kern+ or Tiefe+ next to accepted water (dfllm bp "
                     "sites hospital names the water), then remove the old zones (readiness hospital_out)")


def patients_hint(d: dict) -> str:
    """M3 (note 94 c): a class-A wake for patients outside the burrow the civ alert confines to, with the recipe."""
    return PATIENTS_OUT_HINT + (f" ({d['n']} of {d['patients']} patients, units {d.get('units', [])[:5]})" if "patients" in d else "")


def need_hint(d: dict) -> str:
    """BUG-065: a mood dwarf or patient confined by the lockdown is in need (thirst/hunger)."""
    return (f"tell Gordon: {d.get('why', 'citizen')} {d.get('unit', '?')} (thirst {d.get('thirst', '?')}) is confined by the "
            "lockdown; with nothing dangerous near the kernel ended it, else STRANDED relax is the rescue for the "
            "others and a sortie against the cause (dfllm status) ends the lockdown")


def park_hint(d: dict) -> str:
    """BUG-037: a project blocked for good was parked (no slot, no pause, the keepers free); the kernel never cancels it.
    Cancelling it without undo keeps what it built (an explore's shaft stays watched)."""
    return (f"tell Gordon; once he agrees: dfllm cmd bp.cancel '{{\"proj\":\"{d['proj']}\"}}' (no undo), then place "
            "it again elsewhere if still wanted")


def rebuild_hint(d: dict) -> str:
    """BUG-030 rebuild policy: the kernel stopped rebuilding a bridge the building destroyers keep breaking; the
    player's answer is a verb (rebuild) or a plan (wall, a second outer gate), leaving it is the default."""
    b = d.get("bridge") or "O1"
    return (f"ask Gordon: rebuild (dfllm cmd bridge.rebuild '{{\"bridge\":\"{b}\"}}'), wall it or a second "
            "outer gate (plan), or leave it (default)")


_WALL = re.compile(r"\bwall -?\d+,-?\d+,-?\d+ (floor|ramp)\b")
# Run 11 (siege 8: Tiefe+ had no drink): readiness R0 refuge_dry; a dry refuge holds the citizens only in a breach
# BUG-040: a bucket-fed cistern without revealed open water in reach stays dry (plan check warns, CISTERN_DRY)
# FR-69 (y477: 1199 drinks in one Kern+ pile, none in Tiefe+): the refuge drink store first (plan propose drafts it)
REFUGE_DRY_HINT = ("the refuge has no drink: next plan its drink store (tpl refuge_drink, FR-69: plan propose drafts "
                   "it) or a well/cistern there with a fill source (BUG-040)")
# BUG-036 (Run 11 siege 9: 7 patients killed in their hospital beds outside the refuge): readiness R0 hospital_out;
# BUG-040 (y453: Tiefe+ had no accepted water): then Kern+ next to the water
HOSPITAL_OUT_HINT = ("the hospital lies outside the core: plan it next to accepted water inside Tiefe+, or in Kern+ when "
                     "Tiefe+ has none (bp sites hospital names the water), then remove the old zones: status names the "
                     "blocking zone and its dfllm cmd hospital.retire (BUG-131)")


# BUG-233 (live Guildcleans y373): the manager validates nothing; nothing here asks for a click at a workshop (the kernel
# adds chair, table, doors, beds and blocks as workshop tasks itself after orders.bypass_days, MANAGER_BYPASS)
MANAGER_HINT = ("tell Gordon once; the kernel adds the office's chair and table (and the doors, beds, blocks projects wait "
                "for) as workshop tasks itself (MANAGER_BYPASS); no office zone: dfllm cmd bp.place tpl=office site=S1")

# BUG-055 (Run 14 y577: the CHIEF_MEDICAL_DWARF office stood vacant for good; Run 11 note 25: squads without a leader):
# readiness R0 office; the line's msg carries the exact command
OFFICE_HINT = ("a vacant office or squads without a leader: dfllm cmd inspect '{\"what\":\"offices\"}', then "
               "dfllm cmd appoint / squad.create / squad.leader (the msg names the unit)")

# BUG-117 (Run 14 note 92) readiness R0 mood_ws: moodable workshop types missing; the line's msg carries the command
MOOD_WS_HINT = ("moodable workshops missing: run the bp.place command the line names (dfllm cmd bp.place "
                "'{\"tpl\":\"workshops\",\"site\":\"S1\",\"p\":{\"only\":\"Loom\"}}'); follow places the rest")


SHOW_FIGHT = ("SIEGE", "BREACH", "ALERT", "DRILL")     # viewlib.lua V.FIGHT: the camera is the player's there
SHOW_CAUSE = ("BREACH", "SIEGE_START", "INVASION", "LOCKDOWN")      # no unit in their d: the lockdown's cause in the state


def view_target(etype: str, d: dict, state: dict | None = None) -> str | None:
    """FR-88: the target of a ready `view` for an event: its unit (d.id for INTRUDER/PREDATOR/INVASION, d.unit for the mood
    types, the first of d.units for patients), else its position (d.pos 'x,y,z'); the SHOW_CAUSE types take the lockdown's
    cause (state alarm.by id, else its pos). None when the event names nothing to look at."""
    def num(v):
        return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else None
    uid = num(d.get("id")) if etype in ("INTRUDER", "PREDATOR", "INVASION") else num(d.get("unit"))
    units = d.get("units")
    if uid is None and isinstance(units, list) and units:
        uid = num(units[0])
    if uid is not None:
        return str(uid)
    pos = d.get("pos")
    if isinstance(pos, list) and len(pos) == 3 and all(isinstance(v, int) and not isinstance(v, bool) for v in pos):
        return ",".join(str(v) for v in pos)
    if etype in SHOW_CAUSE:
        by = ((state or {}).get("alarm") or {}).get("by")
        if isinstance(by, dict):
            if num(by.get("id")) is not None:
                return str(by["id"])
            return view_target("", {"pos": by.get("pos")})
    return None


def show_hint(burst: dict[str, dict], state: dict | None) -> str:
    """FR-88: 'show: dfllm cmd view target=39230', the camera on the first event of the burst (wake order) that names a
    unit or a place. In a fight the camera is the player's (V.FIGHT): then the command is his, with --by gordon."""
    for ty in sorted(burst, key=_prio):
        e = burst[ty]["e"]
        t = view_target(ty, e.get("d") if isinstance(e.get("d"), dict) else {}, state)
        if t:
            cmd = f"dfllm cmd view target={t}"
            return (f"show (the player, in a fight): {cmd} --by gordon" if (state or {}).get("mode") in SHOW_FIGHT
                    else f"show: {cmd}")
    return ""


def wake_line(burst: dict[str, dict], state: dict | None, held_s: float = 0, auto: bool = True,
              review: str = "") -> str:
    """'WAKE y3 sum d20 PEACE | SIEGE_END: msg | GATE_FAIL x2: msg | next: ...' within WAKE_TOKENS. DECISIONS 2: with
    follow --no-auto (auto False) and ways in without door or bridge, every wake line says 'auto-seal off, N openings'.
    FR-86: `review` (plan.review_note: PLAN STALE, the ERROR fixes of this year's draft) rides on the YEAR_REVIEW item."""
    t = (state or {}).get("t") or {}
    when = fmt_tick(t.get("abs", t["y"] * schema.TICKS["YEAR"] + t["tick"])) if t else "?"
    head = f"WAKE {when} {(state or {}).get('mode', '?')}"
    types = sorted(burst, key=_prio)
    ns = [p["n0"] for p in burst.values() if isinstance(p.get("n0"), int)]
    hint = next_hint(types[0], burst[types[0]]["e"])
    openings = ((state or {}).get("ready") or {}).get("open")
    if not auto and isinstance(openings, int) and openings > 0:     # the follow process places nothing: say so every time
        head += f" | AUTO-SEAL OFF, {openings} opening{'s' if openings != 1 else ''} (follow --no-auto)"
        hint = "seal by hand: dfllm cmd bp.place tpl=seal site=S1 at=last; " + hint
    show = show_hint(burst, state)
    tail = f" | next: {hint}" + (f"; dfllm events --cls A --since {min(ns) - 1}" if ns else "") + (f" | {show}" if show else "")
    room = WAKE_TOKENS - est_tokens(head + tail) - 4
    items, used = [], 0
    for i, ty in enumerate(types):
        p = burst[ty]
        e = p["e"]
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        bridge = d.get("bridge") or d.get("module") or ""
        item = f"{ty}{' x%d' % p['c'] if p['c'] > 1 else ''}{' ' + bridge if bridge else ''}: {e.get('msg', '')}"
        if str(e.get("msg", "")).startswith(ty + " ") and p["c"] == 1 and not bridge:
            item = str(e["msg"])                               # FR-94: the message already names its type ("PAUSED_BY_DF for 5 min: ...")
        if ty == "YEAR_REVIEW" and review:
            item += f" | {review}"
        left = len(types) - i - 1
        budget = max(8, (room - used) // (left + 1) if left else room - used)
        item = clip(item, budget)
        cost = est_tokens(" | " + item)
        if used + cost > room:
            items.append(f"+{len(types) - i} more")
            break
        items.append(item)
        used += cost
    line = " | ".join([head] + items) + tail
    return clip(line, WAKE_TOKENS)


class Follower:
    """One poll per call; state persisted in <save>/.follow.json (Python-private)."""

    def __init__(self, save: str | None = None, out: Callable[[str], None] | None = None,
                 clock: Callable[[], float] = time.time, since: int | None = None, auto: bool = True,
                 gate: WakeGate | None = None, audit: bool = True):
        self.pinned, self.out, self.clock, self.since, self.auto = save, out or self._print, clock, since, auto
        self.audit = audit                     # FR-65: the audit job runs with --no-auto too (only --no-audit stops it)
        self.gate = gate or WakeGate()
        self.dir: Path | None = None
        self.tail: files.EventTail | None = None
        self.jobs: dict = {}                   # auto actions in flight: audits, tombs, replies (cmd id -> what)
        self.hb_woken = False
        self._saved = ""
        self._pruned = 0.0
        self.sup_seen: dict | None = None      # supervise alert key -> last 'said' wall seen
        self._sup_read = 0.0
        self.qs_seen: int | None = None        # Run 10: wall of the last <save>/quicksave.json record seen
        self._qs_read = 0.0
        self.plan_auto: dict = {}              # FR-86: first_y (the year follow first saw no plan), tried_y, applied_y
        self._plan_read = 0.0
        self._beat = -1e18

    @staticmethod
    def _print(line: str) -> None:
        print(line, flush=True)

    # ------------------------------------------------------------ persistence
    def _state_path(self) -> Path:
        return self.dir / ".follow.json"

    def _attach(self, d: Path) -> None:
        if self.dir is not None:
            self.save_state()
        self.dir, self.jobs, self.hb_woken, self._saved, self.qs_seen = d, {}, False, "", None
        self.plan_auto, self._plan_read = {}, 0.0
        st = files.read_json(self._state_path())
        since = self.since
        if isinstance(st, dict) and st.get("v") == 2:
            try:
                self.gate.load(st.get("gate") or {})
                self.jobs = self._fresh_jobs(st.get("jobs") if isinstance(st.get("jobs"), dict) else {})
                self.hb_woken = bool(st.get("hb_woken"))
                if isinstance(st.get("sup_seen"), dict):
                    self.sup_seen = {str(k): float(v) for k, v in st["sup_seen"].items()
                                     if isinstance(v, (int, float)) and not isinstance(v, bool)}
                qs = st.get("qs_seen")
                self.qs_seen = qs if isinstance(qs, int) and not isinstance(qs, bool) else None
                pa = st.get("plan_auto")                     # FR-86: survives a restart of follow (a reload of the game)
                self.plan_auto = {k: v for k, v in pa.items() if k in PLAN_AUTO_KEYS and isinstance(v, int)
                                  and not isinstance(v, bool)} if isinstance(pa, dict) else {}
            except Exception as e:             # noqa: BLE001 - a corrupt .follow.json must not block attaching
                self.gate.__init__(self.gate.per_type_s, self.gate.merge_s, self.gate.quiet_s, self.gate.per_hour)
                self.jobs = {}
                files.log_cli(d, "follow", "resume", {}, f"ignored bad .follow.json: {type(e).__name__}: {e}")
            if since is None and isinstance(st.get("last_n"), int) and not isinstance(st.get("last_n"), bool):
                since = st["last_n"]
        self.tail = files.EventTail(d, since, tick_fn=lambda: files.current_tick(d))    # BUG-121
        self.since = None
        self._pruned = 0.0
        files.prune_snaps(d)

    def _fresh_jobs(self, jobs: dict) -> dict:
        """Drop auto jobs a previous follow process left unfinished (their replies are gone); keep cooldowns."""
        now, out = self.clock(), {}

        def fresh(j):
            return isinstance(j, dict) and now - (j.get("since") or 0) <= AUTO_TIMEOUT_S
        for key in ("audits", "replies"):
            group = jobs.get(key) if isinstance(jobs.get(key), dict) else {}
            kept = {k: j for k, j in group.items() if fresh(j)}
            if kept:
                out[key] = kept
        for key in PLACE_KEYS:
            t = jobs.get(key)
            if isinstance(t, dict) and (t.get("placed") or fresh(t)):
                out[key] = t
        w = jobs.get("waive")                  # BUG-300 review: the phase.waive cooldown survives a follow restart
        if isinstance(w, dict) and now - (w.get("since") or 0) < WAIVE_COOLDOWN_S:
            out["waive"] = w
        if out != jobs:
            files.log_cli(self.dir, "follow", "resume", {}, f"dropped stale jobs {sorted(jobs)}")
        return out

    def save_state(self) -> None:
        if self.dir is None or self.tail is None:
            return
        doc = {"v": 2, "last_n": self.tail.last_n, "gate": self.gate.to_json(), "jobs": self.jobs,
               "hb_woken": self.hb_woken}
        if self.sup_seen is not None:
            doc["sup_seen"] = self.sup_seen
        if self.qs_seen is not None:
            doc["qs_seen"] = self.qs_seen
        if self.plan_auto:
            doc["plan_auto"] = self.plan_auto
        text = files.dumps(doc)
        if text == self._saved:
            return                             # unchanged: no disk write every second
        try:
            files.write_json_atomic(self._state_path(), doc)
            self._saved = text
        except OSError as e:
            sys.stderr.write(f"follow: cannot save state: {e}\n")

    def _resolve(self) -> Path | None:
        name = self.pinned or paths.active_save()
        if name is None:
            return self.dir                    # DF closed: keep the last save
        d = paths.runtime_root() / name
        return d if d.is_dir() else self.dir

    # ------------------------------------------------------------ poll
    def poll(self) -> list[str]:
        now = self.clock()
        d = self._resolve()
        if d is None:
            return []
        if d != self.dir:
            self._attach(d)
        printed: list[str] = []
        for e in self.tail.poll():
            self._on_event(e, now)
        self._heartbeat(now)
        self._check_heartbeat(now)
        self._check_supervise(now)
        self._check_quicksave(now)
        self._check_plan(now)
        if self.auto or self.audit:
            self._run_jobs(now)
        if now - self._pruned >= PRUNE_EVERY_S:
            self._pruned = now
            files.prune_outbox(self.dir)
        burst = self.gate.flush(now, tick=lambda: files.current_tick(self.dir))     # BUG-240: game time
        if not burst and self.gate.pending:
            held = self.gate.held_note(now, lambda: files.read_state(self.dir))
            if held:
                self.out(held)
                printed.append(held)
                files.log_cli(self.dir, "follow", "held", sorted(self.gate.pending), held)
        if burst:
            state = files.read_state(self.dir)
            review = plan_mod.review_note(self.dir, state) if "YEAR_REVIEW" in burst else ""     # FR-86
            line = wake_line(burst, state, auto=self.auto, review=review)
            self.out(line)
            printed.append(line)
            files.log_cli(self.dir, "follow", "wake", sorted(burst), line)
        self.save_state()
        return printed

    def _timeline_reset(self, e: dict) -> None:
        """BUG-121: kern found the clock before the log (an older save was loaded). What follow had in flight (audits, tomb and
        seal placements, command replies, the year its minimal plan was tried) belongs to the discarded line; the wake gate
        is wall-clock bound and stays. The events before the marker never reach this point (EventTail drops them)."""
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        files.log_cli(self.dir, "follow", "timeline_reset", {"n": e.get("n")},
                      f"{'save of another line' if d.get('kind') == 'foreign' else 'older save'} loaded: tick "
                      f"{d.get('tick_alt')} -> {d.get('tick_neu')}; dropped jobs {sorted(self.jobs)}")
        self.jobs, self.plan_auto, self._plan_read = {}, {}, 0.0

    def _on_event(self, e: dict, now: float) -> None:
        t, d = e.get("type"), e.get("d")
        d = d if isinstance(d, dict) else {}
        if t == files.TIMELINE_RESET:
            self._timeline_reset(e)
            return
        if t in WAKE_TYPES and e.get("cls") == "A":
            self.gate.add(e, now)
        if not (self.auto or (self.audit and t == "SNAPSHOT_READY")):
            return
        try:                                   # one bad event must not lose the rest of the batch
            if t == "SNAPSHOT_READY":
                self._on_snapshot(d, now)
            elif t == "PROJECT_REQUEST" and d.get("tpl") == "tombs":
                self._request_tombs(d, now)
            elif t == "PROJECT_REQUEST" and d.get("tpl") == "bedrooms" and d.get("why") in ("mood_rock", "rock"):
                # live L4: a strange mood waited for a boulder while nobody placed care's stone dig; the
                # Possessed mood before it failed within 40 days. A bedrooms dig at prio 1 gives boulders.
                # Run 11: economy asks the same when the rock orders want more stone than the fort has (1 boulder,
                # ~110 orders 'no rock') and the miners have nothing to dig
                n = d.get("n") if isinstance(d.get("n"), int) and not isinstance(d.get("n"), bool) else 4
                self._request_place(d["why"], "bedrooms", {"n": max(1, min(n, 6))}, "S1", now, prio=1)
            elif t == "PROJECT_REQUEST" and d.get("tpl") == "farms" and d.get("why") == "food":
                # live L5: pop 41 -> 53 on the same 80 farm tiles, food 105 -> 15 days; economy sizes the plots
                n = d.get("n") if isinstance(d.get("n"), int) and not isinstance(d.get("n"), bool) else 2
                self._request_place("farms", "farms", {"plots": max(1, min(n, 4))}, "S1", now, prio=1)
            elif t == "PROJECT_REQUEST" and d.get("tpl") == "workshops" and d.get("why") == "fishery":
                # Run 11: 883-4532 raw fish lay uncleaned with no fishery and food fell to 5 days: the fishery alone
                from .cmd import _moodable
                # BUG-038: the fort manifest keeps a destroyed fishery (fortcore stage 1, the y433 project); the
                # kernel saw none on the map, so the manifest's dedupe of `add` must not drop it
                self._request_place("fishery", "workshops", {"add": "Fishery", "skip": ",".join(_moodable())}, "S1",
                                    now, prio=1, need=["Fishery"])
            elif t == "PROJECT_REQUEST" and d.get("tpl") == "workshops" and d.get("why") == "farmers":
                # FR-73 (Run 14: no Farmer's Workshop in the whole fort, thread and cloth orders waited for months): the
                # farmer's shop alone, kept although the fort manifest lists a destroyed one (as the fishery, BUG-038)
                from .cmd import _moodable
                self._request_place("farmers", "workshops", {"add": "Farmers", "skip": ",".join(_moodable())}, "S1",
                                    now, prio=1, need=["Farmers"])
            elif t == "PROJECT_REQUEST" and d.get("tpl") == "workshops" and (
                    d.get("why") in ("mandatory", "slabs", "busy", "manager", "missing", "gear", "well")
                    or (d.get("why") == "mood" and d.get("types"))):
                # BUG-283 (Run 15 Drillchamber: the glass furnace a fey mood waited for came 30 days late in a plain
                # 12-shop placement at prio 4): why=mood with types = only the shops the mood and its materials need, prio 1
                # FR-76 (Run 12 Trussroads, reclaimed: no carpenter, no craftsdwarf, no kitchen): the types the runner
                # saw missing on the map, whatever the fort manifest lists (kept by `need`, BUG-066). BUG-133: economy's
                # why=slabs (ghosts wait for memorial slabs, no mason's workshop stands) the same way: the Masons alone.
                # BUG-224: why=busy (one Carpenters/Masons holds the waiting jobs, idle workers stand): one more of it
                # BUG-231: why=manager (the held manager orders' items go to a Carpenters/Masons as tasks; none stands)
                # BUG-267: why=missing (orders wait 14+ days for these shops); BUG-270: why=gear (Leatherworks, Tanners,
                # Mechanics for gear and lever mechanisms); why=well (fix6-water: the hospital well's shop)
                from .cmd import _extra_shops, _moodable
                mood, extra = _moodable(), set(_extra_shops())
                want = [x for x in d.get("types") or [] if isinstance(x, str) and (x in mood or x in extra)]
                if want:
                    params = {"skip": ",".join(x for x in mood if x not in want)}
                    if any(x in extra for x in want):
                        params["add"] = ",".join(x for x in want if x in extra)
                    prev = self.jobs.get("mood")
                    if d["why"] == "mood" and isinstance(prev, dict) and prev.get("placed") and \
                            set(prev.get("need") or []) != set(want):
                        self.jobs.pop("mood")          # BUG-283: another set of mood shops is no repeat (no cooldown)
                    self._request_place(d["why"], "workshops", params, "S1", now, prio=1, need=want)
            elif t == "PROJECT_REQUEST" and d.get("tpl") in AUTO_REQUESTS:
                # live L1: a strange mood needs a shop; BUG-042: economy's tannery request names the Tanners the map
                # lacks, kept although the fort manifest lists a destroyed one (as the fishery, BUG-038)
                need = ["Tanners"] if d.get("tpl") == "workshops" and d.get("why") == "tannery" else None
                self._request_place(d["tpl"], d["tpl"], {}, "S1", now, need=need)
            elif t == "PLAN_EXHAUSTED" and d.get("phase") in AUTO_PHASES:
                self._request_starter(d, now)
            elif t == "AUDIT" and d.get("ok") in (0, False):
                self._request_seal(now)
        except Exception as ex:                # noqa: BLE001 - surfaces as one AUTO_FAIL wake
            self._fail(f"event #{e.get('n')} {t}", f"{type(ex).__name__}: {ex}", now)

    def _synth(self, etype: str, msg: str, now: float) -> None:
        self.gate.add({"n": None, "type": etype, "cls": "A", "msg": msg[:200], "d": {}}, now)
        files.log_cli(self.dir, "follow", etype, {}, msg)

    def _heartbeat(self, now: float) -> None:
        """FR-29: `status` and `doctor` read <save>/.follow.hb to tell a quiet follow from a dead one."""
        if now - self._beat < FOLLOW_HB_EVERY_S or self.dir is None:
            return
        self._beat = now
        try:
            files.write_follow_hb(self.dir, {"v": 2, "wall": int(now), "last_n": self.tail.last_n if self.tail else 0,
                                             "code": CODE,        # BUG-042: status names a follow on old code
                                             "auto": 1 if self.auto else 0})   # DECISIONS 2: --no-auto places nothing
        except OSError as e:
            sys.stderr.write(f"follow: cannot write heartbeat: {e}\n")

    def _check_heartbeat(self, now: float) -> None:
        if paths.active_save() != self.dir.name:
            self.hb_woken = False              # DF closed normally (ACTIVE deleted) or another save
            return
        _, age = files.read_heartbeat(self.dir, now)
        if age is not None and age > HB_STALE_S:
            if not self.hb_woken:
                self.hb_woken = True
                self._synth("HB_STALE", f"heartbeat {int(age)}s old, ACTIVE={self.dir.name}", now)
        elif age is not None:
            self.hb_woken = False

    def _check_supervise(self, now: float) -> None:
        """A supervisor alert supervise logged (said[key] moved) since the last look -> one SUPERVISE wake."""
        if now - self._sup_read < SUPERVISE_EVERY_S:
            return
        self._sup_read = now
        doc = files.read_json(paths.runtime_root() / "supervise.json")
        if not isinstance(doc, dict):
            return
        said = doc.get("said") if isinstance(doc.get("said"), dict) else {}
        said = {str(k): float(v) for k, v in said.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}
        last = doc.get("last") if isinstance(doc.get("last"), dict) else {}
        msgs = {a.get("key"): a.get("msg") for a in last.get("alerts") or [] if isinstance(a, dict)}
        if self.sup_seen is None:              # first look: remember, do not wake on old alerts ...
            self.sup_seen = said
            # ... except a fort that waits for a click right now: supervise's last pass still carries the alarm
            wall = last.get("wall") if isinstance(last.get("wall"), (int, float)) else 0
            if isinstance(doc.get(CLICK_KEY), dict) and msgs.get(CLICK_KEY) and 0 <= now - wall <= CLICK_PASS_S:
                self._synth("NEEDS_CLICK", str(msgs[CLICK_KEY]), now)
            return
        for key, t in sorted(said.items()):
            if t > self.sup_seen.get(key, 0.0):
                self.sup_seen[key] = t
                if now - t <= SUPERVISE_FRESH_S:
                    if key == CLICK_KEY:
                        self._synth("NEEDS_CLICK", str(msgs.get(key) or "see supervise.log"), now)
                    else:
                        self._synth("SUPERVISE", f"{key}: {msgs.get(key) or 'see supervise.log'}", now)

    def _check_quicksave(self, now: float) -> None:
        """Run 10: a `dfllm save` that found no new save folder (<save>/quicksave.json ok 0) -> one QUICKSAVE_FAILED wake
        per failed attempt; one that failed while follow was not running wakes too when it is less than an hour old."""
        if now - self._qs_read < SUPERVISE_EVERY_S or self.dir is None:
            return
        self._qs_read = now
        from .save import read_record, settle
        rec = read_record(self.dir)
        if rec is not None and rec.get("state") == "running":
            # BUG-069: a save still being written is no failure; settle it (landed late / vanished) and look again
            try:
                from .supervise import default_env
                rec = settle(default_env(), self.dir, now) or rec
            except Exception:                  # noqa: BLE001 - no DF folder known: keep waiting
                return
            if rec.get("state") == "running":
                return
        if rec is None or (self.qs_seen is not None and rec["wall"] <= self.qs_seen):
            return
        self.qs_seen = rec["wall"]
        if not rec["ok"] and now - rec["wall"] <= SUPERVISE_FRESH_S:
            self._synth("QUICKSAVE_FAILED", f"quicksave ({rec['by']}) wrote nothing: {rec['why']}", now)

    # ------------------------------------------------------------ auto actions (no LLM)
    def _check_plan(self, now: float) -> None:
        """FR-86 (Run 14: plan.json of y503 in y708, 190 YEAR_REVIEW wakes, no `plan apply`): after plan.stale_apply_years
        game years without an applied plan (0 = off; follow --no-auto never) follow applies the minimal plan itself,
        once per game year, in PEACE only, and wakes PLAN_AUTO; when it cannot (a check ERROR the minimal repairs do not
        clear), AUTO_FAIL says why. The year it counts from is the applied plan's, else the first year follow saw none
        (`plan_auto.first_y`, in .follow.json: it survives a restart)."""
        if not self.auto or self.dir is None or now - self._plan_read < PLAN_CHECK_EVERY_S:
            return
        self._plan_read = now
        try:
            years = plan_mod.stale_years()
            state = files.read_state(self.dir)
            year = ((state or {}).get("t") or {}).get("y")
            if years <= 0 or not isinstance(year, int) or (state or {}).get("mode") != "PEACE":
                return
            plan = plan_mod.applied_plan(self.dir)
            if plan is not None:
                ref = plan["year"]
            else:
                ref = self.plan_auto.setdefault("first_y", year)
            # BUG-132: under the minimal plan a quiet game year is enough: the next automatic plan raises one phase
            rise = year - ref < years and plan_mod.raise_due(self.dir, state, plan)
            if (year - ref < years and not rise) or self.plan_auto.get("tried_y") == year:
                return
            self.plan_auto["tried_y"] = year           # one try a game year, whatever comes out
            self.save_state()
            errs, msg = plan_mod.apply_minimal(self.dir, by="follow")
            if errs:
                self._fail("minimal plan", "; ".join(errs[:3]), now)
                return
            self.plan_auto["applied_y"] = year
            if rise:
                self._synth("PLAN_AUTO", f"minimal plan y{ref}, a quiet year, now y{year}: follow applied the next "
                                         f"automatic plan ({msg})", now)
            else:
                self._synth("PLAN_AUTO", f"no plan applied since y{ref}, now y{year}: follow applied the minimal plan "
                                         f"({msg})", now)
        except Exception as ex:                        # noqa: BLE001 - the plan check must never stop the follower
            self._fail("minimal plan", f"{type(ex).__name__}: {ex}", now)

    def _send(self, verb: str, args: dict, what: str | None, now: float, snap: dict | None = None,
              need: list | None = None) -> str:
        """Send without waiting; with `what`, the reply is read in _run_jobs (refusal/timeout -> AUTO_FAIL)."""
        from .cmd import send
        cid, _ = send(self.dir, verb, args, by="follow", wait_s=0, snap=snap, need=tuple(need or ()))
        if what:
            self.jobs.setdefault("replies", {})[cid] = {"verb": verb, "what": what, "since": now,
                                                        "tpl": args.get("tpl")}
        return cid

    def _fail(self, what: str, err, now: float) -> None:
        self._synth("AUTO_FAIL", f"{what}: {err}", now)

    def _on_snapshot(self, d: dict, now: float) -> None:
        sid, rel, purpose = d.get("id"), d.get("path"), d.get("purpose")
        mine = [self.jobs[k] for k in PLACE_KEYS if self.jobs.get(k) and sid and self.jobs[k].get("snap") == sid]
        for job in mine:
            job.update(path=rel or f"snap/{sid}.json", ready=now)
        if not self.audit or (isinstance(sid, str) and sid.startswith(AUDIT_PREFIX)):
            return                             # --no-audit, or `dfllm audit` asked for it and audits it itself
        if not mine and purpose == "audit" and sid and rel and files.read_manifest(self.dir) is not None:
            # kern's <save>/manifest.json: no inspect round trip, no 8 KB reply limit (live L1)
            self._audit(sid, rel, {"ok": True, "data": files.read_manifest(self.dir)}, now)
        elif not mine and purpose == "audit" and sid and rel:
            try:
                cid = self._send("inspect", {"what": "manifest"}, None, now)    # reply read by the audits job
            except Exception as e:             # noqa: BLE001
                return self._fail(f"audit {sid}", e, now)
            self.jobs.setdefault("audits", {})[sid] = {"path": rel, "inspect": cid, "since": now}

    def _request_tombs(self, d: dict, now: float) -> None:
        params = {"n": d["n"]} if isinstance(d.get("n"), int) and not isinstance(d.get("n"), bool) else {}
        self._request_place("tombs", "tombs", params, "S1", now)

    def _request_place(self, key: str, tpl: str, params: dict, site: str, now: float, prio: int | None = None,
                       need: list | None = None) -> bool:
        """True when the snapshot for the placement was requested (False: cooldown, or the request failed)."""
        job = self.jobs.get(key)
        if job and now - job.get("since", 0) < (AUTO_TIMEOUT_S if not job.get("placed") else TOMBS_COOLDOWN_S):
            return False
        try:
            cid = self._send("snapshot", {"purpose": "sites"}, f"{tpl} snapshot", now)
        except Exception as e:                 # noqa: BLE001
            self._fail(f"{tpl} snapshot", e, now)
            return False
        self.jobs[key] = {"snap": cid, "since": now, "params": params, "tpl": tpl, "site": site}
        if prio is not None:
            self.jobs[key]["prio"] = prio
        if need:
            self.jobs[key]["need"] = list(need)
        return True

    def _request_seal(self, now: float) -> None:
        """Run 10: the audit named the bypass for months and nobody walled it. In PEACE, the walls of the newest audit
        that no seal project builds yet (cmd.audit_routes) get the seal at=audit (cmd.place resolves the tiles).
        BUG-211 (live round 3, Earthboat): never while the audit says the fort has no trap hall (fortcore stage 2: every
        way in is a 'bypass' then, the walls are room doors off the core corridor), never on a fortcore tile (audit_routes
        leaves those out), and the cli.log line only when a placement starts, once per walls set in AUTO_TIMEOUT_S."""
        from .cmd import audit_routes, no_trap_hall
        st = files.read_state(self.dir) or {}
        if st.get("mode") != "PEACE":
            return                             # builders outside in a fight: the next monthly audit asks again
        a = audit_routes(self.dir, st)
        if not a["open"] or no_trap_hall(a.get("fails") or []):
            return
        prev = self.jobs.get("seal") if isinstance(self.jobs.get("seal"), dict) else {}
        if not self._request_place("seal", "seal", {"at": "audit"}, "S1", now):
            return                             # cooldown: the placement of this audit runs already, no log line
        key = ";".join(sorted(a["open"]))
        logged = prev.get("logged") if prev.get("walls") == key and isinstance(prev.get("logged"), (int, float)) else None
        self.jobs["seal"].update(walls=key, logged=logged if logged is not None and now - logged < AUTO_TIMEOUT_S else now)
        if self.jobs["seal"]["logged"] == now:
            files.log_cli(self.dir, "follow", "auto:seal", {"walls": a["open"]},
                          f"audit names {a['routes'][0]}: placing the seal at=audit")

    def _request_starter(self, d: dict, now: float) -> None:
        """PLAN_EXHAUSTED in an auto phase: place the phase's first proj deliverable that has no project yet."""
        from .plan import applied_builds, load_phases
        phases = load_phases()
        ph = next((x for x in (phases or {}).get("phases", []) if x.get("id") == d.get("phase")), None)
        if ph is None:
            return
        done = applied_builds(self.dir, files.read_state(self.dir))
        done_tpls = {t for t, _ in done}
        for dv in ph.get("deliver") or []:
            if dv.get("k") not in ("proj", "workshops"):
                continue
            # live L1b: a `workshops` deliverable starts the workshops template (cmd.place skips the types
            # the fort already has or has planned)
            tpl, stage = (dv.get("tpl"), dv.get("stage")) if dv.get("k") == "proj" else ("workshops", None)
            wparams: dict = {}
            if dv.get("k") == "workshops":
                from .cmd import _extra_shops, _moodable, workshops_missing
                mood, extra = set(_moodable()), set(_extra_shops())
                types = [t for t in dv.get("types") or [] if t == "moodable" or t in mood or t in extra]
                miss = workshops_missing(self.dir, types) if types else []
                if not miss:
                    continue                   # the template builds none of the missing types (or none is)
                # live L6: the non-moodable shops (P0: still, butcher) come through `add`; a phase that asks for
                # no moodable shop gets none of them (skip all)
                add = [t for t in miss if t in extra]
                if add:
                    wparams["add"] = ",".join(add)
                if not any(t in mood for t in miss):
                    wparams["skip"] = ",".join(_moodable())
            staged = isinstance(stage, int) and not isinstance(stage, bool)
            if (stage is None and tpl in done_tpls and dv.get("k") != "workshops") or (staged and any(
                    t == tpl and isinstance(s, int) and s >= stage for t, s in done)):
                continue                       # built, running, or a later stage of it exists
            # (workshops: the fort manifest counts built and planned shops, so a missing type is never queued twice)
            params = {"stage": stage} if staged else wparams
            site = "same" if staged and stage >= 2 else "S1"
            files.log_cli(self.dir, "follow", "auto:starter", {"tpl": tpl, "p": params, "site": site},
                          f"PLAN_EXHAUSTED in {d.get('phase')}: placing {tpl}")
            return self._request_place("starter", tpl, params, site, now)

    def _run_jobs(self, now: float) -> None:
        self._read_replies(now)
        for sid, job in list((self.jobs.get("audits") or {}).items()):
            reply = files.read_outbox(self.dir, job["inspect"])
            if reply is None:
                if now - job["since"] > AUTO_TIMEOUT_S:
                    del self.jobs["audits"][sid]
                    self._fail(f"audit {sid}", "no manifest reply", now)
                continue
            del self.jobs["audits"][sid]
            self._audit(sid, job["path"], reply, now)
        for key in PLACE_KEYS:
            job = self.jobs.get(key)
            if job and not job.get("placed"):
                if job.get("ready"):
                    self._place(key, job, now)
                elif now - job["since"] > AUTO_TIMEOUT_S:
                    del self.jobs[key]
                    self._fail(job.get("tpl", key), "no sites snapshot", now)

    def _read_replies(self, now: float) -> None:
        """Outbox replies of auto commands: ok -> done; ok:false or none in time -> AUTO_FAIL."""
        replies = self.jobs.get("replies") or {}
        for cid, r in list(replies.items()):
            reply = files.read_outbox(self.dir, cid)
            if reply is None and now - r.get("since", 0) <= AUTO_TIMEOUT_S:
                continue
            del replies[cid]
            key = next((k for k in PLACE_KEYS if self.jobs.get(k) is not None
                        and cid in (self.jobs[k].get("snap"), self.jobs[k].get("placed"))), None)
            job = self.jobs.get(key) if key else None
            mine = job is not None
            if reply is None:
                if mine and r["verb"] == "snapshot":
                    del self.jobs[key]         # no second 'no sites snapshot' fail for the same cause
                self._fail(r["what"], f"no reply to {r['verb']} {cid} within {AUTO_TIMEOUT_S}s", now)
                continue
            files.log_cli(self.dir, "follow", f"reply:{r['verb']}", {"id": cid},
                          ("ok " if reply.get("ok") else "ERR ") + str(reply.get("msg", "")))
            if reply.get("ok"):
                continue
            if r["verb"] == "bp.place" and r.get("tpl"):
                from .cmd import unplace
                unplace(self.dir, cid, r["tpl"], (job or {}).get("prev") if mine else None)
            if mine:
                del self.jobs[key]             # a later PROJECT_REQUEST / PLAN_EXHAUSTED may try again
            self._fail(r["what"], f"{r['verb']} {cid} refused: {reply.get('msg', '')}", now)
        if not replies:
            self.jobs.pop("replies", None)

    def _audit(self, sid: str, rel: str, reply: dict, now: float) -> None:
        info: dict = {}
        try:
            args = compute_audit(self.dir, sid, rel, reply, info=info)
            self._send("audit", args, f"audit {sid}", now)
        except Exception as e:                 # noqa: BLE001 - any audit failure must surface as one wake
            return self._fail(f"audit {sid}", e if isinstance(e, AuditError) else f"{type(e).__name__}: {e}", now)
        files.log_cli(self.dir, "follow", "auto:audit", {"snap": sid},
                      f"ok={args['ok']} traps={args['min_traps']}" + trap_note(info, args))
        files.prune_snaps(self.dir)

    def _place(self, key: str, job: dict, now: float) -> None:
        from .cmd import BpError, _placed
        tpl = job.get("tpl") or key
        try:
            snap = files.read_snapshot(self.dir / str(job["path"]))
            if snap is None:
                raise BpError(f"snapshot {job['path']} missing/invalid")
            args = {"tpl": tpl, "site": job.get("site") or "S1"}   # S1 = best free site on this snapshot
            if job.get("params"):
                args["p"] = job["params"]
            if isinstance(job.get("prio"), int):
                args["prio"] = job["prio"]
            prev = files.read_json(_placed(self.dir, tpl))
            need = job.get("need") if isinstance(job.get("need"), list) else None
            cid = self._send("bp.place", args, tpl, now, snap=snap, need=need)
        except Exception as e:                 # noqa: BLE001 - WP3 bugs included: one AUTO_FAIL, job dropped
            self.jobs.pop(key, None)
            self._fail(tpl, e, now)
            if tpl == "farms" and isinstance(e, BpError):
                self._waive_farms(str(e), now)
            return
        job.update(placed=cid, since=now, prev=prev if isinstance(prev, dict) else None)
        files.log_cli(self.dir, "follow", f"auto:{key}", args, f"placed {cid}")


    def _waive_farms(self, err: str, now: float) -> None:
        """BUG-300 (Run 15 Drillchamber: phase P0 for six game years, plans at P5; `farms` found 'only 0 free site(s)'
        at every PLAN_EXHAUSTED starter and farms request): when the farms placement finds no free site and the sites
        snapshot has neither a farms room site nor a surface one (plan.farm_site 'none'), the current phase's
        deliverable farms is waived in the kernel (phase.waive, why names the count), once per WAIVE_COOLDOWN_S."""
        if "only 0 free site(s) for farms" not in err:
            return
        from .plan import farm_site, load_phases
        st = files.read_state(self.dir) or {}
        ph = next((x for x in (load_phases() or {}).get("phases", []) if x.get("id") == st.get("phase")), None)
        if ph is None or not any(d.get("k") == "proj" and d.get("tpl") == "farms" and "stage" not in d
                                 for d in ph.get("deliver") or []):
            return
        last = self.jobs.get("waive")
        if isinstance(last, dict) and now - (last.get("since") or 0) < WAIVE_COOLDOWN_S:
            return
        if farm_site(self.dir) != "none":
            return
        self.jobs["waive"] = {"since": now}
        try:
            self._send("phase.waive", {"tpl": "farms", "why": "bp sites farms: 0 room and 0 surface sites"}, None, now)
        except Exception as e:                 # noqa: BLE001
            return self._fail("phase.waive farms", e, now)
        files.log_cli(self.dir, "follow", "auto:waive", {"tpl": "farms", "phase": st.get("phase")},
                      f"no farm site at all: deliverable farms of {st.get('phase')} waived")


class AuditError(RuntimeError):
    """Why an audit was not sent (the AUTO_FAIL text of follow, the error line of `dfllm audit`)."""


def trap_note(info: dict, args: dict) -> str:
    """' (41 armed in the trap hall; 0 on the cheapest route now, a bypass skips them; ...)' from bp.topo.audit's
    info (Run 9/10: `traps 0` beside an armed hall needs its reason in plain sight); '' without info."""
    t = info.get("traps") if isinstance(info, dict) else None
    if not isinstance(t, dict):
        return ""
    out = [f"{t.get('hall', 0)} of {t.get('armed', 0)} armed traps in the trap hall"]
    if t.get("walls"):
        out.append(f"counted with the {t['walls']} bypass wall(s) the findings name; the bypass itself meets "
                   f"{t.get('any_route', 0)}")
    e = t.get("enters")
    if args.get("min_traps", 0) < t.get("hall", 0) // 2 and e:
        out.append("the counted route enters the hall at %d,%d,%d" % tuple(e))
    return " (" + "; ".join(out) + ")"


def compute_audit(save_dir: Path, sid: str, rel: str, reply: dict, info: dict | None = None) -> dict:
    """The follower's audit job for one audit snapshot: the kern manifest (an `inspect manifest` reply or
    {ok, data: <save>/manifest.json}) is checked, cached for site ranking, and bp.topo.audit(snap, manifest) gives
    the `audit` verb args. Raises AuditError (refused/truncated/invalid manifest, missing snapshot) or the bp error."""
    if not reply.get("ok"):
        raise AuditError(f"inspect manifest refused: {reply.get('msg', '')}")
    data = reply.get("data")
    manifest = data.get("manifest", data) if isinstance(data, dict) else None
    if isinstance(manifest, dict) and manifest.get("trunc"):
        # kern.lua reply(): an inspect `data` > 8 KB is replaced by {trunc, bytes}; never audit that
        raise AuditError(f"manifest truncated by kern ({manifest.get('bytes', '?')} bytes > 8 KB inspect limit); "
                         "audit not sent")
    errs = schema.validate("manifest", manifest) if isinstance(manifest, dict) else ["not an object"]
    if errs:
        raise AuditError(f"manifest invalid ({errs[0]}); audit not sent")
    from .cmd import cache_manifest, load_bp
    cache_manifest(save_dir, manifest)         # site ranking (cmd.fort_manifest) starts from the kern manifest
    snap = files.read_snapshot(Path(save_dir) / rel)
    if snap is None:
        raise AuditError(f"snapshot {rel} missing/invalid")
    fn = load_bp("topo").audit
    try:
        takes_info = "info" in inspect.signature(fn).parameters
    except (TypeError, ValueError):
        takes_info = False
    res = fn(snap, manifest, info=info) if takes_info and info is not None else fn(snap, manifest)
    return audit_args(sid, res)


def audit_args(sid: str, res: dict) -> dict:
    """bp.topo.audit result -> `audit` verb args (types coerced, lists clipped to the schema limits)."""
    fails = [str(f).encode("utf-8")[:80].decode("utf-8", "ignore") for f in (res.get("fails") or [])][:50]
    return {"snap": sid, "ok": bool(res.get("ok")), "fails": fails, "min_traps": max(0, int(res.get("min_traps") or 0)),
            "bypass": bool(res.get("bypass")), "refuge_sep": bool(res.get("refuge_sep")),
            "civ_sep": bool(res.get("civ_sep")), "caverns": bool(res.get("caverns"))}


# ---------------------------------------------------------------- dfllm audit (FR-65)
def _snap_file(save_dir: Path, sid: str, events: bool = False) -> tuple[str, dict] | None:
    """(rel path, valid snapshot) of snapshot `sid`: snap/<sid>.json, snap/<sid>-<n>.json, else (events) the path its
    SNAPSHOT_READY event of the running boot names (the scan stops at the newest BOOT)."""
    d = Path(save_dir)
    cands = [d / "snap" / f"{sid}.json"]
    try:
        cands += sorted((d / "snap").glob(f"{sid}-*.json"))
    except OSError:
        pass
    for p in cands:
        doc = files.read_snapshot(p) if p.is_file() else None
        if doc is not None and doc.get("id") == sid:
            return f"snap/{p.name}", doc
    for e in (files.iter_events_rev(d) if events else ()):
        if e.get("type") == "BOOT":
            break
        ed = e.get("d") if isinstance(e.get("d"), dict) else {}
        if e.get("type") == "SNAPSHOT_READY" and ed.get("id") == sid and isinstance(ed.get("path"), str):
            doc = files.read_snapshot(d / ed["path"])
            return (ed["path"], doc) if doc is not None else None
    return None


def audit_timeout(save_dir: Path) -> tuple[float, int]:
    """BUG-160 (live round 2, i1: a 323k-tile audit came 70 s after the request, the old fixed 60 s gave up first):
    (seconds, bytes) - the wait for a fresh audit snapshot adapts to the fort: the largest snapshot on disk scanned three
    times over (its own export plus a running readiness export it queues behind) plus a minute, at least AUDIT_SNAP_S,
    at most AUDIT_SNAP_MAX_S."""
    big = 0
    for p in files.snap_paths(save_dir):
        try:
            big = max(big, p.stat().st_size)
        except OSError:
            pass
    return min(float(AUDIT_SNAP_MAX_S), max(float(AUDIT_SNAP_S), 60.0 + 3.0 * big / AUDIT_SNAP_BPS)), big


def run_audit(args, save_dir: Path, sleep: Callable[[float], None] = time.sleep,
              clock: Callable[[], float] = time.monotonic) -> int:
    """`dfllm audit [--snap ID]`: what follow does on an audit snapshot, once and now. Without --snap it requests a
    fresh snapshot (purpose audit, the kernel's default audit box: the fort's pieces + a margin, explore shafts as
    column parts, BUG-043) and waits for it."""
    from .cmd import EXIT_BAD, EXIT_NOREPLY, EXIT_OK, EXIT_REFUSED, fmt_reply, send
    save_dir = Path(save_dir)
    sid = args.snap
    if sid is not None and not re.fullmatch(schema.ID_RE, sid):
        print(f"audit: bad snapshot id {sid!r} (expected {schema.ID_RE})")
        return EXIT_BAD
    timeout = args.timeout
    if timeout is None:                        # BUG-160: adapt to the fort's size and say so
        timeout, big = audit_timeout(save_dir)
        if args.snap is None:
            print(f"audit: waiting up to {int(round(timeout))} s for the fresh snapshot (largest snapshot on disk "
                  f"{big // 1024} KB; --timeout sets it)")
    try:
        if sid is None:
            sid = files.new_cmd_id(prefix=AUDIT_PREFIX)
            _, reply = send(save_dir, "snapshot", {"purpose": "audit"}, by="cli", wait_s=min(10.0, timeout),
                            cmd_id=sid)
            if reply is None:
                print(fmt_reply(sid, "snapshot", None, save_dir))
                return EXIT_NOREPLY
            if not reply.get("ok"):
                print(f"audit: snapshot refused: {reply.get('msg', '')}")
                return EXIT_REFUSED
        t0, found, noted = clock(), None, False
        while True:
            found = _snap_file(save_dir, sid, events=args.snap is not None)
            if found is not None or args.snap is not None or clock() - t0 >= timeout:
                break
            if not noted and clock() - t0 >= AUDIT_SNAP_NOTE_S:
                noted = True                   # BUG-160: a big fort scans long or queues behind a readiness export
                print(f"audit: still waiting for {sid} after {AUDIT_SNAP_NOTE_S} s (the kernel scans it in slices, "
                      "behind a running snapshot export if one is under way)")
            sleep(0.5)
        if found is None:
            later = f" within {timeout:g} s; try again later: dfllm audit --snap {sid}"
            print(f"audit: no snapshot {sid}" + (later if args.snap is None else " (dfllm events --type SNAPSHOT_READY)"))
            return EXIT_NOREPLY if args.snap is None else EXIT_BAD
        rel, snap = found
        if snap.get("purpose") != "audit":
            print(f"audit: snapshot {sid} has purpose {snap.get('purpose')!r}; readiness accepts only audit "
                  "snapshots (run dfllm audit without --snap)")
            return EXIT_BAD
        man = files.read_manifest(save_dir)
        if man is not None:
            reply = {"ok": True, "data": man}
        else:
            _, reply = send(save_dir, "inspect", {"what": "manifest"}, by="cli", wait_s=args.wait)
            if reply is None:
                print("audit: no reply to inspect manifest (is the kernel running? dfllm status)")
                return EXIT_NOREPLY
        info: dict = {}
        a = compute_audit(save_dir, sid, rel, reply, info=info)
        cid, reply = send(save_dir, "audit", a, by="follow", wait_s=args.wait)
    except (AuditError, schema.SchemaError) as e:
        print(f"audit: not sent: {'; '.join(e.errors[:3]) if isinstance(e, schema.SchemaError) else e}")
        return EXIT_BAD
    except Exception as e:                     # noqa: BLE001 - bp unavailable or a WP3 bug: say it, never a traceback
        print(f"audit: not sent: {type(e).__name__}: {e}")
        return EXIT_BAD
    yes = {True: "yes", False: "no"}
    print(f"audit of snapshot {sid} (tick {snap.get('tick')}): ok {yes[a['ok']]}, traps {a['min_traps']}, "
          f"bypass {yes[a['bypass']]}, refuge_sep {yes[a['refuge_sep']]}, civ_sep {yes[a['civ_sep']]}, "
          f"caverns sealed {yes[a['caverns']]}")
    note = trap_note(info, a)
    if note:
        print(f"  traps:{note[1:]}")
    for f in a["fails"][:6]:
        print(f"  fail: {f}")
    if len(a["fails"]) > 6:
        print(f"  ... {len(a['fails']) - 6} more")
    print(fmt_reply(cid, "audit", reply, save_dir))
    files.log_cli(save_dir, "cli", "audit", {"snap": sid}, f"ok={a['ok']} traps={a['min_traps']}" + note)
    if reply is None:
        return EXIT_NOREPLY
    if not reply.get("ok") and "unknown snap" in str(reply.get("msg", "")):
        print("  (readiness takes only an audit snapshot of the running boot, once: run dfllm audit without --snap)")
    return EXIT_OK if reply.get("ok") else EXIT_REFUSED


def add_audit_parser(sub) -> None:
    p = sub.add_parser("audit", help="run the path audit now (follow's audit job, once) and send its result",
                       description="Without --snap: request a fresh audit snapshot, wait for it, audit it with "
                                   "bp.topo.audit and send the result (readiness R0/R1). Works with follow --no-auto "
                                   "and without follow.")
    p.add_argument("--snap", help="audit this audit snapshot of the running boot instead of a fresh one")
    p.add_argument("--timeout", type=float, default=None,
                   help=f"seconds to wait for the fresh snapshot (default: by the fort's snapshot size, at least "
                        f"{AUDIT_SNAP_S})")
    p.add_argument("--wait", type=float, default=10.0, help="seconds to wait for each kernel reply")


# BUG-238 (Run 15 Guildcleans/Inkintense: a Monitor's old `follow` child kept running beside the new one; every audit
# snapshot was audited twice, the second answer 'unknown snap' woke as AUTO_FAIL 15+ times, both wrote .follow.json):
# one follow per save. <save>/.follow.lock {v, pid, start, hb}; a second follow refuses while the owner's pid lives and
# its hb is younger than FOLLOW_LOCK_STALE_S, unless --takeover; an owner that finds another pid in the lock exits.
FOLLOW_LOCK = ".follow.lock"
FOLLOW_LOCK_STALE_S = 3 * FOLLOW_HB_EVERY_S


def pid_alive(pid) -> bool:
    """Whether a process with this pid runs (Windows: OpenProcess + GetExitCodeProcess; never os.kill, which ends it there)."""
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 0:
        return False
    if sys.platform == "win32":
        import ctypes
        from ctypes import wintypes as w
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.OpenProcess.argtypes, k32.OpenProcess.restype = [w.DWORD, w.BOOL, w.DWORD], w.HANDLE
        k32.GetExitCodeProcess.argtypes = [w.HANDLE, ctypes.POINTER(w.DWORD)]
        k32.CloseHandle.argtypes = [w.HANDLE]
        h = k32.OpenProcess(0x1000, False, pid)              # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return ctypes.get_last_error() == 5             # access denied: it exists
        try:
            code = w.DWORD()
            return bool(k32.GetExitCodeProcess(h, ctypes.byref(code))) and code.value == 259    # STILL_ACTIVE
        finally:
            k32.CloseHandle(h)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return True


def lock_owner(save_dir: Path, now: float, alive: Callable[[int], bool] | None = None) -> dict | None:
    """BUG-238: the lock of another follow that still runs for this save (live pid, fresh hb), else None."""
    doc = files.read_json(Path(save_dir) / FOLLOW_LOCK, retry=False)
    if not isinstance(doc, dict) or doc.get("pid") == os.getpid():
        return None
    hb = doc.get("hb")
    if not isinstance(hb, (int, float)) or isinstance(hb, bool) or now - hb > FOLLOW_LOCK_STALE_S:
        return None
    return doc if (alive or pid_alive)(doc.get("pid")) else None


def acquire_lock(save_dir: Path, now: float, takeover: bool = False,
                 alive: Callable[[int], bool] | None = None) -> tuple[bool, dict | None]:
    """(True, None) when this process now holds <save>/.follow.lock; (False, owner) when another follow runs."""
    owner = lock_owner(save_dir, now, alive)
    if owner is not None and not takeover:
        return False, owner
    files.write_json_atomic(Path(save_dir) / FOLLOW_LOCK, {"v": 1, "pid": os.getpid(), "start": int(now), "hb": int(now),
                                                           **({"took": owner.get("pid")} if owner else {})})
    return True, None


def refresh_lock(save_dir: Path, now: float, alive: Callable[[int], bool] | None = None) -> dict | None:
    """Beat the lock; the lock of a follow that took over (another live pid with a fresh hb) is returned untouched."""
    owner = lock_owner(save_dir, now, alive)
    if owner is not None:
        return owner
    doc = files.read_json(Path(save_dir) / FOLLOW_LOCK, retry=False)
    start = doc.get("start") if isinstance(doc, dict) and doc.get("pid") == os.getpid() else None
    files.write_json_atomic(Path(save_dir) / FOLLOW_LOCK, {"v": 1, "pid": os.getpid(),
                                                           "start": start if isinstance(start, int) else int(now),
                                                           "hb": int(now)})
    return None


def release_lock(save_dir: Path | None) -> None:
    if save_dir is None:
        return
    p = Path(save_dir) / FOLLOW_LOCK
    doc = files.read_json(p, retry=False)
    if isinstance(doc, dict) and doc.get("pid") == os.getpid():
        try:
            p.unlink()
        except OSError:
            pass


class _Lock:
    """run()'s hold on the lock of the save the follower is attached to (it follows a save switch)."""

    def __init__(self, takeover: bool):
        self.takeover, self.dir, self.beat = takeover, None, -1e18

    def step(self, d: Path | None) -> str | None:
        """None to go on; the line to print before exiting when another follow holds or took the lock."""
        try:
            return self._step(d)
        except OSError as e:                        # a lock that cannot be written must not blind the follower
            sys.stderr.write(f"follow: lock: {type(e).__name__}: {e}\n")
            self.dir, self.beat = d, time.time()    # try again at the next beat, not every poll
            return None

    def _step(self, d: Path | None) -> str | None:
        now = time.time()
        if d is None:
            return None
        if d != self.dir:
            release_lock(self.dir)
            self.dir = None
            ok, owner = acquire_lock(d, now, self.takeover)
            if not ok:
                age = int(now - owner["hb"]) if isinstance(owner.get("hb"), (int, float)) else "?"
                return (f"follow already runs (pid {owner.get('pid')}, beat {age}s ago) for {d.name}: this one exits; "
                        f"stop that one, or start this one with --takeover")
            self.dir, self.beat = d, now
            files.log_cli(d, "follow", "lock", {"takeover": self.takeover}, "holds .follow.lock")
            return None
        if now - self.beat >= FOLLOW_HB_EVERY_S:
            self.beat = now
            owner = refresh_lock(d, now)
            if owner is not None:
                self.dir = None                     # not ours any more: never delete it
                return f"follow: pid {owner.get('pid')} took over {d.name} (--takeover): this one exits"
        return None


def run(args) -> int:
    f = Follower(save=args.save_pin, since=args.since, auto=not args.no_auto,
                 audit=not getattr(args, "no_audit", False))
    t0, errors, last_err = time.monotonic(), 0, -1e18
    lock = _Lock(bool(getattr(args, "takeover", False)))          # BUG-238
    try:
        while True:
            try:
                why = lock.step(f._resolve())
                if why:
                    print(why, flush=True)
                    f.dir = None                    # leave the other follow's .follow.json alone
                    return 3 if "already runs" in why else 0
                f.poll()
                errors = 0
            except Exception as e:             # noqa: BLE001 - never die: the Monitor would go blind
                errors += 1
                now = time.monotonic()
                if now - last_err >= ERR_EVERY_S:      # a persistent error must not flood the Monitor
                    last_err = now
                    sys.stderr.write(f"follow: poll error {errors}: {type(e).__name__}: {e}\n")
                try:
                    files.log_cli(f.dir, "follow", "error", {}, f"{type(e).__name__}: {e}")
                except Exception:              # noqa: BLE001
                    pass
            if args.once or (args.max_s and time.monotonic() - t0 >= args.max_s):
                return 0
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0
    finally:
        f.save_state()
        release_lock(lock.dir)


def add_parser(sub) -> None:
    p = sub.add_parser("follow", help="Monitor target: one wake line per allowed class-A burst")
    p.add_argument("--since", type=int, help="replay events with n > N (default: resume / start at the end)")
    p.add_argument("--interval", type=float, default=1.0)
    p.add_argument("--once", action="store_true", help="poll once and exit")
    p.add_argument("--max-s", type=float, default=0, help="exit after N seconds")
    p.add_argument("--no-auto", action="store_true",
                   help="no automatic placements (tombs, workshops, farms, P0/P1 starters); the audit still runs")
    p.add_argument("--no-audit", action="store_true", help="do not run the path audit on audit snapshots either")
    p.add_argument("--takeover", action="store_true",
                   help="BUG-238: take the save over from a follow that still runs (it exits); without it this one exits")
