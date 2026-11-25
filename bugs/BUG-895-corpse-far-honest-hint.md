# BUG-895 Two unburied dead out of reach (corpse_far): the ladder says tombs.repair, which cannot reach them, and counts them against the track for ever
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17c i3 Orangering y459: `inspect tombs` 'unburied [{u 26637 p [88,83,145] why corpse_far}, {u 26638 ...}]', 69 free coffins, 0 burial jobs; both lay on a wall top in another walk group (group 2220 / 2147); `leiter.t_wohl`: 'NAECHST Wohl I: 2 Tote unbestattet -> tombs.repair'; `tombs.repair` answered 'queued: the next care run repairs the tombs and retries entomb' and nothing could happen.
Module: `lua/dfllm/care.lua` (`finish` ~l.5432, `M.verbs['tombs.repair']` ~l.6018), `dfpilot/leiter.py` (`t_wohl` ~l.174), `dfpilot/schema.py`, `lua/dfllm/util/contract.lua`

## Cause
`care.far_bodies` marks a body another walk group holds as `corpse_far` ('no coffin, zone or hauler helps'); `finish` counted it in `corpses_old` (only `unr`, tree crowns and no walk group, was excluded) and `t_wohl` turned `corpses_old > 0` into the repair command; the verb's 'not repairable, a memorial slab is their burial' text was only for `unr_ids`.

## Fix
The remedy exists in the code: the memorial slab (`MEM.early`, config `care.mem_early`, `mem_wait_days` 7: a far body with a historical figure gets a slab ordered and placed by care itself, state `none -> order -> loose -> build -> placed`; there is no player command for it). `finish`: a far body whose slab is `placed` is not in `corpses_old` any more (state `care.corpses_far_mem`); `care.corpses_far` = the old bodies that are far (a subset of `corpses_old`). `leiter.t_wohl`: when every unburied body is far, no `tombs.repair` and no tombs project: 'N Tote ausser Reichweite (corpse_far, andere Wegegruppe): kein Grab moeglich, Gedenkplatte ist die Bestattung' with `dfllm cmd inspect what=tombs` (slab state). `tombs.repair` answers also for far bodies (not only tree crowns): 'N corpses out of reach (another walk group, unit U at x,y,z): tombs.repair cannot reach them, a memorial slab is their burial (slabs: ...; care orders and places it itself)', `data.far`.

## Tests
`tests/lua/test_care_ghosts.lua` (two far bodies: counts and the honest reply; one with a placed slab leaves `corpses_old`), `tests/test_bug895_leiter_far.py` (the ladder: far only / a mix / no counter), `tests/lua/test_care_m1.lua` runs against the extended state schema.

## Live-Erwartung
i3 Orangering: `inspect state` care `corpses_far 2` (or `corpses_far_mem 2` once the slabs stand; `corpses_old` 0 then), the ladder shows 'Wohl 0: 2 Tote ausser Reichweite (corpse_far ...)' with `inspect what=tombs` (no `tombs.repair`), `tombs.repair` answers '2 corpses out of reach (... unit 26637 at 88,83,145 ...)'. NOT promised: that the slabs are made when no hard stone or no historical figure exists (the figure's `nohf` state stays named), nor that the wall top is reached.
