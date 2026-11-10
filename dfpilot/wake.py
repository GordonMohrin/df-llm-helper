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
                                  why=mood with d.types (BUG-283: the shops a strange mood and its materials need) -> the same;
                                  why=cut (BUG-654: the shop types no citizen can walk to) -> the same, a NEW shop of the type
  PROJECT_REQUEST tpl=office why=office -> BUG-396: the manager's office (the surface variant without a dug core), prio 1
  PROJECT_REQUEST tpl=farms why=food -> the same with p.plots = n (1-4) at prio 1 (economy asks when the farm
                                  tiles fall short of the citizens and food is low or falling; live L5)
  PROJECT_REQUEST tpl=farms why=drink|drink_surface -> BUG-406/408: one plot of the kind the stock's brewable seeds
                                  fit (drink_surface: p.surface = 1), prio 1
  PROJECT_REQUEST tpl=cistern why=patient_water -> BUG-434: the same for patients lying far from any accepted water (d.at only when a
                                  body without a bank is known; without it `plan propose` drafts the cistern)
  PROJECT_REQUEST tpl=cistern why=no_water -> BUG-424: no water the citizens reach, drink running low: the cistern template with its pipe
                                  from the water nearest to the fort (d.at; a bank intake or a sealed rock intake, safe plans only; a
                                  plan that needs water above the well room is AUTO_FAIL for Gordon), never free digging at the water
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
SYNTH = {"HB_STALE", "TICK_STALL", "AUTO_FAIL", "SUPERVISE", "QUICKSAVE_FAILED", "NEEDS_CLICK", "PLAN_AUTO", "PROJECT_STALE"}   # follower's own wake reasons (not kern events)
# Run 9: an army walked in while SIEGE_START/INVASION waited in the digest; they and the interrupts come right
# after BREACH and wake at once (URGENT: no merge wait, no hourly limit, one per type per URGENT_REPEAT_S)
PRIO = ["BREACH", "SIEGE_START", "INVASION", "INTRUDER", "ARRIVAL", "PREDATOR", "WATER_PREDATOR", "DROWNED", "LOCKDOWN", "SIEGE_DEEP", "REFUGE_PLUG",
        "BRIDGE_DESTROYED", "GATE_FAIL",
        "TRANSFORM", "CURSED",                # BUG-115: a were-form among the citizens, then a curse (interrupts)
        "DEATHS_3PLUS", "NO_DEPOT", "CURSE_MOON",
        "NEEDS_CLICK",                        # K2: no fort runs at all; nothing else in the burst can be acted on first
        "PATIENT_DYING", "PATIENTS_OUT", "MOOD_CRITICAL",     # I1: a patient or a mood dwarf at the death line comes before the housekeeping types
        "DEATHS_PREVENTABLE", "KERN_FAULT", "HB_STALE", "TICK_STALL", "SUPERVISE", "QUICKSAVE_FAILED",
        "PAUSED_BY_DF",                       # FR-94: the game stands (a load, a popup); one `dfllm cmd resume` runs it again
        "SIEGE_END",
        "DRILL_FAIL", "BURROW_SHRUNK", "SIEGE_UNREADY", "PERF_DEGRADED", "DECISION_NEEDED", "SEAL_STUCK",
        "PROJECT_BLOCKED", "PLAN_EXHAUSTED", "PROJECT_STALE", "PLAN_AUTO", "YEAR_REVIEW", "AUTO_FAIL"]
URGENT = {"BREACH", "SIEGE_START", "INVASION", "LOCKDOWN", "WATER_PREDATOR", "DROWNED"} | set(schema.INTERRUPTS)   # BUG-494/496: a pack at the brook kills in days
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
        # BUG-475: the clock stands with the kernel alive; the line says whether `resume` can release it
        "TICK_STALL": "dfllm status; pause:df / pause:popup: dfllm cmd resume (refuses threat or curse popups); else tell Gordon "
                      "(a screen the kernel cannot close; nothing is clicked from here)",
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
        # BUG-494: a large or predatory wild unit in or beside water near the citizens; the kernel holds the fishers home. d.cmd is
        # the exact squad.sortie (d.reach 1 = on the citizens' ground, 2 = strike from the bank, 0 = out of reach: no sortie)
        "WATER_PREDATOR": "dfllm cmd inspect what=unit key=<d.id>; keep everybody off that water (no well, fishing, bridge "
                          "or dig beside it); d.cmd sends the squad when d.reach is 1 or 2; tell Gordon",
        # BUG-496: a citizen was found drowned; the line names the tile, the water and the wild units near
        "DROWNED": "dfllm cmd inspect what=unit key=<id of a d.near unit> for a wild unit near the body; keep the others away "
                   "from that water (WATER_PREDATOR keeps the fishers home); no dig, well or bridge beside it; tell Gordon",
        # BUG-479: building destroyers are at the refuge; the kernel walled the stair foot (a hatch/door is broken by them)
        "REFUGE_PLUG": "dfllm status; tell Gordon: the refuge stair foot is walled against the building destroyers; the kernel lifts it in PEACE",
        "REFUGE_FAIL": "dfllm cmd inspect '{\"what\":\"refuge\"}'; dfllm cmd bp.place tpl=seal site=S1 at=refuge "
                       "(its stair hatch and the line's tiles); next plan: refuge pieces first",
        # BUG-107: a potential refuge holds less food/drink than refuge.floor_pct % of the siege need; d.cmd is the existing
        # command that builds the store (stockroom in Kern+, refuge_drink in the refuge); d.total_f/total_d: if the whole fort
        # holds too little, make food/drink first
        "REFUGE_STOCK": "dfllm cmd inspect '{\"what\":\"refuge\"}'; send the line's d.cmd (stockroom / refuge_drink) when the "
                        "fort's own stock covers it, else food and drink first; tell Gordon (BUG-464: d.fight=1 is a refuge "
                        "that took the citizens in short of food or drink in a fight: no build now, stock it when the way "
                        "is clear)",
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
                            "BUG-462: building destroyers break a RAISED bridge too, the kernel already sent the civilians to "
                            "the refuge (seal.lost); nothing tactical",
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
# BUG-435: follow cancelled a project set aside plan.stale_project_days days (plan.STALE_CANCEL_TPLS); `plan propose` drafts it again
NEXT["PROJECT_STALE"] = ("tell Gordon what follow cancelled (d.msg: project, template, days, what it waited for; the kernel orders the "
                         "missing mechanisms itself); dfllm plan propose y.json draws the template again with the material in reach, "
                         "plan check, plan apply; a core, seal or water project is never cancelled this way (PROJECT_BLOCKED why=stale)")
STALE_CHECK_EVERY_S = 600                      # BUG-435: how often follow looks at the set-aside projects
CORE_SITE_EVERY_S = 300                        # BUG-441: how often follow looks for a queued core above / in the aquifer
ORPHAN_FIRST_S = 120                           # BUG-442: the first sweep of a save folder comes this long after follow saw it
ORPHAN_EVERY_S = 900                           # BUG-442: how often follow asks the kernel about bp files it may not know
STALE_RETRY_S = 21600                          # BUG-435: a refused cancel is tried again after this long
SUPERVISE_EVERY_S = 15                         # supervise.json read cadence
SUPERVISE_FRESH_S = 3600                       # alerts logged longer ago than this never wake
CLICK_KEY = "needs_click"                      # supervise.CLICK_KEY (K2): the alarm for a save only a human can load now
CLICK_PASS_S = 600                             # a standing needs_click wakes a follow that starts late if supervise ran this recently
HB_STALE_S = 300
FOLLOW_HB_EVERY_S = 10                         # FR-29: follow's own heartbeat (<save>/.follow.hb)
AUTO_TIMEOUT_S = 60
# BUG-639 (Run 16b i2 Valleyhame y375-y378: `AUTO_FAIL farms / tombs / bedrooms: no sites snapshot` over and over while kern.log said 'snapshot:
# ... (sites, 168480 tiles, by inbox:follow) written 1 min / 2 min / 3 min after the request'): the sites export of a default box takes one to
# three minutes on a busy kernel (it paces itself, waits for the yearly autosave), AUTO_TIMEOUT_S gave up after 60 s and asked again, so the
# queue held a request nobody waited for. A job that waits for its snapshot waits AUTO_SNAP_TIMEOUT_S (cmd.SNAP_WAIT_MAX_S).
AUTO_SNAP_TIMEOUT_S = 300
TOMBS_COOLDOWN_S = 600
WAIVE_COOLDOWN_S = 3600                         # BUG-300: one phase.waive farms per hour of follow at most
CODE = files.code_stamp()                      # BUG-042: the dfpilot code this follow process imported
PLACE_KEYS = ("tombs", "workshops", "starter", "mood_rock", "rock", "farms", "seal", "fishery", "farmers",
              "mandatory", "slabs",           # automatic placements (one each); BUG-133: slabs = the masons for the ghosts
              "busy",                         # BUG-224: busy = one more Carpenters/Masons beside a full one
              "mood",                         # BUG-283: the shops a strange mood waits for (care's typed request)
              "cistern_water",                # BUG-424: the piped cistern from the water nearest to a fort without drink
              # BUG-654 (Run 16a i1 Basementflew): the workshops requests are keyed by their `why` (_on_event), and these six were not listed:
              # their snapshot came, `_on_snapshot` matched no job and nothing was ever placed (BUG-231 manager, BUG-267 missing, BUG-270 gear,
              # well, BUG-473 masonry, BUG-630 trade); cut = BUG-654's own, the shop types no citizen can walk to
              "manager", "missing", "gear", "well", "masonry", "trade", "cut")
SEAL_HINT = ("dfllm cmd bp.place tpl=seal site=S1 at=audit (walls the audit's bypass; follow places it itself "
             "unless --no-auto); then dfllm audit")
AUTO_REQUESTS = ("tombs", "workshops")            # PROJECT_REQUEST templates follow places itself
AUTO_PHASES = ("P0", "P1")                    # PLAN_EXHAUSTED auto-start only for the basic infrastructure
PRUNE_EVERY_S = 60
STALL_S = 120                                  # BUG-475: real seconds the game tick may stand while the kernel beats and nothing is paused
STALL_AGAIN_S = 1800                           # BUG-475: a stall that goes on is said again after this long
STALL_HB_MAX_S = 30                            # BUG-475: the heartbeat must be this fresh (the kernel runs; HB_STALE is the other case)
PAUSED_HINT_S = 30                             # BUG-614: real seconds follow sees pause:df / pause:popup before it says `cmd resume`
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
URGENT_DECISIONS = {"drink_low", "food_low", "famine", "thirst", "patient_thirst", "stranded_drink", "stranded_food",
                    "mood_deadline", "no_water", "thirst_unit", "job_stalled", "mood_thirst", "dry_well", "patient_out",
                    "pond_blocks_well"}   # BUG-340; BUG-391; BUG-395; BUG-401; BUG-416; BUG-422; BUG-507; BUG-509; BUG-541; BUG-559; BUG-615
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


