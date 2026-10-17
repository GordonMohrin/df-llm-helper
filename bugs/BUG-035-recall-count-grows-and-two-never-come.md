# BUG-035 The recall's count grows past its start ('9 of 5 still outside') and two citizens never come in
Status: fixed (offline, live-untested): the recall follows the citizens it called by id and measures arrival in the
burrows the alert really confines to, newcomers counted apart; every citizen still out is diagnosed (read-only) with a
reason; seal's path check finds a way that crosses doors this lockdown forbade and the door opens again for him;
citizens who cannot come hold no door (RECALL `stuck`); water and `refuge_dry` say where the wells are
Severity: high (citizens locked out with the enemy; the doors held open 2,400 ticks for someone who cannot come)
Found: 2026-10-17, Run 11 fort Kilrudrabed (site98), y445, siege 9 (invasion 13: 2 cave dragons, 2 goblins, a snatcher,
then an ambush; 6 foes, 1 killed; pop 49 -> 39, soldiers 16 -> 6), dfpilot main 784399f, from the game session's events
and kern.log
Module: `lua/dfllm/reflex.lua` (the recall), `lua/dfllm/sense.lua` (census `outside`), `lua/dfllm/seal.lua`
(`door_outside`, the entrance doors), `lua/dfllm/gate.lua` (lever pullers), `lua/dfllm/water.lua`, `readiness.lua`

## Actual
- ARRIVAL siege: `recall: 5 outside Kern+`; kern.log `called into Kern+, the doors wait up to 2400 ticks` (as designed).
  Then `recall: 9 of 5 still outside after 1246 t`, `recall: 8 of 5 still outside after 1265 t`; then SIEGE_DEEP and a
  BREACH (O1 destroyed), REFUGE_SWITCH Kern+ -> Tiefe+ (event #10079).
- The ambush after it: `recall (arrival:ambush): 2 of 2 citizens still outside Kern+ after 2407 ticks: the doors stop
  waiting`, at the lockdown's end after 4807 ticks still 2 of 2 (RECALL end, left 2, eta -1), never `done`. The alert
  confined to Tiefe+, the texts said `outside Kern+`; the doors line said `8 waiting for 1 citizen outside`.
- The two (RECALL units 28346 at 135,77,137 and 28350 at 133,86,137) were the same in both lockdowns: adults, job IDLE,
  unhurt (28350 one wound), not caged, not lying, both legs, walk group 29 like all 39 citizens.
- `water: ... refuge dry, 1 wet sources (13 wells)`: 13 wells, none said where; status `SIEGE UNREADY (R0): ...
  refuge_dry` (correct).

## Causes (proved from the code at 784399f)
1. **The count is the live total, the start is a fixed number.** `recall_step` compared `census.u.outside` (reflex.lua:853)
   with `rc.n` from the start (reflex.lua:790); anybody who left Kern+ after the alert raised `left` past `n`.
2. **`outside` is "on no Kern+ or Tiefe+ tile"** (sense.lua:131-133), whatever the alert confines to. Tiles in neither
   burrow (the stairs and passages between Kern+ and Tiefe+, a corridor, the lever rooms, Hebel+, Innen+) count as
   outside. Who leaves Kern+ after the alert, by the code:
   - gate's lever pullers: in SIEGE/DRILL/BREACH gate assigns 2 adult civilians to each `dfllm-levers*` room
     (gate.lua:357, 566-632, act.burrow_units) and siege lists the room in the alert (siege.lua:826-833); they walk out
     to the levers and stay there on purpose (+2 per room);
   - a confined civilian takes a PullLever job in `Hebel+` and walks out of Kern+ to it (BUG-013's design);
   - after the REFUGE_SWITCH to Tiefe+ every citizen walks down through tiles in neither burrow.
   Refuted by the code's own live record: a confined dwarf does not walk out for a drink (gate.lua's puller comment,
   live L3: 21 thirsty citizens stayed in the alert burrow).
3. **The texts say `Kern+` whatever the burrow** (reflex.lua:796, 817-818, 826-834), and with the alert on Tiefe+ the
   recall still measured Kern+ ∪ Tiefe+: citizens in Kern+, not yet in Tiefe+, counted as in.
4. **A door is forbidden although a recalled citizen's only way in crosses it** (hypothesis (i), proved). The lockdown
   forbids a door once `seal.door_outside` counts nobody on its outside side (reflex.lua forbid_doors); that side is the
   doorway, a revealed open-sky tile of the door's walk group, or the porch of an opening it closes (seal.lua:3156-3195).
   The porch is a walk from the opening that stops at every door and after 200 tiles (seal.lua:1863-1867, door_walk). So
   a citizen in a roofed room off the porch behind its own door, or in a roofed area farther than 200 tiles, is on no
   outside side: the entrance door is forbidden at once and he cannot get in. Worse, seal's entrance doors include the
   first door on the route from an opening toward the nearest citizen (seal.lua:1844): when that citizen stands behind
   it, the lockdown forbids the door of his own room. Walk groups ignore a forbidden door (group 29 for all proves
   nothing); DF leaves a civilian idle when the alert burrow has no path. `tests/lua/test_recall.lua` reproduces both.
5. **A citizen who cannot come holds the doors** for RECALL_MAX: `door_outside` counts every non-soldier citizen on an
   outside tile whatever his state (lying, caged, held at a lever by gate), reflex.lua:270 then waits 2,400 ticks. A
   lever puller on an open-sky lever strip holds every door of his walk group (seal.lua:3181).

## Not decided offline (the live data that decides it)
- **Why 28346 and 28350 stood idle.** Two candidates fit the facts: gate's lever pullers (IDLE by design, outside Kern+/
  Tiefe+) or a door forbidden on their only way in (cause 4: idle, unhurt, one walk group). The ambush's alert on Tiefe+
  and a lockdown of its own (`arrival:ambush`) suggest PEACE/ALERT, where gate assigns no pullers: that points to cause
  4. Decides it: kern.log `gate: lever pullers <room> = {...}` lines in siege 9 and the ambush (do they hold 28346 or
  28350?), the lockdown's door lines (`reflex: N more entrance doors forbidden: ...`, ARRIVAL `doors N forbidden`) with
  the positions of those doors against 135,77,137 / 133,86,137, and the mode at the ambush. After this fix: kern.log
  `reflex: recall: out at the alert: 28346:...`, RECALL `stuck`/`late`/`end` `d.reasons` (`puller:dfllm-levers`,
  `door:<id>` / `locked:<id>`, `idle`), and `reflex: recall: door N (x,y,z) opened again: citizen ...`.
