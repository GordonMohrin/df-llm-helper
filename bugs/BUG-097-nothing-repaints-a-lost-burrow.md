# BUG-097 Nothing repaints a burrow that lost its tiles, and the tile set it should have is not kept anywhere
Status: fixed in the K1 commit (offline, live-untested): the kernel keeps the last good reading of Kern+ and the refuge (tiles as
runs, persist key `burrows`) and, in PEACE/RECOVERY, paints the tiles a burrow lacks again with `act.burrow_tiles`, at most
`burrow.guard.repair_per_day` (2000) a game day, hospital, wells and refuge first, never a hidden tile; a burrow that is gone is
made again under its name when its tile set is known, else DECISION_NEEDED `burrow_gone`
Severity: high (a fort with a burrow of one tile has no refuge and no alert burrow; the SIEGE_UNREADY wake for `hospital_out` named
a hospital that was fine)
Found: 2026-10-23, Run 14 Trussroads y586 (note 70), kernel of b2b9435
Module: `lua/dfllm/seal.lua` (`BG.apply`, `BG.paint`), `lua/dfllm/burrowkeep.lua`

## Actual
After the loss of note 70 the fort stayed as it was until the game session repainted the 35 hospital tiles by hand. Tiefe+ was not
made again at all; the rest of Kern+ (about one tile left of thousands) was not painted.

## Cause (base b2b9435, proved from the code)
- Nothing repaints. The only burrow writers are quickfort's burrow stages (`dfpilot/bp/fortcore.py:158`, `dfpilot/bp/rooms.py:87`:
  one project's rectangle, once) and seal's `job_paint` / `lever_burrow` (`lua/dfllm/seal.lua:2895`, `:3467`: the interior burrow
  Innen+, the dead end as the refuge when it is missing, Hebel+). Neither knows what Kern+ or the refuge SHOULD hold.
- The intended tile set is not persisted. A finished project deletes its document (`lua/dfllm/runner.lua:1850`,
  `K.persist.set('bp.<id>', nil)`) after merging its manifest fragment (`lua/dfllm/runner.lua:420`); the fragment holds the burrow's
  NAME and role (`dfpilot/bp/fortcore.py:229`), the rooms' boxes, never the burrow rectangles, and nothing records what the burrow
  plugin grew over every tile dug beside a `+` burrow (thousands of tiles in a fort of 80). The manifest's room boxes are not the
  burrow (a room's burrow is its box plus a door tile, the rest of Kern+ is the corridors the plugin added).
- A project that runs after the loss makes it worse to read: `create=true` makes the burrow again with its own rectangle, and
  readiness sees a Kern+ (`lua/dfllm/readiness.lua:359`).

## Fix
- The last good reading is the intended set: per managed burrow (the manifest roles kern and refuge) `base` tiles, `nb` blocks, `id`
  and the tiles as runs (`k`, flat `z, y, x0, x1`), in the persist key `burrows` (owner seal; `persist.burrows`), rewritten only
  when a reading differs, at most once a game day. Size: about 14 bytes a run; a room row is one run, a corridor three; the
  fixture of `test_the_record_of_a_big_fort_fits_the_persist_budget` (300 rooms, 400 corridors, 8,000 tiles, 2,700 runs) is 40 KB;
  the cap is `RUNS_MAX` 8,000 runs a burrow (about 110 KB; more runs: the first 8,000 and `kp` 1, the repair is partial). The
  persist layer writes a key of 8 KB or more at most every 60 s and logs from 64 KB. The state document (4 KB shed) carries only
  `alert.bg` (about 80 bytes, present while an episode is open).
- An episode keeps the baseline (a loss is never taken as the new normal at once). Each daily pass, when the mode is PEACE or
  RECOVERY and no lockdown holds: the baseline tiles the burrow lacks (`BK.missing`: the runs near the hospital zones outside the
  burrow, the accepted water sources and the refuge anchor first, within `NEAR` 8 tiles on the same level; then the rest) are
  checked for being revealed (a hidden tile is left out and said in kern.log) and painted with `act.burrow_tiles` in chunks of 400
  a frame, at most `burrow.guard.repair_per_day` (2000) a game day: BURROW_REPAIRED (B) per pass, kern.log per pass. A burrow
  that is gone is created by the first chunk (`create`, a new id) when its runs are known.
- Never a burrow the kernel does not manage (names come from the manifest roles; Innen+, Hebel+ and a player's burrows are not
  read). Never in ALERT, SIEGE, BREACH, DRILL or a lockdown (a tile added in a fight may lie outside the walls; the record
  waits: `fix wait`, the settle clock stands still); seal's own fallback (Innen+ painted whole) covers the fight. A burrow list
  that is EMPTY (a reclaimed or retired fort) is not repainted from an old record: DECISION_NEEDED `burrow_gone`. A record
  of another adoption (`dfllm adopt` again) is dropped at boot.
- The episode ends when nothing is left to paint (`repaired`; with hidden tiles left out `partial`: the reading is the new
  baseline), when the burrow is above the line again and no repair is possible (`regrown`), or `burrow.guard.settle_days` (14)
  after the last progress (`settled`: the loss is the new baseline; a burrow that stays gone leaves the record). `repair_per_day`
  0 makes the guard a sensor; `on` false switches it off.
- Safe at every size: one reading and one paint pass a game day and `burrow.guard.every_s` (120) real seconds apart, the work sliced by
  seal's bucket (a fort of 80: 600 blocks of Kern+ are about 150,000 work units, 800 a frame, 6,000 a second); a fort of 7 reads one block; an old kernel state (no record) starts from the
  reading without an event.

## Not decided offline
- Whether DF takes `setAssignedTile` on a block of a tile that is not loaded or revealed in the way the screen's brush does (the game
  session's own repaint worked); whether painting 2,000 tiles (5 chunks of 400, one a frame) shows as a hitch at timestream speed.
- Whether a burrow made again by `create` keeps what the civ alert holds: the alert list holds burrow ids; siege writes it by NAME
  on the next alarm (`act.alert_burrows`), so a stale id is replaced then; between the loss and the next alarm the PEACE alert
  is not sounding.
- What the lever room units (`burrow_units`) of a gone lever room need: not repaired here (Hebel+ and the `dfllm-levers*`
  rooms are painted by seal and gate).
- Live read: the next BURROW_SHRUNK / BURROW_REPAIRED events, `dfllm status` (`burrows:`), `inspect persist` (`burrows` size),
  `dfllm doctor` (cost of seal).

## Tests
`tests/lua/test_burrow_guard.lua`: the repair of a shrink and a vanish (a new id, create), the daily cap (40 a day: 40, 40, 32), the
sensor only (`repair_per_day` 0), a burrow the kernel does not manage, a hidden tile, SIEGE/BREACH/ALERT (no paint, then paint),
a long fight (the settle clock stands), a fort of 7, the order (the corridor of the hospital first), a reclaimed fort (empty list: asks),
an old or foreign record; `tests/lua/test_burrowkeep.lua` (the rules); `tests/test_k1_burrows.py`
(`test_the_record_of_a_big_fort_fits_the_persist_budget`: the numbers above). All fail on b2b9435.

Related: BUG-096, FR-80, BUG-036; note 70