def next_hint(etype: str, e: dict, save_dir=None) -> str:
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
    if etype == "DECISION_NEEDED" and d.get("id") == "manager_stuck":
        return manager_stuck_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "locked_out":
        return locked_out_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "lockdown_long":
        return lockdown_long_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "bridge_rebuild":
        return rebuild_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "intruder_sortie":
        return sortie_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "confined_need":
        return need_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "kill_lone_intruder":
        return lone_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "siege_long":
        return siege_long_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "starve_lockdown":
        return starve_lockdown_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "seal_stalled":
        return seal_stalled_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "job_stalled":
        return stalled_job_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "dry_well":
        return dry_well_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "no_hard_stone":
        return no_hard_stone_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "mood_thirst":
        return mood_thirst_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "project_released":
        return released_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") == "hospital_supply":
        return hospital_supply_hint(d)
    if etype == "DECISION_NEEDED" and d.get("id") in ("famine", "food_low", "mood_deadline", "no_water",
                                                                         "thirst_unit", "thirst") and d.get("cmds"):
        return food_hint(d, save_dir)
    if etype == "PATIENTS_OUT":
        return patients_hint(d)
    if etype == "PAUSED_BY_DF" and d.get("deny"):
        return ("tell Gordon at once: a popup with a threat or curse word holds the game; resume refuses it, he reads and "
                "clicks it in DF (dfllm cmd inspect what=curse if it names a curse)")
    if etype == "DECISION_NEEDED" and d.get("id") == "curse_kill":
        return ("ask Gordon: a kill order on the were-form (dfllm cmd squad.sortie, approve:true is the logged decision; "
                "a squad and its target position) or keep them apart in a locked room; no answer = no kill")
    if etype == "PROJECT_BLOCKED" and d.get("unreach") is not None and d.get("proj"):
        return unreach_hint(d)
    if etype == "PROJECT_BLOCKED" and d.get("idle") is not None and d.get("proj"):
        return idle_hint(d)
    if etype == "PROJECT_BLOCKED" and d.get("autocancel") is not None and d.get("proj"):
        return autocancel_hint(d)
    if etype == "PROJECT_BLOCKED" and d.get("park") is not None and d.get("proj"):
        return park_hint(d)
    return NEXT.get(etype, "dfllm brief")


def armour_note(d: dict) -> str:
    """BUG-348 (Run 15 Guildcleans: kill_lone_intruder #7150 offered a sortie with worn 43 %, the player held back by the
    80 % rule): the kernel's word on the sortie it offers, from d.worn / d.need / d.rec (military.sortie_advice)."""
    if not isinstance(d.get("worn"), int) or not isinstance(d.get("need"), int):
        return ""
    # BUG-578 (Run 16c i3 Sealcertain: the sortie against cave dragons said only 'worn 85 % >= 80 %'): odds = good | even | poor |
    # hopeless (cv = the squad's combat value, est = the foes' weight x sortie.foe_cv); poor / hopeless is never recommended
    odds = ""
    if isinstance(d.get("odds"), str) and isinstance(d.get("ours"), int) and isinstance(d.get("est"), int):
        odds = f", odds {d['odds']} (cv {d['ours']} vs ~{d['est']}, {d.get('foes', '?')} hostile(s))"
    if d.get("rec") == 1:
        return f" (sortie recommended: worn {d['worn']}% >= {d['need']}%{odds})"
    if odds and d["worn"] >= d["need"]:
        return f" (sortie NOT recommended: worn {d['worn']}% ok, but{odds[1:]}; wait)"
    return f" (sortie NOT recommended: worn {d['worn']}% < {d['need']}%{odds}; wait)"


def sortie_hint(d: dict) -> str:
    """BUG-065: an intruder holds a lockdown. A harmless one: the lockdown ends by itself at the limit, the sortie is the
    faster way; a dangerous one past the limit: the lockdown stays while it is near, the sortie is the way out."""
    cmd = d.get("cmd")
    how = f"; to send the squad{armour_note(d)}: {cmd} (approve:true is a logged decision)" if cmd else "; no squad to send"
    if d.get("hl"):
        return f"tell Gordon{how}; otherwise the lockdown ends by itself at its limit (confine.max_days)"
    return (f"tell Gordon: the lockdown stays while this one is near{how} (only if the squad can win); "
            "dfllm status shows the cause")


FARM_CMD = re.compile(r'"tpl":\s*"farms"|bp sites farms')       # BUG-641: `bp sites farms surface=1 ...` is a farm command too
SURFACE_FARM_CMD = re.compile(r'"surface":\s*1')
TRADE_FOOD_CMD = """dfllm cmd trade.want '{"add":["food","seeds"]}'"""
TRADE_DRINK_CMD = """dfllm cmd trade.want '{"add":["plant","drink","seeds"]}'"""      # BUG-641: what the thirst decision falls back to


def workable_food_cmds(d: dict, save_dir=None) -> tuple[list[str], list[str]]:
    """BUG-459 (Run 16d Orbblock y377: the famine decision offered `bp.place farms surface=1` with no second farm site, butcher.mark 'no
    animal to mark', fishing on frozen water, cooking with 156 inedible leaves): only commands that can work now. The kernel filters
    what it knows (butcher.mark only while an animal can be marked); here the farm command is dropped when the newest sites snapshot
    has no farm site (plan.farm_site, the surface plots included), and a decision left with no command gets trade.want food, seeds
    (the caravans bring what the list names; always valid). Returns (cmds, dropped: why-lines)."""
    cmds = [c for c in d.get("cmds") or [] if isinstance(c, str)]
    dropped: list[str] = []
    if save_dir is not None and any(FARM_CMD.search(c) for c in cmds):
        try:
            from .plan import farm_site
            site = farm_site(save_dir, urgent=True)
        except Exception:                               # noqa: BLE001 - no bp package / snapshot: the command stays
            site = None
        if site == "none":
            keep = [c for c in cmds if not FARM_CMD.search(c)]
            dropped.append("bp.place farms: no farm site on the newest sites snapshot (bp sites farms surface=1 finds none)")
            cmds = keep
    if not cmds or not any("trade.want" in c for c in cmds):
        # BUG-641 (Run 16c i3 Wallfree y387: the thirst decision offered the farm command in a fort whose `bp sites farms surface=1` is 0
        # for good): a thirst decision with nothing left falls back to the caravans' drink and plants, not to food
        cmds = cmds + [TRADE_DRINK_CMD if d.get("id") == "thirst" else TRADE_FOOD_CMD]
    return cmds, dropped


def food_hint(d: dict, save_dir=None) -> str:
    """BUG-340 (Run 15c/15d: the famine options `gather` and `trade.want food` could not be sent): food_low/famine carry
    d.cmds, the command lines of the options (in d.opts order); what the kernel does itself is d.auto (caravans asked for
    food and seeds, gatherers, the fishery request). The wake line is short (WAKE_TOKENS): the first command in full, the
    rest by name; `dfllm events --cls A` shows every line of d.cmds."""
    cmds, dropped = workable_food_cmds(d, save_dir)
    if not cmds:
        return NEXT["DECISION_NEEDED"]
    auto = ", ".join(str(a) for a in d.get("auto") or [])
    head = f"the kernel already: {auto}; " if auto else ""
    opts = [str(o) for o in d.get("opts") or []]
    more = f"; also {', '.join(opts[1:len(cmds)])} (d.cmds: dfllm events --cls A)" if len(cmds) > 1 and opts else ""
    gone = f" [not offered: {dropped[0]}]" if dropped else ""
    return f"{head}tell Gordon, send the option he picks as d.cmds has it: {cmds[0]}{more}{gone}"


def lone_hint(d: dict) -> str:
    """M3 (BUG-112, notes 94 and 96): a harmless lone intruder holds a SIEGE/BREACH for days. The kernel kills one inside Kern+
    itself after confine.kill_hours when a squad stands at sortie.worn; this is the question when it is still there."""
    cmd = d.get("cmd")
    how = (f"; to send the squad now{armour_note(d)}: {cmd} (approve:true is a logged decision)" if cmd
           else "; no squad to send")
    kill = f" (the kernel's own kill order: {d['kill']})" if d.get("kill") else ""
    return (f"tell Gordon{how}{kill}; otherwise the kernel releases it at confine.max_days when the soldiers stand at "
            "their stations (LOCKDOWN_END limit); dfllm events --type SORTIE says whether the soldiers arrived, killed it or "
            "stood beside it (not_attackable: DF does not treat it as an enemy)")


def hospital_supply_hint(d: dict) -> str:
    """BUG-537 (Run 16c i3: a hospital with patients and no table, splints, thread or cloth): d.gaps = the missing parts (no_table,
    no_traction, no_splints, no_thread, no_cloth), d.cmds the commands that make or buy the supplies. Yours to decide (no need to ask)."""
    gaps = ", ".join(str(g) for g in d.get("gaps") or [])
    cmds = [str(c) for c in d.get("cmds") or []]
    gaps_l = d.get("gaps") or []
    if "no_table" in gaps_l and any("furnish" in c for c in cmds):
        # BUG-623: the table is the `hospital furnish=1` project (one table inside the room that stands, a finished room project does not hold it)
        furn = " ; the table: that bp.place command puts one table inside the hospital room (plan propose drafts it too)"
    elif any(g in ("no_table", "no_traction") for g in gaps_l):
        furn = " ; a table / traction bench: build it inside the hospital zone (the hospital template places one)"
    else:
        furn = ""
    send = f"send: {cmds[0]}" + (f" (+{len(cmds) - 1} more in d.cmds)" if len(cmds) > 1 else "") if cmds else "no command makes it"
    return f"hospital lacks {gaps}: decide yourself; {send}{furn}"


def mood_thirst_hint(d: dict) -> str:
    """BUG-509 (Run 16d i4: 24 strange-mood dwarves died of thirst, children among them): a moody dwarf drinks nothing at his shop and
    his job cannot be cancelled; d.days = days to 75,000, d.missing the slots still short, d.cmds what can still be sent (the
    caravans asked, the shops on the surface). No such command: only his own finish saves him."""
    cmds = [c for c in d.get("cmds") or [] if isinstance(c, str) and "inspect" not in c]
    days = d.get("days")
    head = f"a strange-mood dwarf dies of thirst in ~{days} days" if days is not None else "a strange-mood dwarf is dying of thirst"
    if not cmds:
        return head + " and nothing is missing for his mood: nothing to send (dfllm cmd inspect what=unit key=<id>)"
    return head + "; send the commands that bring his material yourself: " + cmds[0] + (
        f" (+{len(cmds) - 1} more in d.cmds: dfllm events --cls A)" if len(cmds) > 1 else "")


