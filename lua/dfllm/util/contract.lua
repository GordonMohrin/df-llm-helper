-- Frozen v2 contract data (WP0). docs/v2/CONTRACTS.md is normative; dfpilot/schema.py
-- mirrors these tables and tests/test_schema.py checks that both agree. Pure Lua, no DFHack.
local json = require('dfllm.util.json')
local C = {}

C.V = 2
C.TICKS = {DAY = 1200, MONTH = 33600, SEASON = 100800, YEAR = 403200}

-- absolute game tick: monotonic across years and timestream skips (CONTRACTS §1.2)
function C.abs_tick(year, ytick) return year * 403200 + ytick end

C.MODES = {'PEACE', 'ALERT', 'SIEGE', 'BREACH', 'RECOVERY', 'DRILL'}
C.TRANSITIONS = {
  PEACE    = {ALERT = true, SIEGE = true, DRILL = true},
  ALERT    = {PEACE = true, SIEGE = true, BREACH = true},
  SIEGE    = {BREACH = true, RECOVERY = true},
  BREACH   = {RECOVERY = true, SIEGE = true},       -- BUG-028: SIEGE once the fort is sealed again
  RECOVERY = {PEACE = true, ALERT = true, SIEGE = true, BREACH = true},
  DRILL    = {PEACE = true, ALERT = true, SIEGE = true},
}
-- who may call K.set_mode: siege any allowed transition; drill only these two
C.MODE_SETTERS = {siege = '*', drill = {['PEACE>DRILL'] = true, ['DRILL>PEACE'] = true}}

-- READY_IN (BUG-029): Ready, every squad at the inner station (stations.melee, stations.b2 while the core seal is
-- up); INTAKE (Gordon 2026-10-16): Ready, melee in the killing field, crossbows in the gallery, only during a wave;
-- CORE (BUG-030): Ready, every squad at the core station (stations.core, else b2, else melee) in the deep defense
C.POSTURES = {'TRAIN', 'STATION_B1', 'READY_STATION', 'B2_HOLD', 'READY_IN', 'INTAKE', 'CORE'}

-- Gameplay modules in dispatch order (§3.4). every = default cadence; critical = never demoted.
C.MODULES = {
  {name = 'sense',     wp = 'WP5', critical = true, every = {ticks = 10}},
  {name = 'threat',    wp = 'WP5', critical = true, every = {ticks = 25}},
  {name = 'siege',     wp = 'WP5', critical = true, every = {ticks = 25}},
  {name = 'gate',      wp = 'WP5', critical = true, every = {ticks = 25}},
  {name = 'reflex',    wp = 'WP5', critical = true, every = {ticks = 10}},
  {name = 'military',  wp = 'WP6', every = {ticks = 3600}},
  {name = 'drill',     wp = 'WP6', every = {ticks = 600}},
  {name = 'readiness', wp = 'WP6', every = {ticks = 33600}},
  {name = 'arbiter',   wp = 'WP1', critical = true, every = {ms = 500}},
  {name = 'runner',    wp = 'WP7', every = {ticks = 600}},
  {name = 'snapshot',  wp = 'WP7', every = {ticks = 100}},
  {name = 'seal',      wp = 'WP7', every = {ticks = 50}},
  {name = 'economy',   wp = 'WP8', every = {ticks = 1200}},
  {name = 'care',      wp = 'WP8', every = {ticks = 1200}},
  {name = 'water',     wp = 'WP8', every = {ticks = 1200}},
  {name = 'traps',     wp = 'WP8', every = {ticks = 1200}},   -- FR-96/97: trap upkeep (counts, cages)
  {name = 'trade',     wp = 'WP9', every = {ticks = 100}},
  {name = 'baseline',  wp = 'WP8', every = {ticks = 33600}},
  {name = 'perf',      wp = 'WP1', every = {ms = 1000}},
  {name = 'selftest',  wp = 'WP1', every = {ms = 60000}},
  {name = 'cavern',    wp = 'WP6', every = {ticks = 100}},     -- FR-98: the military clears the caverns (G16)
}

