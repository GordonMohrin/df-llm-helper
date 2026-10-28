# BUG-115 Curses and transformations are invisible to the kernel: "has been cursed by Ok!" woke nobody, 23 dwarves became werecavies, pop 54 -> 10
Status: fixed in the M4 commit (offline, live-untested): care reads the game's curse and transformation reports whatever their
announcement type (kern routes a report by `care.report_text`) and the unit sheets, emits CURSED / TRANSFORM (class A, interrupts)
and CURSE_MOON (class A), keeps the list in the persisted care state, publishes state `curse`, and the arbiter leaves such popups
for the player; the announcement type name and the form of a were-unit on the sheet are the live data that is not decided offline
Severity: critical (the fort fell to a curse nobody was told about; a repeat costs the whole population)
Found: 2026-10-25/28, Run 14 (Trussroads, y707 d074 - y708), game session note 84 (`bugs/RUN11-offene-bugs-und-FR.md`);
`docs/v2/POSTMORTEM-run14-trussroads-y708.md`
Module: `lua/dfllm/curse.lua` (new library), `lua/dfllm/care.lua` (`M.report_text`, `M.on.REPORT`, `look_unit`, `M.state`, `M.inspect`,
`M.curse_text`), `lua/dfllm/kern.lua` (`text_hit`, `report_event`, `deliver`, `INSPECT_BY`, `SHRINK`), `lua/dfllm/arbiter.lua` (`M.DENY`,
`M.were`), `lua/dfllm/reflex.lua` (defaults, `EV:CURSED`, `EV:TRANSFORM`), `lua/dfllm/util/contract.lua`, `dfpilot/schema.py`,
`dfpilot/wake.py`, `dfpilot/brief.py`, `dfpilot/fairplay.py`

## Actual
y707 d074: a miner toppled a statue in a tantrum and the game said "<name>, Miner has been cursed by Ok!"; he became a werecavy.
Every full moon (d155, d180, d206, d232, d258: 336 / 13 = 25.85 days apart) the cursed turned, bit, and the bitten turned at the next
moon; 23 dwarves (the mayor, the manager, the chief physician and the bone doctor among them) changed form, 11 were "killed by
dwarf", 17 bled and 17 suffocated (neck wounds, mostly patients). The popup stood "unclassified"; the session clicked it away
without reading it; no event, no wake, no line in the status. DEATHS_3PLUS woke with causes (`killed`, `bled`) that did not say why.

## Causes (proven from the code at 32994bb)
1. **No module listens to the report.** `care` filters reports by announcement type (care.lua:93-95 `M.reports`: mood, toppled
   building, tantrum types); kern delivers a REPORT only to a module whose filter holds the type (kern.lua:1099 `deliver`,
   kern.lua:1107 `report_event`: `if not tname or not (st.report_any or st.report_types[tname])`). Nothing names a curse or
   transformation type; `util/contract.lua` `C.REPORTS` has `WEREBEAST_ARRIVAL` only (a foreign werebeast walking in, reflex.lua:151),
   which is a different announcement. The type DF uses for "has been cursed by" is not in the repo and cannot be read offline, so a
   type filter would guess; the route has to work on the text (the fix) and log the type it saw.
2. **The popup is not read.** `arbiter.classify` (arbiter.lua:456-472) knows the migrant, caravan, death, mood, noble, berserk and
   threat texts; "has been cursed" matches none, so the popup stays and `note_left` (arbiter.lua:523) logs
   `popup left for the player (unclassified)` once per 15 minutes. `M.DENY` (arbiter.lua:92) holds `werebeast` and `vampire` but
   neither `cursed` nor `transformed`, and the word `were` is no entry: the catch-all `popups.other` (FR-75) would have cleared a
   curse popup after 20 s had it been switched on (`other_popup` checks `denied`), and the broad `arrival` words would have cleared
   "... have arrived ... werecavy". The game halts on the popup; the session cleared it with its own tooling (post-mortem 2).