def stalled_job_hint(d: dict) -> str:
    """BUG-507 (Run 16b i2 Brotherarrow: a GiveWater job hung 26 days on a child while the patient died of thirst, the player had no
    command): water found a GiveWater / GiveFood / FillPond job whose worker has not moved for days. The kernel already took the
    worker off Orderlies and removed the pond zone beside him; d.cmds has `water.unstick unit=<id>` (the same ladder at once; BUG-542:
    it never removes the hospital zone, the kernel does that itself only from the third round for a patient over water.stall_dying)
    and inspect what=unit."""
    cmds = [c for c in d.get("cmds") or [] if isinstance(c, str)]
    first = cmds[0] if cmds else "dfllm cmd water.unstick"
    return (f"a water job is stalled: send {first} yourself (it takes the worker off Orderlies and removes the pond zone beside him so "
            "the game posts the job anew; the hospital zone stays, no job is removed); dfllm cmd inspect what=unit "
            "key=<id> shows what he holds")


def dry_well_hint(d: dict) -> str:
    """BUG-541 (Run 16b i2 y386/y390, Run 16d i4 y404: 3 patients dead, the GiveWater carriers stood 26-28 days at a DRY well beside
    the hospital): water.stalls found GiveWater workers standing at a built well with no water below it while a patient is thirsty.
    d.q names the well and the nearest accepted water; d.cmds[0] = `well.retire id=<well>` (the building screen's remove; a
    cistern room's well needs approve:true), then `water.unstick unit=<id>` (the worker off Orderlies so the game posts the job anew)."""
    cmds = [c for c in d.get("cmds") or [] if isinstance(c, str)]
    return (f"{d.get('q', 'GiveWater carriers stand at a dry well')}. Send " + (f"{cmds[0]}" if cmds else "dfllm cmd well.retire id=<well>")
            + " (takes the dry well away so the carriers fill at the accepted water; a cistern's well only with approve:true)"
            + (f", then {cmds[-1]}" if len(cmds) > 1 else ""))


def no_hard_stone_hint(d: dict) -> str:
    """BUG-545 (Run 16d i4 Trumpetrealms: 101 boulders, none of them non-economic hard stone; Run 16a i1 Basementflew: every boulder out of
    reach): DF cancels rock jobs with "Needs non-economic hard stone boulders" (or the census shows boulders and none usable). The kernel
    counts stone as 0 (no rock order is queued for it) and the caravans are asked. d.cause = none | denied, d.cmds = trade.want stone and
    mechanisms, plan propose (a dig to hard stone), inspect workload. Yours to decide: wood serves doors, chests, tables, beds, coffins;
    mechanisms, stone traps and levers have no wooden form."""
    cmds = [str(c) for c in d.get("cmds") or []]
    return (f"{d.get('q', 'no non-economic hard stone')}. Decide yourself: buy it ({cmds[0] if cmds else 'dfllm cmd trade.want'}), dig to hard "
            f"stone ({cmds[1] if len(cmds) > 1 else 'dfllm plan propose'}), or go on without mechanisms and stone traps")


def released_hint(d: dict) -> str:
    """BUG-529 (Run 16a i1 Basementflew: an aqshaft stood 425 days at z124 and held the runner slot the hospital and the fortcore waited
    for): the shaft made no progress for runner.queue.release_days; the kernel gave its slot to the others (it is still measured) and
    asks. d.cmds[0] = bp.cancel (only what is not built goes), then `bp sites aqshaft --fresh` for another column."""
    cmds = [c for c in d.get("cmds") or [] if isinstance(c, str)]
    return (f"project {d.get('proj', '?')} (aqshaft) has not moved for {d.get('n', '?')} days ({d.get('cause', '?')}); the other projects "
            "run first now. Decide: fix the cause, or cancel it" + (f" ({'; then '.join(cmds[:2])})" if cmds else "")
            + " and place another column")


def seal_stalled_hint(d: dict) -> str:
    """BUG-336 (Run 15b Earthboat: the refuge hatch stalled 911 days, trolls walked down the open stair, 92 -> 1): a stuck seal
    without progress for seal_first.esc_days; d.how = what to do (build it by hand, or the other closure), d.cmd = its
    commands (bp.cancel then bp.place; none when placing it again cannot help: the refuge's hatch on the same head).
    BUG-349 (Run 15 Guildcleans i2 #7282/#7283: the player did not dare to send the bp.cancel): the fix says it is safe
    (only unbuilt pieces go) and what stays: the way in is open now and until the new piece stands; after
    plan.PERIMETER_WAIVE_D days of such a seal plan check lets the phase rise past it."""
    cmd, how = d.get("cmd"), d.get("how")
    return (f"tell Gordon: seal {d.get('proj', '?')} ({d.get('mat', '?')}) has built nothing for {d.get('n', '?')} days"
            + (f"; {how}" if how else "") + (f"; fix (safe: the bp.cancel drops only unbuilt pieces): {cmd}" if cmd else "")
            + "; until it stands that way in is open (max-pop held; the phase may rise past it after "
              f"{plan_mod.PERIMETER_WAIVE_D} d, BUG-349)")


def locked_out_hint(d: dict) -> str:
    """BUG-458 (Run 16d Orbblock y376-y377: walls the kernel put up where the doors stayed unbuilt shut the only surface farm, the manager
    and the broker outside, 23 starved): citizens (d.units) and places (d.places) stand off the main walk group beside the kernel's wall
    (d.at). d.cmd = bp.cancel reopen (quickfort undo of our wall only); then a door goes there (the kernel adds the workshop task)."""
    cmd = d.get("cmd")
    if d.get("reop"):                          # BUG-487: the kernel took the wall down itself
        return (f"our wall at {', '.join(str(a) for a in (d.get('at') or [])[:4])} shut {d.get('n', '?')} citizens "
                + (f"and {', '.join(d['places'][:3])} " if d.get("places") else "")
                + "out; the kernel designated it for removal and puts a door there (workshop task); nothing to do but watch it "
                "(dfllm status); no wall at that tile again (WALL_REFUSED keeps plan propose / seal at=audit on close=door)")
    return (f"act now: our wall at {', '.join(str(a) for a in (d.get('at') or [])[:4])} shuts {d.get('n', '?')} citizens "
            + (f"and {', '.join(d['places'][:3])} " if d.get("places") else "")
            + "off the fort (they starve outside)"
            + (f"; take the wall down: {cmd}" if cmd else "")
            + "; then dfllm cmd bp.place seal at=last (a door, made at the workshop; no wall again while they are out)")


def manager_stuck_hint(d: dict) -> str:
    """BUG-450 (Run 16a i1 y386: 35 orders unvalidated for 149 days with an appointed manager and a complete office): the manager
    holds the office and the kernel finds nothing wrong; d.cmds look at him, the orders and the offices. zone.place type=office works in
    a siege too (a second office zone for him over a chair and a table)."""
    cmds = [c for c in d.get("cmds") or [] if isinstance(c, str)]
    if d.get("out") is not None:
        # BUG-458 (Run 16d Orbblock y377: the seal's walls left the manager outside, 'MANAGER has no vacant assignment', 145 days):
        # he stands off the citizens' walk group; after economy.OUT_DAYS days appoint replace gives the post to a citizen who is inside
        rep = d.get("replace")
        return (f"tell Gordon: the manager is OUTSIDE the fort for {d.get('out')} days ({d.get('n', '?')} orders unvalidated: nothing is brewed or cooked)"
                + (f"; fix (a reachable citizen takes the post): {rep}" if rep else f"; look: {cmds[0]}" if cmds else "")
                + "; also take the walls that shut him out down (a locked_out question names them) or build the door")
    look = f"; look: {cmds[0]}" + (f" ; {cmds[1]}" if len(cmds) > 1 else "") if cmds else ""
    return ("tell Gordon: the manager validates nothing for "
            f"{d.get('days', '?')} days ({d.get('n', '?')} orders: brewing and cooking stop){look}; the kernel adds the office's chair and "
            "table and the items the orders wait for as workshop tasks; another office zone for him: dfllm cmd zone.place type=office "
            "(allowed in SIEGE); the nobles screen's replacement is the player's call")


def lockdown_long_hint(d: dict) -> str:
    """BUG-452 (Run 16a i1 y385: a lockdown held 151 days at 30 t/s, 'past the limit' and nothing followed): a lockdown past
    confine.max_days in SIEGE/BREACH (d.calm 1: nothing near or inside Kern+, the hostiles stand far); the sortie when a squad is
    able, else the wait."""
    cmd = d.get("cmd")
    how = (f"; to send the squad{armour_note(d)}: {cmd} (approve:true is a logged decision, only if the squad can win)" if cmd
           else "; no squad to send")
    return (f"tell Gordon: the lockdown has held {d.get('days', '?')} days in {d.get('mode', 'SIEGE')} "
            f"(hostiles counted: {d.get('n', '?')}, inside Kern+: {d.get('inside', 0)}{', all far' if d.get('calm') else ''}){how}; "
            "otherwise it ends with the siege (the kernel never ends it alone: threat's quiet clock takes over then)")


def siege_long_hint(d: dict) -> str:
    """BUG-331: a SIEGE calm for siege_long.days (nobody inside, every hostile far): the kernel eased it (the deep defense
    lifted, the civilians back to Kern+ or where seal keeps them: d.to); attacking is the player's call."""
    cmd = d.get("cmd")
    where = f"civilians in {d['to']}" if d.get("to") else "civilians in Kern+"   # BUG-331 review: seal's real pick
    how = (f"; to attack{armour_note(d)}: {cmd} (approve:true is a logged decision, only if the squad can win)" if cmd
           else "; no squad to send")
    return (f"tell Gordon: the siege has been calm for {d.get('days', '?')} days (nearest hostile {d.get('n', '?')} tiles), "
            f"the kernel eased it ({where}, the bridges stay up){how}; otherwise wait")