-- Event registry (§12): class fixed per type; by = emitting module ('any' = every module).
C.EVENTS = {
  -- A: wakes the LLM
  SIEGE_END = {cls = 'A', by = 'siege'}, GATE_FAIL = {cls = 'A', by = 'gate'},
  BREACH = {cls = 'A', by = 'siege'}, DEATHS_3PLUS = {cls = 'A', by = 'care'},
  -- BUG-115 (Run 14 y707: a curse, then 23 werecavies): a citizen cursed by a god, a citizen changing form, the full moon near
  CURSED = {cls = 'A', by = 'care'}, TRANSFORM = {cls = 'A', by = 'care'}, CURSE_MOON = {cls = 'A', by = 'care'},
  DRILL_FAIL = {cls = 'A', by = 'drill'}, KERN_FAULT = {cls = 'A', by = 'any'},   -- BUG-075: kern (back-off), runner (caught fault)
  -- DECISION_NEEDED food_low/famine (economy): food, block, opts and, BUG-038, auto (fishery: its request is out or
  -- queued; gather: plant gatherers added): what the kernel does itself, never an option for the player; BUG-042:
  -- drink_low (drink = days; block: still, brew, unvalidated, plants, barrels, brewer; auto: brew, office, barrels,
  -- gather) and manager_office (unvalidated orders older than orders.unval_days, with the reason)
  PERF_DEGRADED = {cls = 'A', by = 'perf'}, DECISION_NEEDED = {cls = 'A', by = 'any'},
  PAUSED_BY_DF = {cls = 'A', by = 'arbiter'},     -- FR-94: the game stood paused by DF (a load, a popup) for resume.wake_min minutes
  -- PROJECT_BLOCKED (and PROJECT_DONE) d.walled, Run 11: the seal doors quickfort refused, planned as walls ('x,y,z');
  -- BUG-037 d.park: the days a project blocked for good stood before it was parked (msg: its bp.cancel command)
  PLAN_EXHAUSTED = {cls = 'A', by = 'runner'}, PROJECT_BLOCKED = {cls = 'A', by = 'runner'},
  YEAR_REVIEW = {cls = 'A', by = 'kern'},
  -- FR-04/26 ghosts and unburied citizens, FR-34 a hospital without accepted water, FR-44 a strange mood at risk
  GHOSTS = {cls = 'A', by = 'care'}, HOSPITAL_DRY = {cls = 'A', by = 'water'}, MOOD_RISK = {cls = 'A', by = 'care'},
  -- BUG-063: a strange-mood dwarf's thirst (hunger) passed mood_crit (mood_crit_hunger): the dwarf, his workshop, the nook
  -- (BUG-102: d.nook says 'no nook within N: <counts>' when none; FR-82: past that bar the search widens 3 -> 6 -> 9)
  -- BUG-282: also (whatever the thirst) a mood without a workshop, with a material none in the fort, still waiting, or near
  -- DF's insanity line (d.why workshop | material | waiting | timer, d.left days, d.ask the shops the kernel requested, d.webs)
  MOOD_CRITICAL = {cls = 'A', by = 'care'},
  -- BUG-034: the zones of a hospital without accepted water were removed while a patient was over water.patient_thirst
  HOSPITAL_REMOVED = {cls = 'A', by = 'water'},
  -- BUG-054 (Run 11 y497: 5 patients dead of thirst at once): a patient at water.dying_thirst (60,000), with the
  -- caregivers' state (the Orderlies work detail is scaled by water: act.work_detail)
  PATIENT_DYING = {cls = 'A', by = 'water'},
  -- BUG-036: in a fight, patients lie outside the burrow the civ alert confines to (once per fight; they cannot walk)
  PATIENTS_OUT = {cls = 'A', by = 'water'},        -- M3 (note 94 c): a class-A wake with a recipe (once per fight)
  -- BUG-040: a done cistern whose well stood dry for water.cistern_dry_days (once per dry spell, with what fills it)
  CISTERN_DRY = {cls = 'B', by = 'water'},
  -- A since Run 9 (an army walked in while these were digest-only): wake at once
  SIEGE_START = {cls = 'A', by = 'siege'}, INVASION = {cls = 'A', by = 'threat'},
  -- A, reflex (FR-36/49/51-53): arrival announcements and the interrupt channel (C.INTERRUPTS)
  ARRIVAL = {cls = 'A', by = 'any'}, INTRUDER = {cls = 'A', by = 'reflex'},
  PREDATOR = {cls = 'A', by = 'reflex'}, NO_DEPOT = {cls = 'A', by = 'reflex'},
  LOCKDOWN = {cls = 'A', by = 'reflex'},
  ORDER_BAD = {cls = 'A', by = 'economy'}, DEPOT_MISSING = {cls = 'A', by = 'trade'},
  CUTOFF = {cls = 'A', by = 'seal'}, PERIMETER_BROKEN = {cls = 'A', by = 'seal'},
  SEAL_LEAK = {cls = 'A', by = 'seal'}, REFUGE_FAIL = {cls = 'A', by = 'seal'},
  REFUGE_STOCK = {cls = 'A', by = 'seal'},        -- BUG-107: a potential refuge under its food/drink floor
  -- BUG-010: autolabor found enabled in legacy mode (the Run 9 crash engine); baseline set it to monitor
  AUTOLABOR_LEGACY = {cls = 'A', by = 'baseline'},
  -- FR-64: >= 2 citizens died of dehydration or starvation within a month (the A twin of DEATH_CLUSTER)
  DEATHS_PREVENTABLE = {cls = 'A', by = 'care'},
  -- FR-65: readiness R0 in PEACE (blockers, ways in without door or bridge, traps); monthly while it fails
  SIEGE_UNREADY = {cls = 'A', by = 'readiness'},
  -- BUG-015: an entrance door the lockdown forbade lost its forbidden flag before the next pass (refused)
  LOCKDOWN_PARTIAL = {cls = 'A', by = 'reflex'},
  -- BUG-023 / Run 10: members of a tool detail hold no pick or axe for days while its jobs wait and free tools exist;
  -- Run 11: forbidden ones count too (forb), d.blk/bk/picks/units/civ/ww = economy's diagnosis of what DF lacks
  TOOL_BLOCKED = {cls = 'A', by = 'economy'},
  -- BUG-027: a SIEGE/BREACH raise went ahead onto units on or next to the footprint (a hostile at the gate)
  GATE_FORCED = {cls = 'A', by = 'gate'},
  -- BUG-027: a unit died on or next to a bridge just pulled or moving (gate's move records)
  BRIDGE_CRUSH = {cls = 'A', by = 'gate'},
  -- BUG-028: citizens cut off from drink/food by our raised gates (a raise held or forced, a rescue and its end);
  -- BUG-031: relax, the civ alert's burrow kept them from it
  STRANDED = {cls = 'A', by = 'siege'},
  -- BUG-028: the main part of the drink or food stock lies outside the lockable core (Kern+ and the refuge)
  SUPPLY_OUTSIDE = {cls = 'A', by = 'seal'},
  -- BUG-096/FR-80 (Run 14 note 70): Kern+ or the refuge lost more than burrow.guard.shrink_pct % of its tiles, or is gone
  -- (d.burrow, was, now, cause load | runtime, nbw/nb blocks, id/rid, gone, pct, crit = well | refuge | hospital, fix)
  BURROW_SHRUNK = {cls = 'A', by = 'seal'},
  -- Gordon 2026-10-16: an intake wave or a sortie through O1 went wrong (losses, a hostile past B1, the field not
  -- clear, soldiers left outside)
  WAVE_FAIL = {cls = 'A', by = 'siege'},
  -- BUG-030: a manifest bridge gate saw complete is gone from its footprint (destroyed; d.n/bd/destroyers/races: its
  -- loss history, gate.losses); the siege's deep defense (building destroyers in sight, an army over
  -- stations.core_ratio x the soldiers, weak squads): refuge and core. PERIMETER_BROKEN d.wait/replaced (BUG-048: a lost
  -- bridge the keeper replaces by a wall and a door; DECISION_NEEDED id bridge_rebuild is not asked any more): the rebuild policy
  BRIDGE_DESTROYED = {cls = 'A', by = 'gate'}, SIEGE_DEEP = {cls = 'A', by = 'siege'},
  -- Run 11: a dig broke into a cavern (lake): the explore shaft's plug (queued, done, failed) or none (by hand); the
  -- daily shaft check (any explore state, field state) queues it too
  CAVERN_PLUG = {cls = 'A', by = 'runner'},
  -- FR-95: a heavy aquifer (water >= 4/7 or a rising flow in our own dug tiles): the dig stopped for good
  -- (breach:heavy_aquifer), a shaft plugged (CAVERN_PLUG); d.proj, z, flow, why flow | rising, pos, plug
  AQ_HEAVY = {cls = 'A', by = 'runner'},
  -- Run 11 siege 8: an open seal or plug built nothing for runner seal_first.stuck_days; the others run again (d.proj,
  -- tpl, stage, days, n, pieces 'door x,y,z', mat, blocked; BUG-041 wait: the job and its labor, a piece no citizen
  -- reaches)
  SEAL_STUCK = {cls = 'A', by = 'runner'},
  -- B: digest
  ALERT_START = {cls = 'B', by = 'siege'}, ALERT_END = {cls = 'B', by = 'siege'},
  -- Run 11: d.cause far (it ended with hostiles in sight beyond reflex.lockdown_near; d.far names them, d.nfar) | quiet
  LOCKDOWN_END = {cls = 'B', by = 'reflex'},
  PREDATOR_FAR = {cls = 'B', by = 'reflex'},
  -- Run 11 (siege 8): the lockdown's recall of the citizens outside Kern+ (d.why done | late | end; n, left, ticks,
  -- units still out, called, burrow, eta; BUG-035: why stuck, reasons, stuck, pull, nnew, newu); a switch of the civ
  -- alert's burrow during a fight (d.from, to, why, mode)
  RECALL = {cls = 'B', by = 'reflex'}, REFUGE_SWITCH = {cls = 'B', by = 'seal'},
  -- FR-80: tiles of Kern+ or the refuge painted again from the last good reading (d.burrow, n, was, now, left, done, day)
  BURROW_REPAIRED = {cls = 'B', by = 'seal'},
  MOOD_START = {cls = 'B', by = 'care'}, MOOD_NEED = {cls = 'B', by = 'care'},
  TOMBS_LOCKED = {cls = 'B', by = 'care'},      -- BUG-062: tomb zones closed to citizens (counts, who closed them again)
  BUILDING_TOPPLED = {cls = 'B', by = 'care'},  -- BUG-064: a building fell to a stressed citizen or a ghost (culprit, stress)
  STRESS_HIGH = {cls = 'B', by = 'care'},       -- FR-74: stress at stress_high for stress_days; the sources named
  MOOD_END = {cls = 'B', by = 'care'}, CARAVAN = {cls = 'B', by = 'trade'},
  MIGRANTS = {cls = 'B', by = 'economy'}, PETITION = {cls = 'B', by = 'care'},
  STOCK_LOW = {cls = 'B', by = 'economy'}, CANCEL_LOOP = {cls = 'B', by = 'economy'},
  LABOR_STARVED = {cls = 'B', by = 'economy'}, WORK_DETAIL = {cls = 'B', by = 'economy'},
  CAPTURE = {cls = 'B', by = 'care'}, BREACH_STOP = {cls = 'B', by = 'runner'},
  -- FR-95: the aquifer pass: observe mode began (a damp report, no park), a shaft level sealed, seepage seen, a shaft passed
  AQ_OBSERVE = {cls = 'B', by = 'runner'}, AQ_LEVEL_SEALED = {cls = 'B', by = 'runner'},
  AQ_SEEP = {cls = 'B', by = 'runner'}, AQ_PASS_DONE = {cls = 'B', by = 'runner'},
  KERNEL_SLOW = {cls = 'B', by = 'kern'}, WEALTH = {cls = 'B', by = 'siege'},
  DRILL_RESULT = {cls = 'B', by = 'drill'}, READY_CHANGE = {cls = 'B', by = 'readiness'},
  POPCAP = {cls = 'B', by = 'readiness'}, AUDIT = {cls = 'B', by = 'readiness'},
  PROJECT_DONE = {cls = 'B', by = 'runner'}, PROJECT_REQUEST = {cls = 'B', by = 'any'},
  PHASE = {cls = 'B', by = 'runner'}, PAUSE = {cls = 'B', by = 'arbiter'},
  DEATH = {cls = 'B', by = 'care'}, ACT_FAIL = {cls = 'B', by = 'kern'},
  DEATH_CLUSTER = {cls = 'B', by = 'care'},      -- FR-64: deaths of one cause (or 3 of any) within a month
  ORDER_STUCK = {cls = 'B', by = 'economy'}, JOBS_SUSPENDED = {cls = 'B', by = 'economy'},
  TRADE_LEDGER = {cls = 'B', by = 'trade'},
  SEAL = {cls = 'B', by = 'seal'}, REACH = {cls = 'B', by = 'seal'},
  -- BUG-044: a seal door still not built seal_first.wall_days after SEAL_STUCK, replaced by a constructed wall on its
  -- tile (d.proj, at 'x,y,z', was 'door', days, why = the SEAL_STUCK wait); PROJECT_BLOCKED d.parts (BUG-046): the parts
  -- of a stalled build stage that wait
  SEAL_WALLED = {cls = 'B', by = 'runner'},
  -- Gordon 2026-10-16: intake waves in SIEGE (muster, open, close, clear, back, abort, refused) and the sortie
  -- through O1 (gather, open, out, recall, close, done, abort)
  INTAKE = {cls = 'B', by = 'siege'}, SORTIE = {cls = 'B', by = 'any'},       -- M3: military reports the position sorties too
  -- Run 11: economy's glass chain for strange moods is blocked (no sand revealed, no bags, no fuel; once per set)
  GLASS_BLOCKED = {cls = 'B', by = 'economy'},
  -- Run 11: pieces planned buildings wait for that nothing in the fort can make (no rock, no logs; once per set)
  MATERIAL_SHORT = {cls = 'B', by = 'economy'},
  -- BUG-042: the manager's office lacked its chair/table (he validates nothing without them); what economy placed
  MANAGER_OFFICE = {cls = 'B', by = 'economy'},
  -- BUG-231: manager orders held past orders.bypass_days: the items added as workshop tasks (act.ws_task)
  MANAGER_BYPASS = {cls = 'B', by = 'economy'},
  -- BUG-032: military moved a squad station off a bridge footprint and its ring (bridge, chain, none, hold)
  STATION_MOVED = {cls = 'B', by = 'military'},
  -- FR-79: the members of a militia squad were swapped for the next cohort at the close of its window (counts only)
  MILITIA_ROTATED = {cls = 'B', by = 'military'},
  -- BUG-068: a lever pulled gate.noeffect_max times in a row without the bridge moving is parked (once per lever)
  LEVER_NOEFFECT = {cls = 'B', by = 'gate'},
  -- BUG-253: a unit on the footprint of a bridge while it moved (once per move; the death is BRIDGE_CRUSH)
  GATE_CRUSH_RISK = {cls = 'B', by = 'gate'},
  -- BUG-121 (Run 14 note 101): boot found the game clock before the last tick the runtime folder saw (an older save was
  -- loaded): events before this marker with a later tick belong to the discarded timeline
  TIMELINE_RESET = {cls = 'B', by = 'kern'},
  -- FR-98: the cavern sweep (squad A through a plugged shaft under a hatch): START (B), a step (C), the END (A: why, kills, losses, sealed)
  CAVERN_SWEEP_START = {cls = 'B', by = 'cavern'}, CAVERN_SWEEP_END = {cls = 'A', by = 'cavern'},
  -- C: log only
  SIEGE_STATUS = {cls = 'C', by = 'siege'}, SEASON = {cls = 'C', by = 'kern'},
  PROJECT_STAGE = {cls = 'C', by = 'runner'}, MODE = {cls = 'C', by = 'kern'},
  POPUP_GONE = {cls = 'C', by = 'arbiter'}, CAVERN_SWEEP_STEP = {cls = 'C', by = 'cavern'},       -- FR-87: a popup vanished without the kernel's dismiss (text, kind)
  GATE = {cls = 'C', by = 'gate'}, LEVER = {cls = 'C', by = 'gate'},
  SNAPSHOT_READY = {cls = 'C', by = 'snapshot'}, CMD = {cls = 'C', by = 'kern'},
  BOOT = {cls = 'C', by = 'kern'}, UNLOAD = {cls = 'C', by = 'kern'},
}