- **Who made `9 of 5`.** Pullers walking out, a PullLever job in Hebel+, or the walk down to Tiefe+ after the switch.
  After this fix: kern.log `reflex: recall: N more citizens out of <burrow> since the alert ...: id:key@x,y,z`
  (`puller:...`, `job:PullLever`, `walk`, `idle`) and `the civ alert moved from Kern+ to Tiefe+`.
- **DF details the diagnosis reads** [? live]: `flags1.rider` for a carried baby or a snatched child, `flags1.on_ground`
  for lying, `unit.burrows` for a unit's own burrow assignment, `unit.path.dest`; all read under pcall (a missing field
  reads as nothing).

## Expected
The recall says how many of the citizens it called are still out of the burrow the alert confines to, apart from those
who left it since; it names each one with where he stands and why he is not in; a door is never forbidden on the only
way in of a recalled citizen while it waits for him; a citizen who cannot come holds no door and is reported once.

## Fix
- **sense:** `recount(names)` (reflex at the recall's start and when the alert's burrow moves): every citizen scan also
  counts `census.u.away`, `away_ids` (<= 40), `away_to` against those burrows.
- **reflex, the recall:** its burrows = the alert's own (siege lists it first) plus Kern+/the refuge/Innen+ when listed
  (lever burrows are no destination); `n` and the ids (<= 40) from that count; each poll the start ids still out
  (`left`) and those out since (`nnew`, newcomers named once in kern.log); a switch of the alert's burrow re-targets it
  (kern.log). Texts name the burrows: `recall: 3 of 5 still outside Tiefe+ after 1246 t, +4 more out since, 2 cannot
  come`.
- **reflex, the diagnosis** (read-only, by census id, RECALL_DIAG 300 ticks, <= 40 + 20 ids, only while a recall is
  open): gone, caged, chained, carried, mood, down, patient, sleep, `puller:<room>` (gate.puller_of), `burrow:<name>`,
  walk, `job:<type>`, away, idle; `/res` for a resident who is no citizen. kern.log at the start names them all.
- **seal, the path check** (`seal.recall_path`, an urgent sliced job, <= 6,000 tiles a citizen, revealed tiles of his
  walk group, a forbidden door crossable at the cost of one door, <= 2): RECALL_PATH (600) ticks after the alert for one
  who could come. Only through doors this lockdown forbade: they open again for him (no hostile within DOOR_NEAR, before
  RECALL_MAX) and wait until he is in (`door:<id>`); a door the player forbade, a hostile at it or the doors done
  waiting: `locked:<id>`; `group`; `path`.
- **Doors:** the NOHOLD keys hold no door (`seal.door_outside(ids, skip)`); a hostile within DOOR_NEAR still forbids at
  once (a reopened door too, its citizen then `locked`). Gate's pullers never keep the recall open (`pull`).
- **RECALL (B):** why `stuck` once per lockdown; `reasons` (`id:key@x,y,z[/dN][/res]`), `stuck`, `pull`, `nnew`, `newu`;
  ARRIVAL/LOCKDOWN `rc_new`; state `alarm` `rn`, `rleft`, `rnew`, `rstuck`, `rto`; `dfllm status`/`brief` show it.
- **Water (task 2):** `water: ... refuge dry (13 wells, 0 in Tiefe+), 1 wet sources`; kpi `rwells`, `rwet`; readiness
  `refuge_dry` says `no well in Tiefe+` or `its 2 wells are dry` (`readiness.refuge_dry()`).

## Found on the way (not fixed here)
- **Soldiers are never waited for.** The census and `seal.door_outside` leave soldiers out (sense.lua:131, seal.lua
  door_outside's `sold`), and the civ alert does not call them: a soldier outside the doors when they are forbidden (a
  squad stationed or training outside, off-duty soldiers hauling) is locked out, and a squad whose station lies inside
  cannot reach it through a forbidden door. The recall never names a soldier. Worth a look for siege 9's 16 -> 6.

## Tests
`tests/lua/test_recall.lua` (each fails on 784399f; the first one prints the old `recall: 7 of 3 still outside`),
`tests/lua/test_water.lua`, `tests/lua/test_readiness.lua`, `tests/test_cli_status.py`.