def starve_lockdown_hint(d: dict) -> str:
    """BUG-570: citizens over the hunger / thirst mark in a SIEGE lockdown. With relief the kernel put the civilians in Kern+ (the burrow
    with the stock) and unforbade food and drink; without it a hostile is near (d.near tiles, d.inside in Kern+) and only an attack
    or the refuge's own stock helps."""
    n, cmd = d.get("n", "?"), d.get("cmd")
    head = f"tell Gordon: {n} citizens are hungry or thirsty in the siege (hunger {d.get('hunger', '?')}, thirst {d.get('thirst', '?')})"
    if d.get("relief"):
        return (f"{head}; the kernel put the civilians in {d.get('to') or 'Kern+'} (food, drink) and unforbade the stock, no hostile "
                f"within reach ({d.get('near', '?')} tiles): nothing to do unless it repeats; dfllm cmd inspect what=refuge shows "
                "why the refuge could not feed them (plan: refuge_drink food=1)")
    how = (f"; to attack: {cmd} (approve:true is a logged decision, only if the squad can win)" if cmd
           else "; no squad can go: carry food to them by hand (stockpile in the refuge: bp refuge_drink food=1)")
    return (f"{head}; NOT widened: a hostile is {'inside Kern+' if d.get('inside') else str(d.get('near', '?')) + ' tiles from the fort'}"
            f"{how}")


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


def autocancel_hint(d: dict) -> str:
    """BUG-637: the kernel cancelled a project that stood build_lost for good (no undo: what it built stays, the tiles of its unbuilt
    pieces are free). d.cmd is the bp.place for the same template; check `bp sites` first, the lost site may be the cause."""
    cmd = d.get("cmd")
    again = (f"place it again: {cmd} (after dfllm bp sites {d.get('tpl') or '<tpl>'} --fresh shows a site; surface=1 without a "
             "fortcore floor)") if cmd else "the next audit places a seal again if one is still needed"
    return f"tell Gordon what was cancelled and why (d.msg); {again}"


def unreach_hint(d: dict) -> str:
    """BUG-352: a dig stage no citizen reaches (its tiles lie in another walk group, e.g. across a brook) stands still. The
    cancel drops only the unbuilt pieces; `bp sites` lists the sites the citizens reach (it shows the walk group)."""
    p = d["proj"]
    tpl = d.get("tpl") or "<tpl>"
    return (f"safe: dfllm cmd bp.cancel '{{\"proj\":\"{p}\"}}' (drops only the unbuilt pieces), then dfllm bp sites {tpl} "
            f"--fresh (only sites the citizens reach) and bp.place tpl={tpl} site=S1 again; the project's old dig "
            "designations stay: dfllm cmd inspect what=workload names the unreachable jobs")


def idle_hint(d: dict) -> str:
    """BUG-328: a project without progress for runner queue.idle_days was set aside (no runner slot, measured now and then;
    it comes back by itself when DF's workers finish a piece). The line's `waits:` names what it waits for."""
    p = d["proj"]
    return (f"tell Gordon what it waits for (dfllm cmd inspect what=projects); fix that, then dfllm cmd bp.resume "
            f"'{{\"proj\":\"{p}\"}}', or once he agrees bp.cancel it (its unbuilt pieces go with it)")


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
                "for) as workshop tasks itself (MANAGER_BYPASS); no office zone: dfllm cmd bp.place tpl=office site=S1 (p.surface=1 without a dug core; follow places it itself, BUG-396)")

# BUG-055 (Run 14 y577: the CHIEF_MEDICAL_DWARF office stood vacant for good; Run 11 note 25: squads without a leader):
# readiness R0 office; the line's msg carries the exact command
OFFICE_HINT = ("a vacant office or squads without a leader: dfllm cmd inspect '{\"what\":\"offices\"}', then "
               "dfllm cmd appoint / squad.create / squad.leader (the msg names the unit)")

# BUG-117 (Run 14 note 92) readiness R0 mood_ws: moodable workshop types missing; the line's msg carries the command
MOOD_WS_HINT = ("moodable workshops missing: run the bp.place command the line names (dfllm cmd bp.place "
                "'{\"tpl\":\"workshops\",\"site\":\"S1\",\"p\":{\"only\":\"Loom\"}}'); follow places the rest "
                "(BUG-394: on the surface when no fortcore site is free)")


SHOW_FIGHT = ("SIEGE", "BREACH", "ALERT", "DRILL")     # viewlib.lua V.FIGHT: the camera is the player's there
SHOW_CAUSE = ("BREACH", "SIEGE_START", "INVASION", "LOCKDOWN")      # no unit in their d: the lockdown's cause in the state