-- Interrupt types (FR-53): a class-A subset that goes to <save>/alarm.txt at once and waits for the
-- operator's `ack`; unacked for reflex ack_timeout_s, the kernel applies the type's lockdown default itself.
C.INTERRUPTS = {ARRIVAL = true, INTRUDER = true, PREDATOR = true, DEATHS_3PLUS = true, NO_DEPOT = true,
                CURSED = true, TRANSFORM = true}   -- BUG-115

-- Inbox verbs (§13). mod = handler ('kern' = kernel itself); modes = allowed modes (nil = any);
-- approve = args.approve must be true.
C.VERBS = {
  ['plan.reload']  = {mod = 'kern'},
  ['bp.place']     = {mod = 'runner'},
  ['bp.cancel']    = {mod = 'runner'},
  ['drill']        = {mod = 'drill', modes = {PEACE = true}},
  ['snapshot']     = {mod = 'snapshot'},
  ['audit']        = {mod = 'readiness'},
  ['popcap.lower'] = {mod = 'readiness'},
  ['tempo.lower']  = {mod = 'arbiter'},
  ['pause']        = {mod = 'arbiter'},
  ['unpause']      = {mod = 'arbiter'},
  ['resume']       = {mod = 'arbiter'},       -- FR-94: releases a pause DF set (pause:df, pause:popup) with the pause key
  ['trade.want']   = {mod = 'trade'},
  ['trade.retry']  = {mod = 'trade', modes = {PEACE = true}},   -- a second trade in the same visit (Run 10 y418)
  ['squad.sortie'] = {mod = 'military', approve = true,
                      modes = {ALERT = true, SIEGE = true, BREACH = true, RECOVERY = true}},
  ['lever']        = {mod = 'gate', modes = {PEACE = true}},
  ['inspect']      = {mod = 'kern'},
  ['selftest']     = {mod = 'selftest'},
  ['module.enable'] = {mod = 'kern'},
  ['tombs.repair'] = {mod = 'care'},
  ['ack']          = {mod = 'reflex'},
  ['order.add']    = {mod = 'economy'},
  ['jobs.release'] = {mod = 'economy'},
  ['butcher.mark'] = {mod = 'economy'},     -- BUG-260: the animal sheet's slaughter toggle for n tame animals
  ['perimeter.record'] = {mod = 'seal'},
  -- BUG-030 rebuild policy: the player's answer to DECISION_NEEDED bridge_rebuild (rebuild that bridge anyway)
  ['bridge.rebuild'] = {mod = 'seal'},
  -- BUG-055: the nobles screen and the squads screen (outside a fight) as verbs
  ['appoint'] = {mod = 'economy'},
  ['squad.create'] = {mod = 'military', modes = {PEACE = true, ALERT = true, RECOVERY = true}},
  ['squad.leader'] = {mod = 'military', modes = {PEACE = true, ALERT = true, RECOVERY = true}},
  ['squad.add'] = {mod = 'military', modes = {PEACE = true, ALERT = true, RECOVERY = true}},
  ['squad.uniform'] = {mod = 'military', modes = {PEACE = true, ALERT = true, RECOVERY = true}},
  -- FR-78 (Run 14 note 65): a civzone (pen, pit, pond, sand, clay, fishing, meeting, dump) in a box, quickfort zone mode
  ['zone.place'] = {mod = 'runner', modes = {PEACE = true, ALERT = true, RECOVERY = true}},
  -- FR-88 (Run 14 note 95): the camera; no mode list (a fight needs by=gordon, viewlib refuses it)
  ['view'] = {mod = 'arbiter'},
  -- BUG-131 (Run 14): the zones screen's remove for one hospital zone outside Kern+/Tiefe+ (no patient in it; a finished
  -- hospital inside or approve:true from the player)
  ['hospital.retire'] = {mod = 'water', modes = {PEACE = true}},
}
-- Verbs accepted only from these `by` origins (§9.5). `by` is a label, not authentication: the
-- hook (WP4) keeps the LLM from writing these origins; this check is the second line.
C.VERB_BY = {audit = {follow = true, test = true}}

