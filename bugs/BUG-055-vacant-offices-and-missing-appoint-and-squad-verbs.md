# BUG-055 Vacant offices nobody fills or reports (chief medical dwarf, squad leaders); appoint and the squads screen are no verbs
Status: fixed in 3713b78, 46203be (offline, live-untested): economy fills CHIEF_MEDICAL_DWARF, readiness R0
`office` names every vacant manager/chief medical dwarf office and squads without a leader with the command that fixes it,
verbs `appoint`, `squad.create`, `squad.leader`, `squad.add`, `squad.uniform`, `inspect offices`; why the kernel could
not create a squad in Run 11 is NOT decided offline (live data below)
Severity: high (wrong decision: no hospital administrator, no squads, silently)
Found: 2026-10-23, Run 14 y577 (note 61, Gordon's question), Run 11 y497 (note 25), Run 14 Trussroads (note 64)
Module: `lua/dfllm/economy.lua` (`M.POSITIONS`, `appoint_vacant`), `lua/dfllm/military.lua` (`ensure_squad`, `stuck`),
`lua/dfllm/readiness.lua`, `lua/dfllm/act.lua` (appoint, squad_*), `dfpilot/schema.py`

## Actual
- Run 14 y577: the CHIEF_MEDICAL_DWARF position was ACTIVE and vacant for good with an available candidate (a level 13
  diagnoser); manager, bookkeeper and broker were filled. `status`/`brief`/SIEGE_UNREADY knew `hospital_out` only.
- Run 11 y497: DECISION_NEEDED `squads` "appoint a militia commander/captain (nobles screen)": no captain, no squads; the
  kernel could not say why or how.
- `act.appoint`, `squad_create`, `squad_leader`, `squad_add`, `squad_uniform` existed but were no inbox verbs: the game
  session replayed `seat_figure` and `act.lua` by hand in scratch scripts (notes 61, 64).

## Cause (proved from the code at f17e2b3)
1. `economy.lua:2267` `M.POSITIONS` listed MANAGER, BOOKKEEPER, BROKER only; `appoint_vacant` (daily task `appoint`) never looked at
   another office, and nothing reported a vacancy (`positions()` returned the vacancies to nobody).
2. `schema.VERBS` / `contract.lua C.VERBS` had no `appoint` and no `squad.*`; `act.appoint` is owned by economy,
   `squad_*` by military (`contract.lua` ACT), so no other module could call them either.
3. `military.stuck()` (`military.lua:557-585`, old) printed a fixed text: neither the act's refusal text nor a way to do it.
4. The militia posts are different from the economy offices: `military.free_assignment` and `act.squad_assignment`
   (`act.lua:600-613`) create a squad on a VACANT (`histfig == -1`, `squad_id == -1`) MILITIA_COMMANDER/CAPTAIN
   assignment and seat its leader with `squad_leader`. An appointment made earlier (`act.appoint` on such an assignment)
   would take it out of their reach. So the kernel must NOT pre-appoint the militia posts: "fill them through act.appoint"
   holds for the economy offices; for the militia the equivalent is creating the squad with its leader.

## Not decided offline (live data that decides)
Why `squad_create` failed in Run 11: no ACTIVE militia position, no vacant assignment and no MILITIA_CAPTAIN position to
add one, or `makeSquad` refused. Read-only: `dfllm cmd inspect '{"what":"offices"}'` (`squads`: ACTIVE militia codes,
vacant assignments without a squad, the act's refusal text and how long) and the DECISION_NEEDED `squads` `q` (now names
`refused: <act text>`). What `ent.positions.assignments` looks like for MILITIA_* after a nobles-screen appointment of a
commander (squad_id, histfig) decides whether a pre-appointed commander is handed to a new squad by the game itself.

## Fix
- `economy.M.POSITIONS` + `CHIEF_MEDICAL_DWARF` (skills DIAGNOSE, SURGERY, SET_BONE, SUTURE, DRESS_WOUNDS): best candidate
  by skill, never a squad member (the existing rule), not twice in an office when someone else can. `appoint_vacant`
  records the vacancies (`m.economy.vac`: first tick seen vacant), `economy.offices(K)` returns them (code, n, days,
  candidate, why none was appointed).
- Readiness R0 blocker `office` (config `offices.blocker_days`, 7; 0 = never): an office of MANAGER or CHIEF_MEDICAL_DWARF
  vacant that long, or `military.leader_state` reporting a refused squad creation that long. State `ready.office`
  (the text with the command), SIEGE_UNREADY `office`, status line `next:`, wake hint. BOOKKEEPER and BROKER vacancies
  are listed by `inspect offices` but block nothing.
- Verbs (closed set, RULES section 6, CONTRACTS section 13): `appoint {code, unit}` (economy; a squad member is refused
  for every code but MILITIA_*), `squad.create {name, leader?, assignment?}`, `squad.leader {squad, unit}`,
  `squad.add {squad, unit}` (needs a leader), `squad.uniform {squad: A|B|C, kind?}` (military, PEACE/ALERT/RECOVERY only;
  `squad` = A/B/C or the game's squad id; the uniform keeps military's weapon guard). `inspect offices`.
- `military.stuck`: the DECISION `q` names the act's refusal and the verbs.

## Safety
The new office fill is the nobles screen's action on a vacant, offered position (fair play: same records as the existing
three). The verbs refuse fights (SIEGE/BREACH/DRILL) for the squads screen; `appoint` is any mode but refuses soldiers.
R0 `office` freezes max-pop growth only after 7 days of failure (a fort of 7 has candidates; a fort whose every adult is a
soldier shows `no adult citizen outside the squads`). No change to squad creation itself.

Review fix: `military.leader_state` read `rt.create_why`, which only the creation path cleared; squads made by the verb
`squad.create` (or on the squads screen) are adopted without reaching it, so the refusal stayed and R0 `office` stayed set
after the very fix it names. The main loop now clears it when no wanted squad is missing or leaderless
(`test_a4_offices.lua`, "review A4").

## Tests
`tests/lua/test_a4_offices.lua` (fill by skill, never a soldier; the view with days/candidate/reason; verb appoint and its
refusals; leader_state and the DECISION text; the squad verbs and their modes; uniform), `tests/lua/test_readiness.lua`
(the blocker, days, codes, config), `tests/test_a4_health.py` (schemas, modes, RULES, config, status/wake texts). All new
ones fail on f17e2b3.

Related: BUG-042 (manager office), notes 25, 61, 64 of RUN11-offene-bugs-und-FR.md; FR-71 (package A3, the militia windows)