def view_target(etype: str, d: dict, state: dict | None = None) -> str | None:
    """FR-88: the target of a ready `view` for an event: its unit (d.id for INTRUDER/PREDATOR/INVASION, d.unit for the mood
    types, the first of d.units for patients), else its position (d.pos 'x,y,z'); the SHOW_CAUSE types take the lockdown's
    cause (state alarm.by id, else its pos). None when the event names nothing to look at."""
    def num(v):
        return v if isinstance(v, int) and not isinstance(v, bool) and v >= 0 else None
    uid = num(d.get("id")) if etype in ("INTRUDER", "PREDATOR", "INVASION", "WATER_PREDATOR") else (None if etype == "DROWNED" else num(d.get("unit")))
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
              review: str = "", save_dir=None) -> str:
    """'WAKE y3 sum d20 PEACE | SIEGE_END: msg | GATE_FAIL x2: msg | next: ...' within WAKE_TOKENS. DECISIONS 2: with
    follow --no-auto (auto False) and ways in without door or bridge, every wake line says 'auto-seal off, N openings'.
    FR-86: `review` (plan.review_note: PLAN STALE, the ERROR fixes of this year's draft) rides on the YEAR_REVIEW item."""
    t = (state or {}).get("t") or {}
    when = fmt_tick(t.get("abs", t["y"] * schema.TICKS["YEAR"] + t["tick"])) if t else "?"
    head = f"WAKE {when} {(state or {}).get('mode', '?')}"
    types = sorted(burst, key=_prio)
    ns = [p["n0"] for p in burst.values() if isinstance(p.get("n0"), int)]
    hint = next_hint(types[0], burst[types[0]]["e"], save_dir)
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
        self._stale_read = 0.0
        self._stale_tried: dict[str, float] = {}     # BUG-435: project id -> wall of the last cancel try
        self._orphan_read = 0.0                      # BUG-442: wall of the last orphan sweep
        self._core_gate_said: dict[str, int] = {}    # BUG-441: how often the core gate said DECISION_NEEDED, per kind
        self._core_site_read = 0.0                   # BUG-441: wall of the last core-site look
        self._core_site_tried: dict[str, float] = {}     # BUG-441: project id -> wall of the last re-site cancel
        self._beat = -1e18
        self._stall: dict = {}                       # BUG-475: tick (heartbeat), since (wall it was first seen), told (wall of the wake)
        self._pdf: dict = {}                         # BUG-614: owner (df / popup), since (wall follow first saw the pause), told

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
        self._orphan_read = 0.0                # BUG-442: a new save folder / reload: the bp files are asked about again
        self._core_gate_said = {}
        files.prune_snaps(d)

    def _fresh_jobs(self, jobs: dict) -> dict:
        """Drop auto jobs a previous follow process left unfinished (their replies are gone); keep cooldowns."""
        now, out = self.clock(), {}

        def fresh(j):
            return isinstance(j, dict) and now - (j.get("since") or 0) <= AUTO_SNAP_TIMEOUT_S
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
        self._check_stall(now)
        self._check_paused(now)
        self._check_supervise(now)
        self._check_quicksave(now)
        self._check_plan(now)
        self._check_stale(now)
        self._sweep_orphans(now)
        self._check_core_site(now)
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
            line = wake_line(burst, state, auto=self.auto, review=review, save_dir=self.dir)
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
            elif t == "PROJECT_REQUEST" and d.get("tpl") == "farms" and d.get("why") in ("drink", "drink_surface"):
                # BUG-406/408: brewable seeds in stock fit no farm plot (a surface crop, only an underground plot; or no plot at
                # all): one plot of their kind. why=drink_surface: p.surface = 1 (soil or mud floor, in PEACE; economy asks then)
                fp: dict = {"plots": 1}
                if d.get("why") == "drink_surface":
                    fp["surface"] = 1
                self._request_place("farms", "farms", fp, "S1", now, prio=1)
            elif t == "PROJECT_REQUEST" and d.get("tpl") == "cistern" and d.get("why") in ("no_water", "patient_water"):
                self._request_access(d, now)
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
                    d.get("why") in ("mandatory", "slabs", "busy", "manager", "missing", "gear", "well", "masonry", "trade", "cut")
                    or (d.get("why") == "mood" and d.get("types"))):
                # BUG-283 (Run 15 Drillchamber: the glass furnace a fey mood waited for came 30 days late in a plain
                # 12-shop placement at prio 4): why=mood with types = only the shops the mood and its materials need, prio 1
                # FR-76 (Run 12 Trussroads, reclaimed: no carpenter, no craftsdwarf, no kitchen): the types the runner
                # saw missing on the map, whatever the fort manifest lists (kept by `need`, BUG-066). BUG-133: economy's
                # why=slabs (ghosts wait for memorial slabs, no mason's workshop stands) the same way: the Masons alone.
                # BUG-224: why=busy (one Carpenters/Masons holds the waiting jobs, idle workers stand): one more of it
                # BUG-231: why=manager (the held manager orders' items go to a Carpenters/Masons as tasks; none stands)
                # BUG-267: why=missing (orders wait 14+ days for these shops); BUG-270: why=gear (Leatherworks, Tanners,
                # Mechanics for gear and lever mechanisms); why=well (fix6-water: the hospital well's shop); BUG-473 why=masonry
                # (an aqshaft level with soil walls and no Masons workshop: the Masons alone, prio 1)
                # BUG-654 (Run 16a i1 Basementflew: the only Kitchen, Carpenters and Mechanics stood in a flooded level, meals 0 for years):
                # why=cut = the shop types whose every shop stands off the citizens' walk groups; a new one, kept although the manifest
                # lists the cut-off one (`need`), on the citizens' walk group (the surface ranking reads it; BUG-394 tries it too)
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
            elif t == "PROJECT_REQUEST" and d.get("tpl") == "office" and d.get("why") == "office":
                # BUG-396 (Run 16a i1: no office for 294 days, the manager validated nothing, drink 0): the manager's office,
                # on the surface when there is no dug core to hang one on; never twice (an office project exists)
                from .plan import _has_z4, applied_builds, surface_core_on
                if not any(t2 == "office" for t2, _ in applied_builds(self.dir, files.read_state(self.dir))):
                    # BUG-413: no surface office unless plan.surface_core; without a dug core the office waits for the fortcore
                    if _has_z4(self.dir) or surface_core_on():
                        self._request_place("office", "office", {} if _has_z4(self.dir) else {"surface": 1}, "S1", now, prio=1)
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
                                             "pid": os.getpid(),  # BUG-385: status names the owner
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

    def _popup_words(self) -> str:
        """BUG-475: the newest popup text the kernel logged (PAUSED_BY_DF popup, POPUP_GONE text), read-only; '' when none."""
        try:
            for e in reversed(files.tail_events(self.dir, 0, limit=3, types={"PAUSED_BY_DF", "POPUP_GONE"})):
                d = e.get("d") if isinstance(e.get("d"), dict) else {}
                t = d.get("popup") or d.get("text")
                if isinstance(t, str) and t:
                    return f'{e["type"]} #{e.get("n")}: "{clip(t, 60)}"'
        except Exception:                      # noqa: BLE001 - a courtesy to the wake line
            pass
        return ""

    def _check_stall(self, now: float) -> None:
        """BUG-475 (Run 16 i1 Syrupobeyed Pop 1, i4 Mazelanterns Pop 1-2: '0 t/s, not paused', heartbeat ok; i2: status 'pause:popup'
        with no wording): the kernel beats but the game tick has not moved for STALL_S real seconds although nothing of ours
        (the player's pause, the inbox hold, a load) explains it. One TICK_STALL wake per stall (again after STALL_AGAIN_S) names
        the owner of the pause (state owners.pause), the popup text the kernel logged, and what may be done: pause:df / pause:popup
        -> `dfllm cmd resume` (the kernel reads the popup, refuses threat or curse words, presses the pause key); a stall with
        no pause and no popup the kernel can list is a screen the kernel cannot see or close (read-only here, nothing is
        clicked): the player presses Esc / Enter in DF. A paused game by the player (gordon) or the inbox is no stall."""
        if self.dir is None or paths.active_save() != self.dir.name:
            self._stall = {}
            return
        hb, age = files.read_heartbeat(self.dir, now)
        tick = (hb or {}).get("tick")
        if hb is None or age is None or not isinstance(tick, int) or isinstance(tick, bool):
            self._stall = {}
            return
        try:
            mt = (self.dir / "heartbeat").stat().st_mtime
        except OSError:
            self._stall = {}
            return
        st = self._stall
        if st.get("tick") != tick:
            self._stall = {"tick": tick, "since": now, "mt": mt, "mt_at": now}
            return
        if mt != st.get("mt"):                 # the kernel rewrote the heartbeat: it runs (the file's age is no clock of ours)
            st["mt"], st["mt_at"] = mt, now
        if now - st.get("mt_at", now) > STALL_HB_MAX_S:
            st.pop("told", None)               # the kernel does not beat: HB_STALE's case, not a stall of the game
            st["since"] = now
            return
        state = files.read_state(self.dir) or {}
        owner = ((state.get("owners") or {}).get("pause")) if isinstance(state.get("owners"), dict) else None
        paused = bool(hb.get("paused"))
        if paused and owner not in ("df", "popup"):
            st["since"] = now                  # the player's or the inbox's own pause: not ours to report
            return
        cap = (state.get("clock") or {}).get("cap") if isinstance(state.get("clock"), dict) else None
        if cap == 0 or now - st.get("since", now) < STALL_S:
            return
        told = st.get("told")
        if told is not None and now - told < STALL_AGAIN_S:
            return
        st["told"] = now
        secs = int(now - st["since"])
        words = self._popup_words()
        if owner in ("df", "popup"):
            what, hint = f"paused by {owner}", "dfllm cmd resume may release it"
        else:
            what, hint = "not paused", "no popup the kernel lists: Gordon presses Esc/Enter in DF"
        self._synth("TICK_STALL", f"BUG-475 tick {tick} static {secs} s, {what}, kernel beats; "
                    f"{words or 'no popup text logged'}; {hint}", now)

    def _check_paused(self, now: float) -> None:
        """BUG-614 (Run 16 i1/i2/i4: after a DF restart or a save load the kernel stays pause:df, `status` showed 'pause:df' in
        the first line and `follow --takeover` said nothing; the player did not know `dfllm cmd resume` runs the game, TICK_STALL
        comes after 120 s and the kernel's PAUSED_BY_DF after 5 min): the game stands paused by DF (a load, a restart) or a
        popup for PAUSED_HINT_S real seconds while the kernel beats -> one PAUSED_BY_DF wake per pause that names the command.
        A pause of the player (gordon) or of the inbox is not ours to report."""
        if self.dir is None or paths.active_save() != self.dir.name:
            self._pdf = {}
            return
        hb, age = files.read_heartbeat(self.dir, now)
        if hb is None or age is None or age > STALL_HB_MAX_S or not hb.get("paused"):
            self._pdf = {}
            return
        state = files.read_state(self.dir) or {}
        owner = ((state.get("owners") or {}).get("pause")) if isinstance(state.get("owners"), dict) else None
        if owner not in ("df", "popup"):
            self._pdf = {}
            return
        st = self._pdf
        if st.get("owner") != owner:
            self._pdf = {"owner": owner, "since": now}
            return
        if st.get("told") is not None or now - st["since"] < PAUSED_HINT_S:
            return
        st["told"] = now
        words = self._popup_words()
        self._synth("PAUSED_BY_DF", f"PAUSED_BY_DF {int(now - st['since'])} s (pause:{owner}, a load or restart leaves the game so; "
                    f"nothing runs): dfllm cmd resume" + (f"; {words}" if words else ""), now)

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

    def _check_stale(self, now: float) -> None:
        """BUG-435 (Run 16d i4 Mazelanterns y401: traps 912 d, tombs 461 d 'waits for trapparts', fortcore 341 d, nine projects set aside
        for ever and clogging the brief): in PEACE a project that says `set aside N d` with N >= plan.stale_project_days (0 = off;
        follow --no-auto never) and is a plan.STALE_CANCEL_TPLS template gets a plain bp.cancel (only what is not built goes; the
        file moves to bp/.cancelled) and PROJECT_STALE says what and why: `plan propose` then draws the template again, and the
        kernel orders the mechanisms its planned traps wait for (economy.plan_mech). A refused cancel is tried again after
        STALE_RETRY_S. The core, the seals and the water builds are never cancelled here (the kernel's PROJECT_BLOCKED why=stale)."""
        if not self.auto or self.dir is None or now - self._stale_read < STALE_CHECK_EVERY_S:
            return
        self._stale_read = now
        try:
            days = plan_mod.stale_project_days()
            state = files.read_state(self.dir)
            if days <= 0 or (state or {}).get("mode") != "PEACE":
                return
            rows = plan_mod.stale_projects(self.dir, state, days)
            sent = []
            for r in rows:
                if now - self._stale_tried.get(r["proj"], -1e18) < STALE_RETRY_S:
                    continue
                self._stale_tried[r["proj"]] = now
                self._send("bp.cancel", {"proj": r["proj"]}, f"stale cancel {r['proj']}", now)
                sent.append(f"{r['proj']} ({r['tpl']}, {r['days']} d: {r['why']})")
            if sent:
                self._synth("PROJECT_STALE", f"cancelled after {days}+ days set aside: " + "; ".join(sent[:4])
                            + (f" (+{len(sent) - 4} more)" if len(sent) > 4 else ""), now)
        except Exception as ex:                        # noqa: BLE001 - the stale check must never stop the follower
            self._fail("stale projects", f"{type(ex).__name__}: {ex}", now)

    def _check_core_site(self, now: float) -> None:
        """BUG-441 (Run 16b i2 Roadvises, 16c i3 Castletongs): a fortcore stage 1 that was queued before the aquifer was known and has
        no tile dug yet (plan.core_over_aquifer: CORE_UNSTARTED_PCT = 0 %, its deepest level not under the lowest known aquifer level)
        is re-sited: a plain bp.cancel (the file moves to bp/.cancelled), PROJECT_STALE says why plus DECISION_NEEDED with the command,
        and `plan propose` draws aqshaft@S1 and the core below the aquifer (plan.surface_facts / aquifer_route). A core with ANY dug
        tile is never cancelled here (review of round 28: i2 Roadvises had a blocked stage-1 core): DECISION_NEEDED says it reaches
        into the aquifer and what to do. Never with --no-auto, never in a fight; the same project is said once per STALE_RETRY_S."""
        if not self.auto or self.dir is None or now - self._core_site_read < CORE_SITE_EVERY_S:
            return
        self._core_site_read = now
        try:
            state = files.read_state(self.dir)
            if (state or {}).get("mode") != "PEACE":
                return
            hit = plan_mod.core_over_aquifer(self.dir, state)
            if not hit or now - self._core_site_tried.get(hit["proj"], -1e18) < STALE_RETRY_S:
                return
            self._core_site_tried[hit["proj"]] = now
            if hit.get("started"):
                self._synth("DECISION_NEEDED", f"BUG-441 core_over_aquifer: {hit['why']}; it has {hit.get('pct')} % dug, so follow does "
                            "not cancel it and the fort keeps a core that reaches into the aquifer. Decide: let it finish and pass "
                            f"the aquifer with `dfllm plan propose` (aqshaft@S1, later stages below), or take it back with "
                            f"`dfllm cmd bp.cancel '{{\"proj\":\"{hit['proj']}\"}}'` and re-site", now)
                return
            self._send("bp.cancel", {"proj": hit["proj"]}, f"core re-site {hit['proj']}", now)
            self._synth("PROJECT_STALE", f"BUG-441: {hit['why']}: the core was queued before the aquifer was known; cancelled (nothing "
                        "dug yet). dfllm plan propose drafts the aqshaft through every aquifer level and the core "
                        "below the lowest", now)
            self._synth("DECISION_NEEDED", f"BUG-441 core_resite: the fort has no core now ({hit['proj']} cancelled): run `dfllm plan "
                        "propose` (aqshaft@S1 through the aquifer, the core below it) and `plan apply`", now)
        except Exception as ex:                        # noqa: BLE001 - the core-site check must never stop the follower
            self._fail("core re-site", f"{type(ex).__name__}: {ex}", now)

    def _core_gate_escape(self, kind: str, gate: dict, now: float) -> bool:
        """Review of round 28 (BUG-441): the core gate must not block the core for ever. The first time a probe is stalled / too
        short / cannot be placed, say it (PROJECT_BLOCKED for a stalled probe, DECISION_NEEDED with the commands) and keep the core
        back (False); the next ask of the starter places the core as before the gate (True), the re-site (_check_core_site) and
        `plan propose` stay the way to a core under the aquifer."""
        n = self._core_gate_said.get(kind, 0)
        self._core_gate_said[kind] = n + 1
        if n:
            files.log_cli(self.dir, "follow", "auto:core", {"gate": kind}, "BUG-441: " + gate["why"] + "; the core is placed anyway")
            return True
        pid = gate.get("proj") or ""
        if kind == "stalled":
            self._synth("PROJECT_BLOCKED", f"BUG-441 why=stalled: the aquifer probe {pid} does not finish ({gate['why']})", now)
        cmds = {"stalled": f"`dfllm cmd bp.cancel '{{\"proj\":\"{pid}\"}}'` takes the probe back (follow probes again), or `plan.core_probe = false` "
                           "in config/baseline.json places the core without a probe",
                "short": "`dfllm plan propose` drafts aqshaft@S1 through the aquifer when you know its levels, or `plan.core_probe = false` "
                         "in config/baseline.json places the core without the probe's answer",
                "noprobe": "name a column: `dfllm cmd bp.place '{\"tpl\":\"aqshaft\",\"site\":\"S1\",\"p\":{\"x\":X,\"y\":Y,\"top\":Z,"
                           "\"depth\":12}}'` (open surface floor, rock beneath, no water within 4 tiles), or `plan.core_probe = false` in "
                           "config/baseline.json"}[kind]
        self._synth("DECISION_NEEDED", f"BUG-441 core_probe_{kind}: {gate['why']}. {cmds}. If nothing is decided follow places the core "
                    "at its next ask", now)
        return False

    def _sweep_orphans(self, now: float) -> None:
        """BUG-442 (Run 16b i2 Roadvises: bp/y372s0b0.json, a project the kernel did not know ('no project y372s0b0'), blocked every
        new fortcore stage 1 for a year; retire() ran only after an ok bp.cancel and the player may not delete in dfllm-runtime): at
        start and every ORPHAN_EVERY_S follow asks the kernel (`inspect persist key=bp.<id> field=tpl`, no wait) about the few bp
        files that may be orphans (cmd.orphan_candidates); the reply (_read_replies) retires the ones it does not hold. A fort heals
        itself after a reload. Never with --no-auto."""
        if not self.auto or self.dir is None or now - self._orphan_read < ORPHAN_EVERY_S:
            return
        if self._orphan_read == 0.0:           # first look at a save folder: after ORPHAN_FIRST_S (the kernel is loading, the reply is slow)
            self._orphan_read = now - ORPHAN_EVERY_S + ORPHAN_FIRST_S
            return
        self._orphan_read = now
        try:
            from .cmd import orphan_candidates
            asked = {r.get("orphan") for r in (self.jobs.get("replies") or {}).values()}
            for pid in orphan_candidates(self.dir):
                if pid in asked:
                    continue
                cid = self._send("inspect", {"what": "persist", "key": f"bp.{pid}", "field": "tpl"}, f"orphan check {pid}", now)
                self.jobs["replies"][cid]["orphan"] = pid
        except Exception as ex:                        # noqa: BLE001 - the sweep must never stop the follower
            self._fail("orphan sweep", f"{type(ex).__name__}: {ex}", now)

    def _send(self, verb: str, args: dict, what: str | None, now: float, snap: dict | None = None,
              need: list | None = None) -> str:
        """Send without waiting; with `what`, the reply is read in _run_jobs (refusal/timeout -> AUTO_FAIL)."""
        from .cmd import send
        cid, _ = send(self.dir, verb, args, by="follow", wait_s=0, snap=snap, need=tuple(need or ()))
        if what:
            self.jobs.setdefault("replies", {})[cid] = {"verb": verb, "what": what, "since": now,
                                                        "tpl": args.get("tpl"), "proj": args.get("proj")}
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
        if job and now - job.get("since", 0) < (AUTO_SNAP_TIMEOUT_S if not job.get("placed") else TOMBS_COOLDOWN_S):
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

    def _request_access(self, d: dict, now: float) -> None:
        """BUG-424 (Run 16a i1 Manorsubtle: the brook lay in a rock gully 8 tiles from the start room, 13 of 15 died of thirst, the
        player could not dig there by the water rule): economy's PROJECT_REQUEST cistern why=no_water carries the water tile nearest
        to the fort (d.at). One piped cistern per fort (a cistern project with a pipe stands or is placed: nothing more); the
        snapshot decides the route in `_place` (sites.cistern_access)."""
        at = d.get("at")
        has_at = isinstance(at, list) and len(at) == 3 and all(isinstance(v, int) and not isinstance(v, bool) for v in at)
        if not has_at and d.get("why") != "patient_water":
            return
        from .cmd import bp_files
        for f in bp_files(self.dir):
            doc = files.read_json(f)
            prm = doc.get("params") if isinstance(doc, dict) and isinstance(doc.get("params"), dict) else {}
            if isinstance(doc, dict) and doc.get("tpl") == "cistern" and (prm.get("path") or prm.get("water") == "aquifer"):
                return                       # BUG-448: an aquifer cistern (no pipe) brings its own water as well
        if not has_at:
            # BUG-469 (Run 16d i4: PROJECT_REQUEST cistern why=patient_water carried no tile, nothing was placed, the mayor died of thirst
            # beside 4899 d of barrel drink): no water body to pipe from; the aquifer cistern (cmd.cistern_fill_guard refuses it
            # without a known aquifer level, and the plain one when no water lies within reach)
            self._request_place("cistern_water", "cistern", {"water": "aquifer"}, "S1", now, prio=1)
            return
        if self._request_place("cistern_water", "cistern", {}, "S1", now, prio=1):
            self.jobs["cistern_water"].update(access=True, at=at)

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
        # BUG-487: a wall the kernel's reach check refused (WALL_REFUSED) is asked for as a door
        params = {"at": "audit", "close": "door"} if a.get("cut") else {"at": "audit"}
        if not self._request_place("seal", "seal", params, "S1", now):
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
                elif now - job["since"] > AUTO_SNAP_TIMEOUT_S:
                    del self.jobs[key]
                    self._fail(job.get("tpl", key), f"no sites snapshot within {AUTO_SNAP_TIMEOUT_S}s (BUG-639: the export of a big box "
                               "takes minutes; dfllm cmd inspect what=snapshot, then dfllm bp sites <tpl> --fresh)", now)

    def _read_replies(self, now: float) -> None:
        """Outbox replies of auto commands: ok -> done; ok:false or none in time -> AUTO_FAIL."""
        replies = self.jobs.get("replies") or {}
        for cid, r in list(replies.items()):
            reply = files.read_outbox(self.dir, cid)
            if reply is None and now - r.get("since", 0) <= (AUTO_SNAP_TIMEOUT_S if r.get("verb") == "snapshot" else AUTO_TIMEOUT_S):
                continue
            del replies[cid]
            key = next((k for k in PLACE_KEYS if self.jobs.get(k) is not None
                        and cid in (self.jobs[k].get("snap"), self.jobs[k].get("placed"))), None)
            job = self.jobs.get(key) if key else None
            mine = job is not None
            if reply is None:
                if r.get("orphan"):
                    continue                   # BUG-442: no kernel answer (DF closed): asked again at the next sweep, no AUTO_FAIL
                if mine and r["verb"] == "snapshot":
                    del self.jobs[key]         # no second 'no sites snapshot' fail for the same cause
                self._fail(r["what"], f"no reply to {r['verb']} {cid} within "
                           f"{AUTO_SNAP_TIMEOUT_S if r['verb'] == 'snapshot' else AUTO_TIMEOUT_S}s", now)
                continue
            files.log_cli(self.dir, "follow", f"reply:{r['verb']}", {"id": cid},
                          ("ok " if reply.get("ok") else "ERR ") + str(reply.get("msg", "")))
            if r.get("orphan"):                # BUG-442: the kernel's answer to 'do you hold this project?'
                from .cmd import kernel_knows, retire_orphan
                if kernel_knows(reply) is False and retire_orphan(self.dir, r["orphan"]):
                    files.log_cli(self.dir, "follow", "retire:orphan", {"proj": r["orphan"]},
                                  "the kernel does not know this project: bp file retired")
                continue
            if reply.get("ok"):
                if r["verb"] == "bp.cancel" and isinstance(r.get("proj"), str):
                    from .cmd import retire        # BUG-435: the file moves to bp/.cancelled (send(wait_s>0) does it for the CLI)
                    retire(self.dir, r["proj"])
                continue
            if r["verb"] == "bp.cancel" and isinstance(r.get("proj"), str) and "no project " in str(reply.get("msg", "")):
                from .cmd import retire_orphan     # BUG-442: the kernel has no such project: the file goes (unless it may be a finished one)
                retire_orphan(self.dir, r["proj"])
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
            if job.get("access"):
                # BUG-424: the cistern's pipe and intake from the water nearest to the fort, planned on this snapshot
                from .cmd import fort_manifest, load_bp
                acc = load_bp("sites").cistern_access(snap, fort_manifest(self.dir), near=job.get("at"), radius=20)
                at = ",".join(str(v) for v in job.get("at") or [])
                if acc["plan"] is None:
                    raise BpError(f"BUG-424: no safe access to the water at {at}: {acc['why']} (dfllm cmd inspect what=water_sources; "
                                  "bp sites cistern --near; dig the core toward the water; trade for drink and plants)")
                if acc["unsafe"]:
                    raise BpError(f"BUG-424: the only cistern route to the water at {at} needs water above the well room (the "
                                  "floodgate and breaker alone keep it out): tell Gordon; python -m dfpilot.bp.sites cistern --near "
                                  f"{at} --unsafe prints it")
                args["p"], args["site"] = acc["plan"]["params"], acc["site"]
            if isinstance(job.get("prio"), int):
                args["prio"] = job["prio"]
            prev = files.read_json(_placed(self.dir, tpl))
            need = job.get("need") if isinstance(job.get("need"), list) else None
            ap = args.get("p") or {}
            if tpl == "fortcore" and not ap.get("retrofit") and not ap.get("aquifer") and (ap.get("stage") or 1) == 1 \
                    and re.fullmatch(r"S[0-9]+", str(args["site"])):
                from .plan import core_probe_args, core_span_gate, wet_core_guard
                # BUG-419 (Run 16b i2 #5420: a wet fortcore, score 0, placed after PLAN_EXHAUSTED): never a wet site by itself
                wp, why = wet_core_guard(self.dir, args.get("p"), snap)
                if wp is None:
                    raise BpError(why)
                if wp != (args.get("p") or {}):
                    args["p"] = wp
                # BUG-441 (Run 16b i2, 16c i3: follow queued the fortcore 1 minute after adopt, before the aquifer was known; it
                # landed above and in it and the aqshaft sites lay beside it): no fortcore of its own before the span is known
                gate = core_span_gate(self.dir, args.get("p"), snap)
                if gate["action"] in ("refuse", "wait"):
                    raise BpError(gate["why"])
                if gate["action"] in ("stalled", "short"):
                    # review of round 28: a probe that never finishes (BUG-443/444) or stopped above the aquifer must not hold the
                    # core for ever: PROJECT_BLOCKED + DECISION_NEEDED once, the next ask places the core as before
                    if not self._core_gate_escape(gate["action"], gate, now):
                        raise BpError(gate["why"])
                elif gate["action"] == "probe":
                    # review of round 28: a fresh embark has no core and no manifest zones.Z4, the ranked `aqshaft site=S1` can never be
                    # placed: the probe is a surface column near the embark centre (plan.core_probe_args), checked by cmd.place
                    pargs, pwhy = core_probe_args(self.dir, snap)
                    if pargs is None:
                        if not self._core_gate_escape("noprobe", {"why": pwhy, "proj": ""}, now):
                            raise BpError(f"{gate['why']}: no probe column fits ({pwhy})")
                    else:
                        tpl, args = "aqshaft", pargs       # the probe shaft goes first; the starter asks again at the next PLAN_EXHAUSTED
                        prev = files.read_json(_placed(self.dir, tpl))
                        files.log_cli(self.dir, "follow", "auto:probe", args, gate["why"] + "; " + pwhy)
            if tpl == "farms":
                cid = self._place_farms(args, now, snap)
            elif tpl == "workshops" and key != "starter":
                cid = self._place_workshops(args, now, snap, need)
            else:
                cid = self._send("bp.place", args, tpl, now, snap=snap, need=need)
        except Exception as e:                 # noqa: BLE001 - WP3 bugs included: one AUTO_FAIL, job dropped
            self.jobs.pop(key, None)
            self._fail(tpl, e, now)
            if tpl == "farms" and isinstance(e, BpError):
                self._waive_farms(str(e), now)
            return
        job.update(placed=cid, since=now, prev=prev if isinstance(prev, dict) else None)
        files.log_cli(self.dir, "follow", f"auto:{key}", args, f"placed {cid}")


    def _place_workshops(self, args: dict, now: float, snap: dict, need: list | None) -> str:
        """BUG-394 (Run 16a i1 Bachwald: a Possessed dwarf waited for 'no Craftsdwarfs' until the shop was placed by hand, the
        kernel's mood request answered `only 0 free site(s) for workshops` 25 times; i2/i3 the same, no fortcore room site):
        a request for named shops (skip/add: the mood's, mandatory, missing ...) that finds no room site is tried again as the
        startup style `surface = 1`, on open surface floor with no fortcore, in PEACE (workshop_tries). The first that places
        is sent; none: the first error with the surface one behind it."""
        from .cmd import BpError
        st = files.read_state(self.dir) or {}
        first = last = None
        tries = workshop_tries(args.get("p") or {}, st.get("mode"))
        for p in tries:
            try:
                cid = self._send("bp.place", {**args, "p": p}, "workshops", now, snap=snap, need=need)
            except BpError as e:
                first = first or e
                last = e
                continue
            if p != (args.get("p") or {}):
                files.log_cli(self.dir, "follow", "auto:workshops", {"p": p},
                              f"BUG-394: no room site for {args.get('p')}: placed on the surface")
            args["p"] = p
            return cid
        if first is not None and last is not first:
            raise BpError(f"{first}; BUG-394: surface=1 too: {last}")
        raise first if first else BpError("workshops: nothing to try")

    def _place_farms(self, args: dict, now: float, snap: dict) -> str:
        """BUG-340 (Run 15d Drillchamber y379-y382: 220 AUTO_FAIL `only 0 free site(s) for farms plots=2` while food fell to
        0 days; the plans placed three surface farms plots=1 that fed the fort, one a year): economy's farms request tries
        the farms room at its plots, then fewer plots (farm_tries), then in PEACE a surface farm on soil floor (cmd.place
        falls back to fewer surface plots itself, BUG-316). The first that places is sent; none: the first error."""
        from .cmd import BpError
        st = files.read_state(self.dir) or {}
        first = None
        for p in farm_tries(args.get("p") or {}, st.get("mode"), urgent=food_urgent(st)):
            try:
                cid = self._send("bp.place", {**args, "p": p}, "farms", now, snap=snap)
            except BpError as e:
                first = first or e
                continue
            if p != (args.get("p") or {}):
                files.log_cli(self.dir, "follow", "auto:farms", {"p": p},
                              f"BUG-340: no farms site for {args.get('p')}: placed with {p}")
            args["p"] = p
            return cid
        raise first if first else BpError("farms: nothing to try")

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
        if farm_site(self.dir, urgent=food_urgent(st)) != "none":
            return
        self.jobs["waive"] = {"since": now}
        try:
            self._send("phase.waive", {"tpl": "farms", "why": "bp sites farms: 0 room and 0 surface sites"}, None, now)
        except Exception as e:                 # noqa: BLE001
            return self._fail("phase.waive farms", e, now)
        files.log_cli(self.dir, "follow", "auto:waive", {"tpl": "farms", "phase": st.get("phase")},
                      f"no farm site at all: deliverable farms of {st.get('phase')} waived")