-- act.lua functions (§5) and the modules allowed to call them ('*' = any module).
C.ACT = {
  set_paused = {'arbiter'}, timestream = {'arbiter'}, setting = {'arbiter'},
  press_pause = {'arbiter'},                          -- FR-94: the pause key to the main DF viewscreen (verb `resume`)
  overlay = {'arbiter'}, dismiss_popup = {'arbiter'},
  view_to = {'arbiter'}, view_window = {'arbiter'},   -- FR-88: the camera (viewport) like a click on a report
  civ_alert = {'siege'}, alert_burrows = {'siege'},
  squad_create = {'military'}, squad_leader = {'military'}, squad_add = {'military'}, squad_remove = {'military'},
  squad_routine = {'military'}, squad_order = {'military'}, squad_uniform = {'military'},
  squad_unequip = {'military'}, squad_release = {'military'}, animal_slaughter = {'economy'}, zone_remove = {'runner'}, manager_office = {'economy'}, pond_remove = {'water'},
  hospital_remove = {'water'},                     -- BUG-034: a dry hospital's zones; BUG-131: hospital.retire
  sand_zone = {'economy'}, fish_zone = {'economy'},
  tool_pile = {'economy'},                         -- BUG-053: a weapons stockpile for the miners' picks near the mines
  zone_place = {'runner', 'economy'},              -- FR-78: the verb zone.place (zonelib); BUG-232: the manager's office zone
  ws_task = {'economy'},                           -- BUG-231: workshop sheet > add task (chair, table, door, bed, blocks)
  mood_task = {'care'},                            -- BUG-284: the Loom sheet > add task > collect webs (a mood needs silk)
  pull = {'gate'}, cancel_own_lever_job = {'gate'}, link_lever = {'gate'}, burrow_units = {'gate'},
  door_forbid = {'reflex', 'cavern'},              -- FR-98: the sweep's hatch over the cavern shaft
  burrow_tiles = {'seal'},
  popcap = {'readiness'},
  quickfort = {'runner'}, order_top = {'runner'},  -- Run 11 siege 8: a seal's manager orders to the top (seal first)
  orders_import = {'economy'}, orders = {'economy'}, workorder = {'economy', 'water', 'care', 'traps'},
  order_suspend = {'economy'}, engrave_order = {'economy'}, kitchen_exclude = {'economy'}, appoint = {'economy'}, work_detail = {'economy', 'water'},
  order_material = {'economy'}, order_remove = {'economy'}, job_resume = {'economy'}, farm_crop = {'economy'},
  plant_gather = {'economy'}, plant_ungather = {'economy'}, work_detail_prune = {'economy'},
  item_flag = {'care', 'water', 'economy', 'military'}, zone_assign = {'care'},
  tomb_zone = {'care'}, medic = {'care'}, hospital_post = {'care'},
  slab_place = {'care'},                           -- BUG-133: Build > Furniture > Slab with a ghost's engraved slab
  trade = {'trade'},
  run = {'baseline', 'economy', 'care', 'military', 'trade', 'arbiter', 'selftest', 'runner'},
}

-- state.json leaf owners (§9.3); 'k.*' means every key under k.
C.STATE_OWNERS = {
  ['v'] = 'kern', ['seq'] = 'kern', ['ev'] = 'kern', ['t.*'] = 'kern', ['mode'] = 'kern',
  ['save'] = 'kern', ['k.*'] = 'kern',
  ['phase'] = 'runner', ['proj'] = 'runner', ['sched.*'] = 'runner', ['adopt.*'] = 'runner',
  ['pop.cit'] = 'sense', ['pop.adults'] = 'sense', ['pop.soldiers'] = 'sense',
  ['pop.cap'] = 'readiness', ['pop.gate_cap'] = 'readiness', ['ready.*'] = 'readiness',
  ['stock.drink_d'] = 'economy', ['stock.food_d'] = 'economy', ['stock.meals'] = 'economy',
  ['stock.ore'] = 'economy', ['stock.bars'] = 'economy', ['stock.leather'] = 'economy', ['stock.metal'] = 'economy',
  ['stock.mood_miss'] = 'economy', ['stock.rock'] = 'economy', ['stock.rock_need'] = 'economy',
  ['stock.picks'] = 'economy', ['stock.pick_want'] = 'economy', ['stock.mshort'] = 'economy', ['stock.melt'] = 'economy',
  ['stock.dwhy'] = 'economy', ['stock.hungry'] = 'economy', ['stock.dforb'] = 'economy', ['stock.fforb'] = 'economy',
  ['stock.hosp_water'] = 'care', ['care.*'] = 'care', ['curse.*'] = 'care', ['mood'] = 'care', ['labor.*'] = 'economy', ['orders.*'] = 'economy',
  ['threat.*'] = 'threat', ['bridges'] = 'gate', ['owners.*'] = 'arbiter',
  ['mil.*'] = 'military', ['trade.*'] = 'trade',
  ['clock.*'] = 'arbiter', ['alarm.*'] = 'reflex', ['lever.*'] = 'gate',
  ['alert.*'] = 'seal', ['wave.*'] = 'siege', ['snap.*'] = 'snapshot', ['water.*'] = 'water', ['stale.*'] = 'kern',
  ['traps.*'] = 'traps',
  ['cav.*'] = 'cavern',                            -- FR-98
}

