# NEU1 P8: job query "why is this job not running" (Neuausrichtung 1)

Status: offline, live-untested. Branch `neu1-jobfrage`. Plan: `leitung/PLAN-NEUAUSRICHTUNG.md` P8
("Ursache von Brau- und Fischstau benannt").

## Old decision

Every stall had its own diagnosis, written from a guess about DF and tested against a fake that shared the guess:

- brew stall (BUG-758ff, BUG-767, BUG-779): `economy.brew_cause` names profile / labor / barrels from the census, but
  the two most frequent live outcomes were guesses: `untaken` ("DF did not assign it (path or burrow?)") and `nojob`
  ("DF counts items its own way"). The cure for both was the same: take the orders down and make them again
  without conditions. It never proved the cause.
- fish stall (BUG-716): when a Fish cleaning holder existed the text was "the fishery is slower than the catch".
- stale orders (BUG-060): "no job for N days (reason)" with the reason from the census, not from the job.

## New behaviour

One read-only library `lua/dfllm/jobwhy.lua` (like `orderlib`, not a module) reads the blocking cause off the
game state, for a workshop, a manager order, a job, or a kind (`brew`, `fish`, `cook`, any job type name):

1. **Job** (in a workshop): worker -> `working`; `suspended`; the labor the job needs (job type attrs, the
   reaction's skill, the material's skill; `orderlib` as fallback). Every adult citizen holding that labor gets
   one status, first that applies: `mood`, `soldier`, `profile` (permitted-worker list, skill window, blocked
   labor of the workshop profile), `burrow` (his own burrows or the civ alert's do not hold the workshop; a
   `limit_workshops` burrow holds it and he is not a member), `far` (no walk group of the workshop's tiles and ring),
   `busy` (with the job's name), `unavailable` (`dfhack.units.isJobAvailable` false), else `free`.
   No holder -> `no_labor`; no free holder -> the structural status most holders share (`profile`, `burrow`,
   `far`, `soldier`, `mood`) when it holds at least half of them, else `busy` if any holder is only busy (busy
   holders come free, kept-out ones never do; the text lists every status either way). Then each job item the job still lacks (DF 53: `job.job_items.elements`, the `job_item_vector` struct's list;
   an old build's bare vector as fallback, like `act.lua`; no readable list -> inputs unknown, never "none missing")
   is matched against DF's item vector (type, subtype, material, `isSuitableItem` / `isSuitableMaterial`,
   unrotten, empty, reaction product / class): none -> `no_input` (`no_container` for an empty-container
   item), none free -> the largest share of `input_forbidden`, `input_claimed`, `input_far`; free ones, but every
   free holder is held to burrows (his own or the civ alert's) and none of them lies inside -> `input_burrow`.
   All checks pass -> `unknown`; its text says only what was read: "the inputs lie free" only when every missing
   job item was read and scanned in full, else "its inputs not read" / "its inputs not fully read" (BUG-817).
   Walk groups come from `snapshot.groups` (the map reads stay in snapshot; lint rule tile-read).
2. **Order**: `done`; not validated -> `no_manager` (no post / nobody appointed) or `not_validated` (the first
   cause of `economy.manager_facts`); a job of the order exists -> the job's cause (worked -> `working`); no job ->
   `pinned` (workshop_id gone), `no_workshop`, `profile_orders` (every fitting workshop has max_general_orders 0),
   `shop_full` (every fitting workshop holds 10 jobs), `conditions` (item conditions DF checks itself), else
   `unknown`.
3. **Workshop**: its first unworked job, else the first open order of its type, else `no_order`.

Fail closed: a check whose data is missing (no API, an error, unknown labor, walk group 0) never yields a cause;
the result is then `unknown` with what was seen. Nothing is written, nothing is cured.

Uses:

- `dfllm cmd inspect what=why key=<k>` (economy `M.inspect.why`) and the CLI `python -m dfpilot why <k>`, where
  `<k>` is `ws:<id>`, `order:<id>`, `job:<id>`, a bare id (order, then building, then job) or a kind
  (`brew`, `fish`, `cook`, a job type name such as `ConstructBed`).
- `brew_watch`: the told stall carries `cause` (ORDER_STUCK, new optional field); when `brew_cause` only guessed
  (`untaken`, `nojob`, `suspended`) the text is the query's. The query runs BEFORE the cures (profile open, labor,
  order take-down; BUG-818): asked after the `nojob` cure it found the orders gone and said `none_open`. The cures
  are unchanged.
- `fish_watch`: the told stall carries `cause`; the guess "slower than the catch" is replaced by the query's text.
  The query runs before the labor cure, so the cause describes the state that stalled, not the post-cure one.
- `T.stale` (stale orders): the event carries `cause`, kern.log the query's line.

## Config switches

`config/baseline.json` `economy.jobwhy`: `stall` (true: brew / fish / stale stalls ask the query; false: the old
texts, no `cause`), `items_max` (4000: item records looked at per missing job item). The inspect verb and the CLI
always answer.

## Deliberately not done

- No new automatic cure. The brew relax cure still runs on `untaken` / `nojob` / `suspended`; whether it should
  wait for a proven cause is a decision for after live evidence.
- Manager item conditions are counted, not evaluated (DF's own matcher is not exposed to Lua).
- DF's job cooldown (`setJobCooldown`) and the pathing cost limit are not readable; they end in `unknown`.
- Items: only the job's own missing items; hauling of already fetched items and stockpile links (take-from)
  are not checked. A job item over `items_max` records with no free one found names no cause (clipped).
- Soldiers are reported as `soldier` (not split into on duty / off duty).

## Fake check against real DF structures

Checked against DFHack 53.x in `E:/DF-test4/hack` (read-only): strings in `dfhack.dll`, `docs/docs/dev/Lua API.txt`
and the DFHack scripts under `hack/scripts` (no df-structures XML there): `workshop_profile` has `permitted_workers
min_level max_level max_general_orders blocked_labors`; `job_type` attrs have `labor skill skill_stone skill_wood
skill_metal`; `burrow_flag` has `limit_workshops`; `manager_order_status` has `validated`;
`dfhack.job.isSuitableItem/isSuitableMaterial`, `dfhack.units.isJobAvailable`, `dfhack.maps.getWalkableGroup` exist.
Mismatches found:

- **`job.job_items` (BUG-817, found by the verifier, missed in the first pass):** in DF 50+/53 it is a
  `job_item_vector` struct and the list is `.elements` (`dfhack.dll` string `job_item_vector`; the scripts read
  `job.job_items.elements`; this repo's `act.lua`, `care.lua`, `economy.lua` too). The first jobwhy read it as a flat
  vector and its test fakes were flat vectors as well, so every input test passed against a shape the game does not
  have; live, the input diagnosis would never have fired and `unknown` would have claimed "the inputs lie free".
  Now `J.job_items` reads `.elements` first; the fakes use `{elements = kmock.vec{...}}`; a test shows an absent,
  erroring or list-less `job_items` keeps the cause `unknown` with "its inputs not read". Lesson: a field name found
  in the dll proves the name, not the shape; compare a fake with a real reader in hack/scripts.
- `k_mock` `dfhack.burrows.isAssignedUnit(b, u)` answers "unit stands in the burrow's box"; the real function
  answers membership (the unit is assigned). jobwhy reads `unit.burrows` instead.
- `wp8_world` `df.job_skill` lacks BREWING and PROCESSFISH (the brew tests read skill 0 for every brewer, so
  the BUG-767 skill-window check never ran against a real skill id).
- `wp8_world` items have no `getSubtype`, `getMaterial`, `getMaterialIndex`; workshops have no `centerx/centery`
  and no `profile` by default; jobs have no `job_items`/`items`. The new tests give them explicitly (in the DF 53
  shape).

## Live-Erwartung

1. The next brew stall's ORDER_STUCK (`brewing stalled`) carries `cause` other than `unknown` in at least
   2 of 3 cases, and kern.log has a `jobwhy brew:` line naming holders by status (e.g. `2 Brewers: 1 busy (Drink),
   1 burrow`).
2. `python -m dfpilot why brew` and `why fish` answer within one kernel tick with a cause and holder/input
   counts; for a Still with an untaken job the answer is never "path or burrow?".
3. A fish stall with a holder reads `fish stall: <cause>` instead of "the fishery is slower than the catch".
4. When the player checks a named cause by hand (labors screen, burrow screen, workshop profile), it matches
   in the first three checked cases; a mismatch is a bug of the query, not of the fort.
5. A brew stall told with the old guess `nojob` ("DF counts items its own way") carries an order-level `cause`
   (`not_validated`, `no_manager`, `profile_orders`, `conditions`, ...) in its ORDER_STUCK, never `none_open`; and
   no `jobwhy` line in kern.log says "inputs lie free" for a job whose `job_items` could not be read.