def workshop_tries(params: dict, mode: str | None) -> list[dict]:
    """BUG-394: the workshops params follow tries in order: the request's (a room of the fortcore), then in PEACE (BUG-302:
    builders on the surface only then) the same shops as the startup style p.surface = 1. Only a named selection (skip/add)
    gets the second try: surface=1 without them is the four startup shops, not what a plain 12-shop request asks for."""
    p = dict(params or {})
    if p.get("surface") or not (p.get("skip") or p.get("add")) or mode != "PEACE":
        return [p]
    return [p, {**p, "surface": 1}]


def _surface_core_on() -> bool:
    from .plan import surface_core_on
    return surface_core_on()


def food_urgent(st: dict | None) -> bool:
    """BUG-460: the food days are below plan.FOOD_DRAFT_D (60): a surface farm is tried although plan.surface_core is off.
    BUG-605 (Run 16c i3 Wallfree: drink 0 days for four years, 56 seeds and no plot, food 331 days): so are the drink days below
    plan.DRINK_DRAFT_D (30), a still with nothing to brew."""
    from .plan import farm_low
    return farm_low(st) is not None


def farm_tries(params: dict, mode: str | None, urgent: bool = False) -> list[dict]:
    """BUG-340: the farms params follow tries in order: the request's (a farms room at its plots), the same room with fewer
    plots (plots - 1 .. 1), and in PEACE (BUG-302: builders on the surface only then) a surface farm p.surface = 1 at the
    request's plots. A surface request stays as it is (cmd.place falls back to fewer plots, BUG-316). BUG-460: `urgent` (food
    below plan.FOOD_DRAFT_D) tries the surface farm with plan.surface_core off too."""
    p = dict(params or {})
    if p.get("surface"):
        return [p]
    n = p.get("plots") if isinstance(p.get("plots"), int) and not isinstance(p.get("plots"), bool) else 2
    out = [p] + [{**p, "plots": k} for k in range(n - 1, 0, -1)]
    if mode == "PEACE" and (urgent or _surface_core_on()):   # BUG-413: surface farm plots only when plan.surface_core allows them
        out.append({**p, "plots": n, "surface": 1})
    return out


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
    if t.get("via"):                           # BUG-564: a stair / hatch / door / bridge no wall fits
        out.append(f"counted with {t['via']} bypass tile(s) of a stair, hatch, door or bridge shut; the bypass itself "
                   f"meets {t.get('any_route', 0)} (its own finding: R0 bypass, status audit route)")
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
    kw: dict = {"info": info} if takes_info and info is not None else {}
    try:
        if "avoid" in inspect.signature(fn).parameters:
            # BUG-658: no audit wall on a fortcore tile or a finished seal's tile: seal at=audit would leave it out
            from .cmd import audit_avoid
            kw["avoid"] = audit_avoid(save_dir, snap.get("tick"))
    except (TypeError, ValueError):
        pass
    res = fn(snap, manifest, **kw)
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
# BUG-334 (Run 15b Earthboat: 'follow already runs' from pid 22684 on OLD CODE, the player did not know --takeover and
# watched by polling): the lock carries the owner's code stamp (`code`, BUG-042); a follow whose CODE differs from the
# owner's (the lock's code, else the owner's .follow.hb code: followers from before BUG-334) takes over by itself and
# says so; the old one exits at its next beat (refresh_lock). Same code: refused as before (--takeover).
# BUG-385 (Run 16b i2: 'also the 2nd and 3rd start is taken over by a foreign pid 17492': two followers with --takeover on one
# runtime folder, each restarted by its own Monitor after "took over, this one exits", kept taking the lock from each other): a
# takeover is allowed once. The lock names who took it (`took`), when (`took_at`) and which start it displaced (`took_sid`); a
# --takeover (or an old-code takeover) of a lock that itself took over less than FOLLOW_TAKEOVER_COOL_S ago is refused, naming the
# owner's pid.
# BUG-385 review fix (merge20): the cool-down alone only slowed the loop to a 120 s period (each refused start's Monitor restarts it
# and the next try lands after the cool-down). A takeover is now refused REGARDLESS of time when the owner took over from the
# requesting start itself (owner `took` == my pid, or `took_sid` == my start id: DFLLM_FOLLOW_SID, else the parent pid, which a
# Monitor's restarts keep). The refused and the displaced start exit FOLLOW_OWNED_EXIT (4) with 'another follow owns this instance
# (pid N); do not restart', which a Monitor can key on; only stopping the owner frees the instance.
FOLLOW_LOCK = ".follow.lock"
FOLLOW_LOCK_STALE_S = 3 * FOLLOW_HB_EVERY_S
FOLLOW_TAKEOVER_COOL_S = 120
FOLLOW_OWNED_EXIT = 4        # BUG-385: 'another follow owns this instance; do not restart'