-- Persistent site-data keys (§10). Stored as dfhack.persistent site strings encoded with util/json.
-- Dynamic keys: 'bp.<project id>' (runner), 'm.<module>' (that module).
C.PERSIST = {
  marker = {key = 'dfllm', owner = 'kern'},
  -- the fort manifest (shape: schema.MANIFEST); BUG-130: `breaches` = {{pos, why, proj, tpl}} from the runner's m.runner dz
  manifest = {key = 'dfllm.manifest', owner = 'runner'},
  projects = {key = 'dfllm.projects', owner = 'runner'},
  plan = {key = 'dfllm.plan', owner = 'kern'},
  phase = {key = 'dfllm.phase', owner = 'runner'},
  mode = {key = 'dfllm.mode', owner = 'kern'},     -- written by K.set_mode
  drill = {key = 'dfllm.drill', owner = 'drill'},
  restore = {key = 'dfllm.restore', owner = 'arbiter'},
  kern = {key = 'dfllm.kern', owner = 'kern'},
  -- BUG-096/FR-80: seal's burrow guard: per managed burrow the last good reading (tiles, blocks, id, runs) and the open episode
  burrows = {key = 'dfllm.burrows', owner = 'seal'},
}
function C.persist_key(k)
  local e = C.PERSIST[k]
  if e then return e.key end
  if k:match('^bp%.[%w_.%-]+$') or k:match('^m%.[%l_]+$') then return 'dfllm.' .. k end
  return nil
end

C.DECISIONS = {
  ['D-01'] = 'B', ['D-02'] = 'unchanged', ['D-03'] = 'rule', ['D-04'] = 'off', ['D-05'] = 'off',
  ['D-06'] = 'off', ['D-07'] = 'unchanged', ['D-08'] = 'dropped', ['D-09'] = 'no', ['D-10'] = 'off',
  ['D-11'] = 'accepted', ['D-12'] = '15/20', ['D-13'] = 'no', ['D-14'] = 'down',
}

-- decisions.yaml reader (§9.16), the one Lua implementation (kern uses it; schema.parse_decisions is
-- the Python twin): strip a UTF-8 BOM, split on \n, strip spaces/tabs/\r at both ends, then
-- `D-NN [ \t]* : value [# comment]`; empty values are skipped, a later line wins.
function C.parse_decisions(text, into)
  local d = into or {}
  local s = tostring(text or '')
  if s:sub(1, 3) == '\239\187\191' then s = s:sub(4) end
  for line in s:gmatch('[^\n]+') do
    local l = line:match('^[ \t\r]*(.-)[ \t\r]*$')
    local id, rest = l:match('^(D%-[0-9][0-9])[ \t]*:(.*)$')
    if id then
      local hash = rest:find('#', 1, true)
      if hash then rest = rest:sub(1, hash - 1) end
      local val = rest:match('^[ \t]*(.-)[ \t]*$')
      if val ~= '' then d[id] = val end
    end
  end
  return d
end

-- Kernel fault and slowness rules (§3.3.5-3.3.6); k_mock and kern use these numbers.
C.KERN = {
  fault_n = 3, fault_window_ms = 600000,            -- 3 faults within 10 min -> back off
  backoff_ms = {critical = 30000, other = 600000},  -- first backoff; doubles per back-off in one boot
  backoff_max_ms = {critical = 480000, other = 3600000},
  backoff_reset_ms = 3600000,                       -- 1 h without a fault resets the doubling
  slow_ms = 5, slow_n = 3, slow_window_ms = 600000, -- 3 calls > 5 ms (os.clock) within 10 min = slow
  promote_ms = 600000, max_factor = 8,              -- factor halves after 10 min without a slow call
  big_ms = 1000,                                    -- BUG-039: a call this long is named in kern.log (what, act)
}

-- Report routing hints (§4.1, names = df.announcement_type; confirm in spike S7).
C.REPORTS = {
  CARAVAN_ARRIVAL = 'trade', FIRST_CARAVAN_ARRIVAL = 'trade', MERCHANTS_LEAVING_SOON = 'trade',
  MERCHANTS_NEED_DEPOT = 'trade',
  MIGRANT_ARRIVAL = 'economy', MIGRANT_ARRIVAL_NAMED = 'economy', D_MIGRANTS_ARRIVAL = 'economy',
  CANCEL_JOB = 'economy', FOOD_WARNING = 'economy',
  STRANGE_MOOD = 'care', MOOD_BUILDING_CLAIMED = 'care', ARTIFACT_BEGUN = 'care', MADE_ARTIFACT = 'care',
  CITIZEN_DEATH = 'care', ANIMAL_TRAP_CATCH = 'care', STRESSED_CITIZEN = 'care', CITIZEN_TANTRUM = 'care',
  GHOST_ATTACK = 'care',
  -- BUG-064: "X toppled by <dwarf>" (a tantrum, a ghost): care names the culprit and his stress (BUILDING_TOPPLED)
  BUILDING_TOPPLED_BY_GHOST = 'care', BUILDING_DESTROYED_OR_TOPPLED = 'care', POSSESSED_TANTRUM = 'care',
  DIG_CANCEL_DAMP = 'runner', DIG_CANCEL_WARM = 'runner', CAVE_COLLAPSE = 'runner', FEATURE_DISCOVERY = 'runner',
  UNDEAD_ATTACK = 'threat', NIGHT_ATTACK_STARTS = 'threat', MEGABEAST_ARRIVAL = 'threat',
  WEREBEAST_ARRIVAL = 'threat', BEAST_AMBUSH = 'threat', AMBUSH_AMBUSHER = 'threat',
  AMBUSH_THIEF = 'threat', AMBUSH_SNATCHER = 'threat',
}

-- snapshot tile legend (§9.10): one ASCII char per tile; BUG-043: ' ' = not exported (outside every part of a union)
C.SNAP_LEGEND = '?_.#SCF<>Xrv+=H^Bw~%T '

---------------------------------------------------------------- state.json spec (§9.3)
-- Same tree as schema.STATE (tests/test_schema.py compares both and runs shared vectors).
-- Nodes: int{lo,hi} str{max,enum,fmt} bool null const{v} arr{items,lo,hi} tup{items}
--        obj{req,opt,extra,keys} any{of}. fmt/keys name a check in C.FMT.
local function int(lo, hi) return {t = 'int', lo = lo, hi = hi} end
local function str(max, enum, fmt) return {t = 'str', max = max, enum = enum, fmt = fmt} end
local function arr(items, lo, hi) return {t = 'arr', items = items, lo = lo or 0, hi = hi} end
local function obj(req, opt, extra, keys) return {t = 'obj', req = req or {}, opt = opt or {}, extra = extra, keys = keys} end
local NAT, FLAG, PCT, BOOL = int(0), int(0, 1), int(0, 100), {t = 'bool'}
local MODULE = str(nil, nil, 'module')
local ROT_ONE = obj(nil, {w = str(24), on = int(0, 1), n = NAT, z = NAT, e = NAT, lo = NAT, hi = NAT, nx = NAT, rt = NAT,
                         mv = NAT, why = str(60)})