3. **The units are not read.** care's unit scan (`look_unit`, care.lua:658-671) counts stress, thoughts and nakedness; it never reads
   `unit.curse` or the race. A unit cursed before the kernel booted, or a transformation whose text we never matched, stays unknown.
4. **The death causes hide the chain.** deaths.lua's categories (`D.CATS`, deaths.lua:33: killed, bled, suffocated, ...) are the
   wound's, not the attacker's; no field names a were-form biter, so DEATH_CLUSTER and DEATHS_3PLUS read "killed 11, bled 17,
   suffocated 17" and nothing said why. (Unchanged by this fix: TRANSFORM / CURSED now come first and name the units.)
5. **A transformed citizen is not a hostile to the kernel.** sense.lua:377-383 treats an own unit as never hostile
   (`isCitizen(u, true)` / `isResident(u, true)` -> `return 7`); a were-form unit that DF still counts as a member of the fort
   raises no INTRUDER, no SIEGE_START, no lockdown. Whether DF counts the were-form as a member is not decided offline (below),
   so the fix does not change sense: the TRANSFORM event and the player's decision carry it.

## Fix
- **kern routes a report by text** (kern.lua `text_hit`, `report_event`, `deliver`; k_mock mirrors it): a module may declare
  `M.report_text` (lower case plain markers); a report of ANY announcement type whose text holds one is delivered to it. care declares
  `has been cursed`, `been cursed by`, `transformed into`, `has transformed`, `transforms into` (curse.lua `M.TEXTS`). The event
  carries the announcement type name in `ann` (`sheet` for the unit sheet, `POPUP` for a popup the arbiter left): the live data.
- **`lua/dfllm/curse.lua`** (a library of care, no new module): `parse` the text (name, god, form, direction), find the citizen by
  name among the citizens (one match only, as BUG-064), find the trigger (care's own BUILDING_TOPPLED records of that unit within
  `curse_trig_win` 4800 ticks, a tantrum seen), keep a record per unit in the persisted `care.cur` (bounded by `curse_keep` 60, the
  transformed longest), read the unit sheet in care's own sliced scan (`unit.curse.name` when it is a string and `name_visible` is not
  false; the race name of the unit containing `were`), forget the dead each run (counted in `dead`).
- **Events** (contracts in schema.py and contract.lua; RULES section 7 row): CURSED (A, interrupt) for a unit that was not known
  (unit, name, god, trig, ann, kind were|vampire|?, n cursed now, ids, moon, mi); TRANSFORM (A, interrupt) for a change of form
  (dir beast|back, to, n were-form now, bite 1 for a unit no curse report named); CURSE_MOON (A) `curse_moon_lead` (4) days before the
  next full moon while citizens are cursed, once per moon and again for a new cursed unit (util/cadence). Cadence: at most one CURSED
  and one TRANSFORM event per `curse_every` (600) ticks, the units that came in between wait in a queue and go out as one merged event
  (`more`, ids <= `curse_ids` 8, the record <= `curse_keep`): 23 curses are two events, not 23. A beast also asks DECISION_NEEDED
  `curse_kill` (once per set of were-form units; util/cadence): a kill order only after the player's yes (`squad.sortie`
  `approve:true`), RULES section 1 / DOCTRINE. reflex records both as interrupts (alarm.txt); defaults: CURSED none, TRANSFORM the
  clock only (`config/reflex.json` `defaults`), never a lockdown: the beast is among the citizens, not at the gate.
- **The moon.** 13 full moons a year (`curse_moon_cycles`), the phase calibrated by the first transformation of each wave (`care.cur.mt`),
  from the new year before a wave was seen (an estimate, said so in `inspect what=curse`).