def start_id() -> str:
    """BUG-385: who started this follow: DFLLM_FOLLOW_SID, else the parent pid (a Monitor's restarts keep it, the pid changes)."""
    return os.environ.get("DFLLM_FOLLOW_SID") or str(os.getppid())


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


def owner_code(save_dir: Path, owner: dict | None, now: float) -> str | None:
    """BUG-334: the code stamp the lock's owner runs: the lock's `code`, else (a follower from before BUG-334) the code
    of a fresh <save>/.follow.hb, which only the lock's owner writes (BUG-238); None when neither says."""
    if not isinstance(owner, dict):
        return None
    c = owner.get("code")
    if isinstance(c, str) and c:
        return c
    doc, age = files.read_follow_hb(save_dir, now)
    c = (doc or {}).get("code")
    return c if isinstance(c, str) and c and age is not None and age <= files.FOLLOW_STALE_S else None


def old_code_owner(save_dir: Path, now: float, alive: Callable[[int], bool] | None = None) -> tuple[dict, str] | None:
    """BUG-334: (owner, its code) when another follow holds the lock with other dfpilot code than this process
    imported (CODE), else None."""
    owner = lock_owner(save_dir, now, alive)
    code = owner_code(save_dir, owner, now)
    return (owner, code) if owner is not None and code is not None and code != CODE else None