C.STATE_SPEC = obj({
  v = {t = 'const', v = C.V}, seq = NAT,
  t = obj({y = NAT, tick = int(0, 403199), season = int(0, 3), tps = NAT, paused = BOOL},
          {abs = NAT, wall = NAT, frame = NAT}),
  mode = str(nil, C.MODES),
  -- BUG-033: top = the top cost owner of the last minute, 'runner 35 (snapshot 20)'
  k = obj({ms_s = NAT, gap_max_ms = NAT, slow = arr(MODULE), faults = NAT},
          {disabled = arr(MODULE), ms_max = NAT, top = str(40)}),
  ev = NAT,
}, {
  save = str(120), phase = str(nil, nil, 'phase'),
  pop = obj(nil, {cit = NAT, adults = NAT, soldiers = NAT, cap = NAT, gate_cap = NAT}),
  ready = obj({lvl = int(0, 3), worn = PCT, cv = NAT, drill_age = int(-1),
               -- BUG-043: why readiness' last audit request was refused; what the last audit's snapshot covered
               audit = obj({ok = FLAG, age = int(-1), min_traps = NAT}, {why = str(80), cov = str(40)}),
               fail = arr(str(24), 0, 8)},
              {open = int(-1), ents = arr(str(24), 0, 3), dhold = str(24), dref = NAT,     -- FR-65; BUG-110: drills refused for want of O1/B1
               route = str(60),            -- the last audit's first attacker-route finding (bypass, refuge)
               pd = NAT, pw = str(60),     -- FR-70: days the perimeter has been open (PEACE), and what is open
               office = str(200),          -- BUG-055: the vacant office (or squad leader post) R0 `office` names, with the fix
               mws = str(200)}),           -- BUG-117: the moodable workshops R0 `mood_ws` names, with the bp.place command
  -- Run 10: ore/bars/leather stock, the metal route and the classes moods missed (plan propose/check supply goals)
  stock = obj(nil, {drink_d = NAT, food_d = NAT, meals = NAT, hosp_water = FLAG, ore = NAT, bars = NAT, leather = NAT,
                    metal = str(24), mood_miss = arr(str(12), 0, 8), rock = NAT, rock_need = NAT, picks = NAT,
                    pick_want = NAT, mshort = FLAG, melt = NAT,     -- Run 11: metal short, items marked for melting
                    dwhy = str(80),                 -- BUG-042: why the stills do not brew below the drink target
                    hungry = NAT,                   -- BUG-059: citizens past DF's "hungry" line (hunger_timer >= starve.hunger)
                    dforb = NAT, fforb = NAT}),     -- FR-76: drink / food units the census counts as forbidden
  care = obj({stressed_pct = PCT, naked = NAT, ghosts = NAT, corpses_old = NAT, tombs_free = NAT, moods = NAT},
             {coffins = obj({want = NAT, short = NAT, stock = NAT, order = NAT, proj = str(40)},
                            {stuck = NAT, stale = NAT}),     -- BUG-126: orders that cannot run; days the project stands still
              died = obj(nil, nil, NAT), tombs_locked = NAT,
              corpses_unreach = NAT,       -- BUG-105: citizen bodies on a tile nobody can path to (apart from corpses_old)
              -- FR-74: stressed citizens by source (ghosts, deaths, beds, drink, food, rooms, toppled), the population
              -- split and record (kids = children and babies, res = residents, peak, deaths and migrant waves in the last
              -- year, days since the last wave or -1) and the deaths of the last year by cause
              src = obj(nil, nil, NAT), died_y = obj(nil, nil, NAT),
              pop = obj({kids = NAT, res = NAT, peak = NAT, dy = NAT, waves = NAT, mig = NAT, lastw = int(-1)}),
              -- FR-83: citizens at stress category 0 (the worst): how many, the first ids and their names
              s0 = obj({n = NAT}, {ids = arr(NAT, 0, 6), nm = arr(str(28), 0, 6)})}),
  -- BUG-115: cursed citizens alive (n), of them in were-form now (tf), the first ids (the transformed first), the next full
  -- moon (mo = day of the year, 1-based; mi = whole days until it) and the cursed who died (dead)
  curse = obj({n = NAT, tf = NAT}, {ids = arr(NAT, 0, 8), mo = int(1, 400), mi = NAT, dead = NAT}),
  -- BUG-285: the open strange moods, fewest days left first: unit, the line 'MOOD <name> <kind> needs <items>: <have/missing>,
  -- <days left>', days left (-1 unknown), the first emergency reason, the trade tokens of the short needs (plan propose)
  mood = arr(obj({u = NAT, t = str(200)}, {left = int(-1), why = str(16), buy = arr(str(24), 0, 6)}), 0, 4),
  -- FR-77: why the adults have no job (rest/hurt/mood/free), adults counted, soldiers, projects the kernel holds back
  labor = obj({starving = NAT, idle = PCT}, {n = NAT, sold = NAT, held = NAT, why = obj(nil, nil, NAT)}),
  -- BUG-071: keys published from the last known values (key -> age in game ticks)
  stale = obj(nil, nil, NAT),
  -- BUG-042: unvalidated live orders, the days the oldest waits, why the manager validates nothing (past unval_days)
  -- BUG-059: of the stuck orders, how many miss a workshop (and which, the most missed first) and how many a worker
  orders = obj({n = NAT, bad = NAT, stuck = NAT}, {unval = NAT, uval_d = NAT, mgr = str(80), stuck_ws = NAT,
                                                   stuck_lab = NAT, ws = str(60), jam = str(80),
                                                   byp = str(80)}),   -- BUG-233: the kernel's workshop tasks (M.mgr_bypass)
  threat = obj({vis = NAT, armed = FLAG}),
  -- BUG-066 / FR-76 (runner): workshops that stand, adopted into the manifest (new) and pruned from it (gone); standing
  -- stockpiles, wells, beds, doors (counts); rec = a reclaimed fort (>= runner.reclaim.min_ws adopted at the first
  -- scan); miss = the mandatory workshops of a reclaimed fort that nothing builds yet
  adopt = obj({ws = NAT, new = NAT}, {gone = NAT, stock = NAT, wells = NAT, beds = NAT, doors = NAT, rec = FLAG,
                                      miss = arr(str(24), 0, 8)}),
  proj = arr({t = 'tup', items = {str(nil, nil, 'id'), str(24), PCT, str(40)}}, 0, 8),
  -- Run 11 siege 8: seal first (the leading open seal or plug: pieces open, projects it pauses, other open seals,
  -- stuck 1 = it built nothing for stuck_days, days) and the rebuild policy (citizens, its bounds, projects paused)
  sched = obj(nil, {seal = obj({proj = str(nil, nil, 'id'), n = NAT, paused = NAT}, {more = NAT, stuck = FLAG, days = NAT}),
                    rb = obj({pop = NAT, lo = NAT, paused = NAT}, {hi = NAT}),
                    -- BUG-116: care first (the hospital project that leads, projects it pauses, why, stuck 1 + days)
                    care = obj({proj = str(nil, nil, 'id'), paused = NAT}, {why = str(24), stuck = FLAG, days = NAT}),
                    -- BUG-037: projects waiting for a slot and the slot holders (id, template, days without own
                    -- progress); no run ended for d days (the run in hand: task i of n, its label, slices, age in days);
                    -- parked projects (blocked for good past runner queue.park_days)
                    q = obj({n = NAT, by = arr({t = 'tup', items = {str(nil, nil, 'id'), str(16), NAT}}, 0, 8)}),
                    run = obj({d = NAT}, {i = NAT, n = NAT, task = str(40), sl = NAT, age = NAT}),
                    pk = NAT}),
  bridges = obj(nil, nil, str(nil, {'up', 'down', 'moving', 'unknown', 'destroyed', 'replaced'}), 'bridge'),   -- BUG-030, BUG-048
  owners = obj({pause = {t = 'any', of = {{t = 'null'}, str(nil, {'inbox', 'gordon', 'popup', 'df'})}},
                tempo = str(nil, {'mode', 'inbox', 'brake', 'clock'})}),
  mil = obj({squads = NAT, soldiers = NAT, worn = PCT, cv = NAT, metal_pct = PCT, on_station = NAT},
            {free = obj(nil, {weapon = NAT, body = NAT, head = NAT, pants = NAT, gloves = NAT, shoes = NAT,
                              shield = NAT, ammo = NAT}),
             cap = obj({sets = NAT, melee = NAT, want = NAT, xbow = NAT}),     -- Run 11: melee follows the gear
             -- FR-79: the militia rotation per squad key (schema.py _ROT)
             rot = obj(nil, {A = ROT_ONE, B = ROT_ONE, C = ROT_ONE})}),
  trade = obj({caravan = FLAG, ratio = NAT, done = NAT}),
  clock = obj({cap = NAT, orig = NAT, ts = int(-1, 1000), held = FLAG, why = str(24)}),
  alarm = obj({defcon = int(1, 5), unacked = NAT, last = NAT, ack = NAT, lock = FLAG, why = str(24)},
              {eta = int(-1), doors = NAT, dwait = NAT, dout = NAT, dref = NAT, far = NAT,
               -- BUG-035: the open recall: called, still out of rto, left since, cannot come
               rn = NAT, rleft = NAT, rnew = NAT, rstuck = NAT, rto = str(24),
               -- BUG-065: the lockdown's age and limit (ticks, lim 0 = off), why its quiet clock does not run (near,
               -- inside, great, recent, armed, stale, run), and the cause: the nearest counted hostile, its race, kind,
               -- position, tiles to the nearest citizen outside Kern+ (dc) and entrance (de), harmless (hl), how many (n), its body size (sz)
               age = NAT, lim = NAT, qw = str(8),
               by = obj({id = NAT, race = str(24), k = str(8), pos = {t = 'tup', items = {NAT, NAT, NAT}},
                         dc = int(-1), de = int(-1)}, {hl = FLAG, n = NAT, sz = NAT, hw = str(24)}),   -- BUG-144: hw = why dangerous
               -- M3 (BUG-111/112): invaders left out of the hostiles (`id:why`: merchant, diplomat, visitor, restrained,
               -- child) and the lone harmless intruder's clock in SIEGE/BREACH (age ticks, how many, ticks until the
               -- limit releases it, the kernel's own kill order: running or why refused)
               ben = arr(str(24), 0, 5),
               ln = obj({age = NAT, n = NAT}, {rel = NAT, kill = str(80)})}),
  lever = obj({lat_s = int(-1), lat_t = int(-1), pend = NAT, wait_s = NAT}),
  alert = obj({want = str(24), burrow = str(24), tiles = NAT, inside = NAT, ok = FLAG},
              {why = str(40), core_d = NAT, core_f = NAT,           -- BUG-028: drink/food days inside the core
               aud = NAT,                                           -- BUG-146: ticks since the last refuge audit (when overdue)
               -- Run 10: the refuge burrow: exists, separated (1, 0 open, -1 unknown), beds, beds wanted (bed_pct)
               ref = obj({ex = FLAG, sep = int(-1, 1), beds = NAT, need = NAT},
                         -- BUG-040: its tiles' bbox and its nearest tile's distance to the nearest accepted source ws
                         {box = {t = 'tup', items = {int(), int(), int(), int(), int(), int()}}, wd = int(-1),
                          ws = {t = 'tup', items = {NAT, NAT, NAT}},
                          -- FR-69: drink units on its tiles, drink wanted, tiles of its drink store (0 none)
                          dr = NAT, dn = NAT, st = NAT,
                          -- BUG-049: trusted (1) or not (0) and the first reason
                          tr = FLAG, trw = str(40)}),
               -- BUG-096/FR-80: the worst open burrow episode: how many, the burrow, its tiles at the last good reading and
               -- now, the cause (load | runtime), tiles painted again, what the repair does, what the lost tiles held
               bg = obj({n = NAT, b = str(24), was = NAT, now = NAT}, {c = str(8), fx = NAT, st = str(16), crit = str(24)})}),
  -- intake waves (siege, Gordon 2026-10-16): phase, wave count, the last refusal, the sortie squad and phase; BUG-030:
  -- deep = the deep defense's reasons ('destroyers,army,weak')
  -- M3 (BUG-114): in BREACH ba = ticks since it began, bw = what it waits for (the bridges not up and why, the quiet clock)
  wave = obj({ph = str(8), n = NAT}, {why = str(40), so = str(24), deep = str(24), ba = NAT, bw = str(100)}),
  -- BUG-033: the snapshot export queue: requests waiting (the running one included), the oldest one's age (s), exports
  -- written and requests dropped this boot; the running (else the first waiting) export: id, purpose, who asked,
  -- progress, why it waits
  snap = obj({q = NAT, old_s = NAT, done = NAT, drop = NAT},
             {run = str(nil, nil, 'id'), p = str(nil, {'audit', 'sites', 'debug'}), by = str(24), pct = PCT,
              wait = str(24)}),
  -- water (BUG-034): patients, their max thirst, the hospital served (flag) and its zones, the refuge's well, free
  -- buckets, the accepted sources (a well over water, a Water Source zone on water >= 4/7) nearest first
  water = obj({patients = NAT, thirst_max = NAT, hosp_ok = FLAG, refuge_ok = FLAG, buckets_free = NAT, hosp = NAT,
               src = arr({t = 'tup', items = {NAT, NAT, NAT}}, 0, 8)},
              -- BUG-036: hospital zones with tiles outside Kern+ and the refuge; BUG-040: a label per src ('well 19098
              -- in Kern+')
              {hosp_out = NAT, src_l = arr(str(32), 0, 8),
               -- BUG-106: the tokens of the hospital's gaps (no_table, no_thread, ...), the first eight; inspect what=hospital
               gaps = arr(str(16), 0, 8),
               -- BUG-131: the first blocking hospital zone outside the core: id, centre, ok 1 = a finished hospital inside
               -- (hospital.retire needs no approve), pat = patients lying in it
               hout = obj({z = NAT, at = {t = 'tup', items = {NAT, NAT, NAT}}, ok = FLAG}, {pat = NAT})}),
  -- FR-96/97 (traps.lua, daily): armed (n) of the manifest's trap tiles (m); built, ways trapped / listed, full cage traps,
  -- free cages, listed tiles without a trap (lost; lh: some in the hall), the last cage order
  traps = obj({n = NAT, m = NAT}, {b = NAT, w = NAT, wn = NAT, f = NAT, c = NAT, l = NAT, lh = FLAG, ord = str(40)}),
  -- FR-98: the cavern sweep: st = its phase (off, wait, open, muster, kill, recall, close), why = what it waits for or how the
  -- last one ended, n = beasts seen at the plugged shafts, k/l = kills and losses of the running (else the last) sweep, acc =
  -- plugged cavern shafts, clr = 1 the caverns count as clear (the P6 deliverable sweep)
  cav = obj({st = str(nil, {'off', 'wait', 'open', 'muster', 'kill', 'recall', 'close'})},
            {why = str(60), n = NAT, k = NAT, l = NAT, acc = NAT, clr = FLAG}),
})

