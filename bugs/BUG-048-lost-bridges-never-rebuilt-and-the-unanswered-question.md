# BUG-048 Lost bridges and gates stay lost for years: PEACE drops them, a bridge without a text queues nothing, the question nobody answers
Status: fixed in FIXHASH (offline, live-untested): a lost bridge enters the keeper's queue the moment gate reports it (PEACE without a lockdown) or at the diff after an episode, never retired in PEACE; a bridge no defense project recorded gets its quickfort text from gate's raise direction and the footprint; after `perimeter.stop_after` losses to building destroyers (and `perimeter.vanish_after` losses with no destroyer in sight, or a rebuild nobody built in 60 days) the bridge is replaced by a wall and a door through the runner, reported once (PERIMETER_BROKEN `replaced`), the other bridges kept; DECISION_NEEDED `bridge_rebuild` is not asked any more (DECISIONS 3); old held state converts
Severity: critical (Run 11: siege 13 and 14 cost 36 and 24 citizens with O1, B1, B2 and their levers lost for years; Run 13 fell in y525 over an open O1)
Found: 2026-10-23 from the game session's notes 13, 17, 20, 23, 26, 43 (`bugs/RUN11-offene-bugs-und-FR.md`) and causes 1 and 3 of `docs/v2/POSTMORTEM-run13-wheelsblows-y525.md`
Module: `lua/dfllm/seal.lua` (the perimeter keeper, bridge queue `m.seal.gq`), `lua/dfllm/gate.lua` (`seen.key`, `bridge_key`, state `replaced`), `lua/dfllm/siege.lua` (`geometry`), `lua/dfllm/readiness.lua` (`check_levers`), `lua/dfllm/snapshot.lua`, `dfpilot/bp/topo.py` (`audit`), `dfpilot/wake.py`, `dfpilot/brief.py`

## Actual
- Run 11 (Kilrudrabed): status `lost:O1,bridge:B1,levers:B1,bridge:B2,levers:B2` for years; PERIMETER_BROKEN `bridge 113,106,142 requeued=0` in PEACE for 35 days
  (note 20); O1 destroyed 14 times and the DECISION_NEEDED `bridge_rebuild` never answered (notes 13, 17); siege 13 (y487): `sealed 0 ticks`,
  36 lost; siege 14 (y497): 24 lost (notes 17, 23, 26).
- Run 13 (Wheelsblows): B2 (y507 sum d16) and O1 (y509 spr d5) reported BRIDGE_DESTROYED in PEACE with no destroyer in sight, both buildings `gone`;
  `bridge.rebuild` answered "no lost bridge waits"; audit FAIL from y507 to the end; the fort fell in y525 over the open O1 (note 43, post-mortem cause 1).

## Expected
A lost bridge or gate is rebuilt in quiet PEACE soon after it is lost, whatever took it. A gate that building destroyers keep breaking is
replaced by a constructed closure, not left open and not made a question. The state says what the keeper does and why.

## Cause (proved from the base commit f17e2b3; each has a test that fails there)
1. **The PEACE retire pass drops a bridge that vanished in PEACE.** `lua/dfllm/seal.lua:3922` schedules `due('perim', t, 'retire')` every `seal_every`
   (7 days) in PEACE; `job_perim` (`:1575`) then treats every gone piece as a thing the player removed: `:1588`
   `if st.gq[k] then kept = kept + 1 else st.perim[k] = nil end`. gate reports BRIDGE_DESTROYED within a day, but nothing puts the bridge into the queue
   (`st.gq` is filled only by the post-episode diff, `:1606`), so the next retire pass forgets the piece. `bridge.rebuild` then says "no lost bridge waits".
   Test: `tests/lua/test_perimeter_keeper.lua` "a bridge that vanishes in PEACE ..." (note 43, Run 13).