def other_code(save_dir: Path, owner: dict | None, now: float) -> bool:
    """BUG-474: the lock's owner runs other dfpilot code than this process (its lock `code`, else its .follow.hb code), or
    says nothing about its code at all (a follower from before BUG-334: older than any code of ours)."""
    c = owner_code(save_dir, owner, now)
    return c is None or c != CODE


def recent_takeover(owner: dict | None, now: float) -> bool:
    """BUG-385: the lock's owner took the save over itself less than FOLLOW_TAKEOVER_COOL_S ago."""
    t = (owner or {}).get("took_at")
    return isinstance(t, (int, float)) and not isinstance(t, bool) and 0 <= now - t < FOLLOW_TAKEOVER_COOL_S


def took_from_me(owner: dict | None) -> bool:
    """BUG-385 review fix: the lock's owner took the save over from this very start (same pid or same start id)."""
    o = owner or {}
    return o.get("took") == os.getpid() or (isinstance(o.get("took_sid"), str) and o["took_sid"] == start_id())


def acquire_lock(save_dir: Path, now: float, takeover: bool = False,
                 alive: Callable[[int], bool] | None = None) -> tuple[bool, dict | None]:
    """(True, None) when this process now holds <save>/.follow.lock; (False, owner) when another follow runs. BUG-385: a
    takeover of an owner that took over less than FOLLOW_TAKEOVER_COOL_S ago is refused (owner['cooldown'] = seconds left),
    and the lock is read back after the write: of two starts at the same moment the one the file names keeps it."""
    owner = lock_owner(save_dir, now, alive)
    if owner is not None and not takeover:
        return False, owner
    # BUG-474 (Run 16 i1/i3/i4: after a deploy `follow --takeover` was refused 'another follow owns this instance (pid N)' and the
    # fort kept running OLD CODE for hours): the BUG-385 ping-pong guards (cool-down, 'took from my start id') apply to two starts
    # of the SAME code. The start id is the parent pid, and every follow an agent starts from one shell shares it, so the
    # deploy's new follow looked like the displaced start for ever. An owner on other code is displaced by a takeover, unless it
    # took the save over from a follower of MY code (took_code == CODE: the old code coming back, the real ping-pong).
    deploy = owner is not None and other_code(save_dir, owner, now) and owner.get("took_code") != CODE
    if owner is not None and not deploy and took_from_me(owner):    # BUG-385: the displaced start restarts: never, whatever the time
        return False, {**owner, "cooldown": 0, "mine": True}
    if owner is not None and not deploy and recent_takeover(owner, now):
        return False, {**owner, "cooldown": int(FOLLOW_TAKEOVER_COOL_S - (now - owner["took_at"]))}
    path = Path(save_dir) / FOLLOW_LOCK
    files.write_json_atomic(path, {"v": 1, "pid": os.getpid(), "start": int(now), "hb": int(now),
                                   "code": CODE,          # BUG-334
                                   "sid": start_id(),
                                   **({"took": owner.get("pid"), "took_at": int(now),
                                       **({"took_sid": owner["sid"]} if isinstance(owner.get("sid"), str) else {}),
                                       **({"took_code": owner_code(save_dir, owner, now)}
                                          if owner_code(save_dir, owner, now) else {})}         # BUG-474
                                      if owner else {})})
    back = files.read_json(path, retry=False)
    if isinstance(back, dict) and back.get("pid") not in (None, os.getpid()):
        return False, back                                 # BUG-385: the other start wrote after us
    return True, None


def refresh_lock(save_dir: Path, now: float, alive: Callable[[int], bool] | None = None) -> dict | None:
    """Beat the lock; the lock of a follow that took over (another live pid with a fresh hb) is returned untouched."""
    owner = lock_owner(save_dir, now, alive)
    if owner is not None:
        return owner
    doc = files.read_json(Path(save_dir) / FOLLOW_LOCK, retry=False)
    mine = isinstance(doc, dict) and doc.get("pid") == os.getpid()
    start = doc.get("start") if mine else None
    kept = {k: doc[k] for k in ("took", "took_at", "took_sid", "took_code") if k in doc} if mine else {}      # BUG-385: the cool-down outlives the beats
    files.write_json_atomic(Path(save_dir) / FOLLOW_LOCK, {"v": 1, "pid": os.getpid(),
                                                           "start": start if isinstance(start, int) else int(now),
                                                           "hb": int(now), "code": CODE, "sid": start_id(), **kept})       # BUG-334
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

    def __init__(self, takeover: bool, auto: bool = True):
        # BUG-334 review fix: auto=False (follow --once / --max-s, a one-shot) never takes over an owner on old code by
        # itself: it would poll beside the long-running follow, end it at its beat, then release the lock and exit too.
        self.takeover, self.auto, self.dir, self.beat = takeover, auto, None, -1e18
        self.dup_seen: dict[int, float] = {}    # BUG-474: foreign pid beating .follow.hb -> wall it was first seen
        self.dup_said: set[int] = set()

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
            old = None if self.takeover or not self.auto else old_code_owner(d, now)   # BUG-334: old code is taken over
            prev = lock_owner(d, now)               # BUG-613: who holds the save right now (named when this start takes it over)
            ok, owner = acquire_lock(d, now, self.takeover or old is not None)
            self.dup_seen, self.dup_said = {}, set()
            if not ok and owner.get("cooldown") is not None:      # BUG-385: no ping-pong
                # BUG-613: says which one stays: THIS (new) start exits, the owner keeps following (the line used to read like the
                # new start had been displaced, and the player believed his --takeover did not take)
                return (f"follow: another follow owns this instance (pid {owner.get('pid')}); do not restart. NOT STARTED: the "
                        f"owner keeps following, this new start (pid {os.getpid()}) exits. It took {d.name} "
                        f"over from pid {owner.get('took')} and this one does not take it back; two starts with "
                        f"--takeover fight over one instance: stop the other start (a Monitor that restarts follow) or stop "
                        f"pid {owner.get('pid')} (PowerShell: Stop-Process -Id {owner.get('pid')}), then start this one")
            if not ok:
                age = int(now - owner["hb"]) if isinstance(owner.get("hb"), (int, float)) else "?"
                return (f"follow already runs (pid {owner.get('pid')}, beat {age}s ago) for {d.name}: this one exits; "
                        f"stop that one, or start this one with --takeover (dfllm follow --takeover)")
            self.dir, self.beat = d, now
            if old is not None:
                msg = (f"follow: pid {old[0].get('pid')} ran OLD CODE ({old[1]}, this one {CODE}): taken over, it exits "
                       f"at its next beat")
                print(msg, flush=True)
                files.log_cli(d, "follow", "lock", {"takeover": "old_code"}, msg)
                return None
            files.log_cli(d, "follow", "lock", {"takeover": self.takeover}, "holds .follow.lock")
            if prev is not None:
                # BUG-613 (Run 16b i2 y412 / y413: a successful `follow --takeover` printed nothing, the old follow's exit line
                # ('another follow owns this instance ... this one exits') was the only text and read as a refusal): say it
                msg = (f"follow: TOOK OVER {d.name} from pid {prev.get('pid')} (code {owner_code(d, prev, now) or '?'}, this one "
                       f"{CODE}): that follow sees the new lock at its next poll and exits ('DISPLACED' in its own line); this "
                       f"one (pid {os.getpid()}) follows now")
                print(msg, flush=True)
                files.log_cli(d, "follow", "lock", {"took": prev.get("pid")}, msg)
            return None
        # BUG-613: the lock is read at every poll, not only at the beat (FOLLOW_HB_EVERY_S = 10 s): a displaced follow went on
        # answering events beside the new owner for up to 10 s, every event twice
        owner = lock_owner(d, now)
        if owner is None and now - self.beat >= FOLLOW_HB_EVERY_S:
            self.beat = now
            owner = refresh_lock(d, now)
            if owner is None:
                self._dup_check(d, now)
        if owner is not None:
            self.dir = None                         # not ours any more: never delete it
            return (f"follow: another follow owns this instance (pid {owner.get('pid')}); do not restart. DISPLACED, not a failed "
                    f"takeover: pid {owner.get('pid')} took over {d.name} (--takeover) and keeps following; this OLD follow "
                    f"(pid {os.getpid()}) exits and does not take it back")
        return None

    def _dup_check(self, d: Path, now: float) -> None:
        """BUG-474 (Run 16b i2: 'zwei follow parallel (pid 25008 + neuer)', every event answered twice): the lock only holds back a
        follow that reads it. A foreign pid that keeps beating <save>/.follow.hb beside this owner for FOLLOW_LOCK_STALE_S is a
        follow that ignores the lock (code from before BUG-238) or a second copy: said once per pid, with the command that ends it
        (no kill from here: the owner of that process decides)."""
        try:
            doc, age = files.read_follow_hb(d, now)
            pid = (doc or {}).get("pid")
            if (age is None or age > files.FOLLOW_STALE_S or not isinstance(pid, int) or isinstance(pid, bool)
                    or pid == os.getpid() or not pid_alive(pid)):
                self.dup_seen.clear()
                return
            first = self.dup_seen.setdefault(pid, now)
            if now - first < FOLLOW_LOCK_STALE_S or pid in self.dup_said:
                return
            self.dup_said.add(pid)
            msg = (f"follow: BUG-474 a second follow (pid {pid}, code {(doc or {}).get('code') or '?'}) keeps beating {files.FOLLOW_HB} "
                   f"beside this owner (pid {os.getpid()}) for {int(now - first)} s although the lock names this one: it ignores "
                   f".follow.lock (code from before BUG-238) or is a second copy, and every event is answered twice; stop it "
                   f"(PowerShell: Stop-Process -Id {pid})")
            print(msg, flush=True)
            files.log_cli(d, "follow", "dup", {"pid": pid}, msg)
        except Exception as e:             # noqa: BLE001 - a check must never stop the follower
            sys.stderr.write(f"follow: dup check: {type(e).__name__}: {e}\n")


def run(args) -> int:
    f = Follower(save=args.save_pin, since=args.since, auto=not args.no_auto,
                 audit=not getattr(args, "no_audit", False))
    t0, errors, last_err = time.monotonic(), 0, -1e18
    lock = _Lock(bool(getattr(args, "takeover", False)),          # BUG-238
                 auto=not (getattr(args, "once", False) or getattr(args, "max_s", None)))   # BUG-334 review fix
    try:
        while True:
            try:
                why = lock.step(f._resolve())
                if why:
                    print(why, flush=True)
                    f.dir = None                    # leave the other follow's .follow.json alone
                    return FOLLOW_OWNED_EXIT if "do not restart" in why else 3 if "already runs" in why else 0
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