-- string formats (§1.1); explicit byte ranges, so LC_CTYPE cannot change them
C.FMT = {
  id = function(s) return #s >= 1 and #s <= 40 and not s:find('[^A-Za-z0-9_%-]') end,
  bridge = function(s) return #s >= 1 and #s <= 8 and s:find('^[A-Z]') ~= nil and not s:find('[^A-Za-z0-9]') end,
  module = function(s) return #s >= 2 and #s <= 16 and s:find('^[a-z]') ~= nil and not s:find('[^a-z_]') end,
  phase = function(s) return s:find('^P[0-7]$') ~= nil end,
}

local OBJECT_MT = getmetatable(json.object{})
-- JSON kind of v as util/json encodes it (floats are written rounded, NaN/inf as null)
local function kind(v)
  local tv = type(v)
  if v == nil or v == json.null then return 'null' end
  if tv == 'number' then
    if math.type(v) == 'float' and (v ~= v or v == math.huge or v == -math.huge) then return 'null' end
    return 'int'
  end
  if tv == 'boolean' then return 'bool' end
  if tv == 'string' then return 'str' end
  if tv ~= 'table' then return tv end
  if json.is_array(v) then return 'arr' end
  if getmetatable(v) == OBJECT_MT then return 'obj' end
  local n, c = #v, 0
  for _ in pairs(v) do c = c + 1 end
  return c == n and 'arr' or 'obj'