2. **A manifest bridge no defense project recorded has no quickfort text, and the diff queues nothing for it.** `perim_manifest` (`:1371`) adds
   the manifest bridges as `{k = 'bridge', fp, name, src = 'manifest'}` without `q`; only `check_pending` (a `class = defense` project's closing cells) fills
   `q`. The diff condition `:1606` `p.k == 'bridge' and p.q and ...` is false, the piece takes the `cells` branch (`:1611` `local q = p.q or QF_OF[p.k]`;
   `QF_OF` has no bridge) and gets nothing, `st.req[k] = t` makes it wait the 7-day cool for pieces that never queue: PERIMETER_BROKEN `requeued=0`,
   no `wait`, no `held`, for ever. A reclaimed fort (Run 13) or a fort whose bridges fell before the keeper existed (Run 11 B1/B2: `bridge:B1`, gate had never
   seen them whole, so no BRIDGE_DESTROYED either) is exactly that. Test: "a manifest bridge the keeper never saw built ... requeued 0, wait {O1}".
3. **The stop rule asks a question nobody answers and holds the bridge open meanwhile.** `ask` (`:1490`) emitted DECISION_NEEDED `bridge_rebuild`; the
   default ("leave") kept O1 lost and R0 `lost:O1` for years (Run 11). The Run 13 lesson: replace destroyed gates at once or close them with wall + door; an
   audit FAIL is a stop signal.
4. **A rebuild nobody builds is given up for good.** `:1536` `if t - (g.qt or t) > CFG.gq_keep then ... given up`: the entry left the queue after 60 days
   (cancelled or starved repair project) and the retire pass of cause 1 then dropped the piece.

## Fix (FIXHASH)
- **Intake.** `KP.add` (the keeper's helpers live in one table: seal.lua is near Lua's limit of 200 locals) enters a lost bridge into `m.seal.gq`; called from
  `M.on['EV:BRIDGE_DESTROYED']` (PEACE, no episode, no lockdown: at once, `due('gates')` runs the pass), from the `pre`/`retire` passes (a bridge piece with a
  manifest name or a recorded text is kept instead of retired) and from the post-episode diff. A bridge the player built and the keeper never saw (no name, no
  text) is retired as before; a replaced bridge is never entered again.
- **Text.** `KP.text`: the recorded text, else `<key>(WxH)` from the footprint with gate's key (`gate.bridge_key`: the raise direction read from the
  complete building, `ga/gd/gw/gx/gs`, persisted in `seen.key`) or `gw` (fortcore's). The repair, the log and `inspect defense` say `no destroyer in sight`
  when the newest loss had none.
- **Closure.** `KP.verdict`: `replace` when the losses to building destroyers since the player's last order reach `stop_after` (2), the losses with no
  destroyer reach `vanish_after` (3, new config key; the loop breaker), the rebuild was not built in 60 days (it used to be given up), or the closure is
  already queued. `KP.cells`: the footprint's first row across the way (its shorter side; a square counts as x), walls `Cw` on every tile but the middle one
  of the long side, which gets the door `d`: a 3x1 bridge gives wall, door, wall; 1x1 a door. `KP.close` queues it with `runner.repair(cells, why,
  {peace = true})` (frozen outside quiet PEACE like the rebuild). Reported once: PERIMETER_BROKEN `replaced`, `why = 'replaced'`, text `bridge O1 lost 2x to
  building destroyers (DRAGON; y437,y438): replaced by wall + door at x,y,z (rp..., built in quiet PEACE); no question: the other bridges stay`. DECISION_NEEDED
  `bridge_rebuild` is never emitted. A closure nobody builds in 60 days is queued again.
- **After it stands** (`KP.done`): `seal.replaced()` lists the bridge. gate publishes state `replaced` (new enum value) instead of `destroyed`; siege's
  `geometry` leaves it out of its gates (no BREACH "O1 destroyed: an open way", no raise, no hold); readiness drops its `bridge:`/`levers:` blockers (the role
  counts as missing: `no_outer`/`no_inner`, the doctrine still wants a gate); the snapshot says `replaced` and `bp.topo.audit` takes the footprint for a door entrance
  (no `footprint is not a bridge`, no lever finding); a bridge standing on the footprint again clears the entry; a footprint the player walled is the same state.
- **Old state.** A gq entry an older kernel wrote (`held`, `asked`, no project) is judged afresh at the next quiet PEACE: it becomes the closure.
- **The verb.** `bridge.rebuild` is the player's order now: stores the counts (`ans`, new `ansv`) so the rule counts again from them, queues a waiting
  bridge, refused for a replaced bridge (take the door and walls down first) and while the closure project is queued (`bp.cancel` it).
- Note 43 (bridges vanish in peace with no destroyer in sight): the keeper treats such a loss as rebuildable and says `no destroyer in sight` in the
  repair's reason, kern.log and `inspect defense` (`how = none`); package B3 reports the culprit.

## Not decided offline (and what decides it)
- **Does the closure's geometry close the way in the real fort?** The first row across the way is derived from the footprint's shorter side; a square footprint
  (2x2) closes only its first column. Live: after the first replacement, `dfllm cmd inspect '{"what":"entrances"}'` and `dfllm audit`: no new open way and no
  `bypass` at the footprint; the pieces `Cw`/`d` stand at the footprint's tiles (`inspect perimeter` lists them).
- **A footprint over open space.** Fortcore's bridges stand on tunnel floor, so a wall and a door can be built there after a loss. A bridge built over a chasm or a channel
  leaves open space when destroyed and a wall cannot be built on it: the closure project would not finish and is queued again every 60 days (kern.log
  `seal: lost bridge O1 at ...: rp1 did not build its wall + door in 60 days`). Live: the tile shape under the lost footprint (`dfllm cmd inspect '{"what":"entrances"}'`, the audit snapshot).
- **The raise-direction key.** `building_bridgest.direction` (Left/Right/Up/Down/Retracting) is read best effort; if DF 53.16 names the field otherwise `gate.bridge_key`
  is nil and the text is `gw(WxH)` (what fortcore builds). Live: `dfllm cmd inspect '{"what":"persist","key":"m.gate","field":"seen"}'` shows `key` per bridge.
- **Is the vanishing in PEACE (Run 13) a citizen's deconstruct job, a mood or something else?** Not the keeper's question; package B3 logs the culprit. The keeper
  stops a loop at `vanish_after` (3) losses.

## Tests (each new one fails on f17e2b3)
`tests/lua/test_perimeter_keeper.lua` (new: PEACE loss rebuilt at once with "no destroyer", wait for quiet PEACE, no text -> text from the footprint, the closure for
3x1 and 1x1, once, no question, reload, `replaced` state, verb refusal, stop_after 0/3, the vanish loop breaker, old held state converts, the 60-day rebuild becomes
the closure), `tests/lua/test_stranded.lua` (a replaced O1 is no open way in a siege), `tests/lua/test_bridge_rebuild.lua` (the Run 11 replay now ends in a door,
never a question; adjusted with reasons), `tests/bp/test_bp_topo.py` (a replaced footprint is a door entrance), `tests/test_perimeter_escalation.py`,
`tests/test_bridge_rebuild.py` (config, hints).

Related: BUG-030 (rebuild policy), BUG-035 (recall), FR-70 (open perimeter is a stop signal), BUG-049 (the refuge), DECISIONS 3.