- **State and status.** Top-level state `curse` {n, tf, ids <= 8, mo, mi, dead} (owner care, shed last by kern); the status line
  `CURSED 3 (ids 5,6,7), 1 in were-form, next full moon ~d206 (in 4 d)` (rank 2); `inspect what=curse` lists the cursed (<= 40) with
  god, kind, form, trigger, source. The persisted list is `m.care` `cur` (about 120 bytes a record, 60 at most); the 4 KB state shows
  ids only.
- **The wake recipe.** `next:` of CURSED / TRANSFORM / CURSE_MOON and the brief's `## curse (recipe)`: all the cursed into ONE room
  before the moon (a burrow they are restricted to + a forbidden door, set by the player in DF: no kernel verb paints a burrow or
  forbids a door for a unit), a were-form unit is an enemy (keep the rest away, a kill order only on the player's yes), watch the
  bitten (TRANSFORM `bite`).
- **The arbiter.** `M.DENY` gains `cursed`, `transformed`, `transforms into` and `M.were` (a word starting `were` + a letter, not
  `weren't`): such a popup is never cleared by the catch-all or the broad arrival words; care is told of its text once
  (`care.curse_text`), a curse already known from its report is no news.
- Unchanged: popups of the known kinds, the berserk question, sense and threat (cause 5), every fort without a curse (no event, no
  state key, no status line; the sheet scan adds a few reads to each citizen of care's run).

## Not decided offline
- **The announcement type name** of "has been cursed by" and of the transformation (the fix does not need it). Live: read `ann` of the
  first CURSED / TRANSFORM event (events.jsonl, wake line `d`), or `dfhack-run lua` `df.announcement_type[<report.type>]` of the
  newest report whose text contains `cursed` (read-only).
- **Whether the were-form changes `unit.race`**, what the creature's name is (`werecavy`?), whether `unit.curse.name` / `name_visible` are
  set on the sheet of a cursed unit before and after the change, and whether DF counts a were-form citizen as a member of the fort
  (`isCitizen`). Live, read-only, on a transformed dwarf: `inspect what=unit key=<id>` (`curse.name`, `curse.form`, `curse.tf`,
  `unread`), `dfhack.units.isCitizen(u, true)`, `isDanger(u)`, `isInvader(u)`, `dfhack.units.getRaceName(u)`. If the race does not change, the
  report is the only signal and a "back" text must be matched (`has transformed into a dwarf` is assumed).
- **The moon phase**: the three offsets in the Run 14 log (d155 d180 d206 d232 d258) fit k x 336/13 from the new year to within a day
  (155.1, 180.9, 206.8, 232.6, 258.5); whether the cycle is tied to the calendar or to the world's moon, and which day of the night the
  change happens, is read from `care.cur.mt` after the first wave (`inspect what=curse`: `calibrated 1`).
- **The text forms** ("has been cursed by Ok!" is from the session's note; "has transformed into a werecavy" / "into a dwarf" likewise).
  A variant that matches none of the five markers is not seen as a report, but the sheet scan still finds the unit as soon as its
  curse name or race shows; the arbiter's popup route covers the words `cursed` / `transformed`.
- **Healing.** A cursed unit that is cured is not noticed (no known signal); he stays listed until he dies.
- **Vampires** are listed when a sheet names them (`name_visible` true) or a text says so; a hidden vampire is not read (fair play:
  only what the unit sheet shows).

## Tests
`tests/lua/test_curse.lua` (23: parse, moon, the report of an unlisted type, trigger, cadence, burst of 23, bound, bite, death,
sheet, hidden curse, struct-valued name, race change and back, a fort of 80, CURSE_MOON, reload and old state, `curse = false`,
`inspect what=unit`, the desperate list), `tests/lua/test_curse_kern.lua` (2: kern text route on the real kernel and its opt-in, the DENY words and
`M.were`, the popup left alone and care told once, the known popups still cleared), `tests/lua/test_reflex.lua` (1: interrupts and defaults),
`tests/test_m4_curse.py` (16: contracts, config limits, wake line within 150 tokens, status and brief budgets, worst case, documents).
All fail on 32994bb.