end
local function as_int(v)
  if math.type(v) == 'float' then return v >= 0 and math.floor(v + 0.5) or -math.floor(-v + 0.5) end
  return v
end
local function keystr(k) return math.type(k) == 'integer' and string.format('%d', k) or tostring(k) end

local check
local function expect(spec_t, k, path, out)
  out[#out + 1] = path .. ': expected ' .. spec_t .. ', got ' .. k
end
function check(s, v, path, out)
  local k, t = kind(v), s.t
  if t == 'any' then
    for _, alt in ipairs(s.of) do
      local e = {}
      check(alt, v, path, e)
      if #e == 0 then return end
    end
    out[#out + 1] = path .. ': no alternative matched'
  elseif t == 'null' or t == 'bool' or t == 'int' or t == 'str' then
    if k ~= t then return expect(t, k, path, out) end
    if t == 'int' then
      local n = as_int(v)
      if s.lo and n < s.lo then out[#out + 1] = string.format('%s: %d < %d', path, n, s.lo)
      elseif s.hi and n > s.hi then out[#out + 1] = string.format('%s: %d > %d', path, n, s.hi) end
    elseif t == 'str' then
      local ok = true
      if s.enum then
        ok = false
        for _, e in ipairs(s.enum) do if e == v then ok = true end end
      end
      if not ok then out[#out + 1] = path .. ': ' .. v .. ' not in enum'
      elseif s.fmt and not C.FMT[s.fmt](v) then out[#out + 1] = path .. ': ' .. v .. ' is not a ' .. s.fmt
      elseif s.max and #json.utf8_clean(v) > s.max then out[#out + 1] = path .. ': longer than ' .. s.max .. ' bytes' end
    end
  elseif t == 'const' then
    if (type(s.v) == 'number' and (k ~= 'int' or as_int(v) ~= s.v)) or (type(s.v) ~= 'number' and v ~= s.v) then
      out[#out + 1] = path .. ': expected ' .. tostring(s.v)
    end
  elseif t == 'arr' or t == 'tup' then
    if k ~= 'arr' then return expect('array', k, path, out) end
    local n = #v
    if t == 'tup' then
      if n ~= #s.items then out[#out + 1] = path .. ': expected ' .. #s.items .. ' items, got ' .. n; return end
      for i = 1, n do check(s.items[i], v[i], path .. '[' .. (i - 1) .. ']', out) end
      return
    end
    if n < s.lo then out[#out + 1] = path .. ': ' .. n .. ' items < ' .. s.lo end
    if s.hi and n > s.hi then out[#out + 1] = path .. ': ' .. n .. ' items > ' .. s.hi end
    for i = 1, n do check(s.items, v[i], path .. '[' .. (i - 1) .. ']', out) end
  elseif t == 'obj' then
    if k ~= 'obj' then return expect('object', k, path, out) end
    local req = {}
    for key in pairs(s.req) do req[#req + 1] = key end
    table.sort(req)
    for _, key in ipairs(req) do
      if v[key] == nil then out[#out + 1] = path .. '.' .. key .. ': missing'
      else check(s.req[key], v[key], path .. '.' .. key, out) end
    end
    local keys = {}
    for key in pairs(v) do keys[#keys + 1] = keystr(key) end
    table.sort(keys)
    for _, ks in ipairs(keys) do
      local x = v[ks]
      if x == nil then x = v[math.tointeger(tonumber(ks))] end
      if s.req[ks] == nil then
        if s.opt[ks] then check(s.opt[ks], x, path .. '.' .. ks, out)
        elseif not s.extra then out[#out + 1] = path .. '.' .. ks .. ': unknown key'
        else
          if s.keys and not C.FMT[s.keys](ks) then out[#out + 1] = path .. ': key ' .. ks .. ' is not a ' .. s.keys end
          check(s.extra, x, path .. '.' .. ks, out)
        end
      end
    end
  else
    error('contract: bad spec node ' .. tostring(t))
  end
end

-- Errors of a state document (strings 'path: msg', [] = valid), judged as util/json would write it.
function C.check_state(doc)
  local out = {}
  check(C.STATE_SPEC, doc, '$', out)
  return out
end

-- Drop every optional top-level key that has an error (kern does this before writing, §9.3).
-- Returns dropped keys (sorted) and all errors found; errors in required keys stay (kern logs them).
function C.prune_state(doc)
  local errs = C.check_state(doc)
  local dropped, seen = {}, {}
  if type(doc) ~= 'table' then return dropped, errs end
  for _, e in ipairs(errs) do
    local top = e:match('^%$%.([^.%[:]+)')
    if top and not C.STATE_SPEC.req[top] and not seen[top] and doc[top] ~= nil then
      seen[top] = true
      dropped[#dropped + 1] = top
      doc[top] = nil
    end
  end
  table.sort(dropped)
  return dropped, errs
end

return C
