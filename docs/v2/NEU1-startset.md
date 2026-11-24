# NEU1-startset: survival start set (phase 0) and hard site policy (decisions E3, E4)

Package P6 of the Neuausrichtung (`leitung/PLAN-NEUAUSRICHTUNG.md`). Success measure of the plan: **0 deaths of thirst or
hunger in years 1-3**. Offline, live-untested.

## 1. Old decisions

- **Everything hangs on the fort core.** The first year's still, kitchen, farm, office and stockpiles came with fortcore stage 1
  (dug into Z4) or with the year plan's later phases. Fallbacks existed one by one (BUG-356 startup shops, BUG-396 surface office,
  BUG-406/408 drink farm, BUG-297 surface farm, BUG-424 cistern), but each had its own trigger: some only through `plan propose`
  (when no Z4 exists yet), some only in PEACE, some only with `plan.surface_core` on (BUG-413: the surface office and the surface
  farm are refused while Gordon's 04.11. rule "no surface fort" stood). A fort whose core dig stalled had no guaranteed still or
  office: Manorsubtle (Run 16a i1, y372-y374) died of thirst on a good site, Bachwald and Mansionlauded before it; Bachwald's
  manager validated nothing for 294 days because no office stood (BUG-396).
- **Site choice is a negotiation.** Every failed embark criterion except `stone`/`timber` could be passed with
  `embark.py --accept ID --reason TEXT`; 65 of 90 world tiles were accepted near goblins, `water`, `aquifer` and `trees` were
  accepted on sites that later starved or drowned the core. Each new world cost hours of scanning.

## 2. New behaviour

### 2a. Phase 0: the survival start set (`lua/dfllm/startset.lua`, kernel module `startset`)

One rule, checked once a game day by a new small kernel module, independent of the core and of the LLM's plan:

> While the start set is not handed over, every part that is neither standing nor under construction is requested; the request
> places it on the surface beside the wagon (or in the core when one exists). The set is handed over to the core once the core
> exists (manifest `zones.Z4`) **and** every part stands; after that the module never requests again.

Parts (config `startset.parts`, all on by default):

| Part | Delivered when (read-only, built only; planned = under construction) | Request (PROJECT_REQUEST why=`startset`) | follow places |
|---|---|---|---|
| `shops` | every type of `startset.shops` (default Still, Carpenters) stands as a workshop | `workshops`, `types` = the missing types | `workshops` p.surface=1 with only those types (core room first when a Z4 exists, BUG-394 tries) |
| `farm` | a farm plot stands | `farms`, n=1 | `farms` p.plots=1 p.surface=1 without a core; with a core the room first, the surface plot as fallback (also with `plan.surface_core` off) |
| `pile` | a stockpile that takes food (settings flag `food`, or a `dfllm-*` food pile by name) stands | `foodpile` | new surface template `foodpile`: a 5x3 food stockpile `dfllm-start` (drink included) on open surface floor |
| `office` | an Office zone holds a BUILT chair AND a BUILT table (zone alone or planned furniture = under construction, not delivered) | `office` | `office` p.surface=1 without a core (the BUG-413 gate is lifted for the start set), the dug one with a core |
| `water` | `water.drink_access`: an accepted source or a bank the citizens reach | `cistern` why=`no_water` with `at` = the nearest water (the existing BUG-424 route: piped cistern, safe plans only) | unchanged (never free digging within 3 tiles of water) |

- **Fail closed.** A read that fails counts every part as missing (nothing is handed over). Unknown water (no scan yet, or the
  water module answers nothing) is missing but not requested (no tile to pipe from); it shows as `water?`.
- **Bounded requests.** A missing part is requested at most `startset.max_tries` (3) times, `startset.retry_days` (7) apart; while
  it is under construction it is not requested again.
- **Total escalation (no silent hold).** For every part the module keeps since when it is not ok (persist `m.startset.r[part].s`,
  the first day seen not ok, whatever the reason; cleared when the part stands). A part not ok for `startset.giveup_days` (default
  `max_tries * retry_days` = 21) days raises DECISION_NEEDED `startset` (A) once (latch `r.g`, cleared only when the part stands
  again) with `q`, `cmds` (`bp sites <tpl> surface=1 --fresh`, `inspect what=water_sources`) and `why` naming the cause per part:
  `missing after requests`, `planned but not built (materials?)` (e.g. an office whose chair/table wait for buildingplan items, a
  Still with no wood), `water: no tile to pipe from / not scanned`. A failing read for that long escalates every part. The state
  `ss.f` lists the escalated parts.
- **Auto-waiver.** `startset` is not plan-driven, so PLAN_EXHAUSTED never fires for it. Once the set escalated
  (`startset.escalated()`) and fortcore stage 1 exists (runner `proj_reached`), runner's `Q.auto_waive` waives the P0 deliverable
  with a logged reason (`by kernel`) and P0 goes on (mood reserve, leather, the follow starter). Without a core the
  DECISION_NEEDED is the signal and P0 holds until the player places the part or runs `phase.waive startset`.
- **Phase 0.** `plans/year1.json` P0 lists `{"k": "startset"}` first; runner's phase check asks `startset.done()` (true when the
  set is complete or handed over, or the switch is off; an absent module skips it as before). The status line shows what it waits
  for (`startset shops,office`).
- **Office with table and chair is the hard precondition.** The part `office` is delivered only with both built; until then the
  module keeps asking (economy's BUG-042 office check still places a missing chair/table in an existing zone). The manager's
  orders are not touched here (P8 owns the order path); the start set guarantees the office they need.
- **Hand-over without duplicates.** Before the hand-over a destroyed part is rebuilt (the set stays complete in year 1). After it
  the module is idle: the core's own still and kitchen (fortcore stage 1), the plan's office and farms and economy's existing rules
  take over; the surface pieces stay where they are (nothing is deconstructed) and no second surface set is ever requested. The
  workshops dedupe (`cmd._place`, live L6) already keeps the core's later `workshops` project from adding a second still.
- **State** `ss` (`{d: 0|1 handed over, m: [missing parts], f: [given-up parts]}`) for status/brief; persist `m.startset`.

### 2b. Hard site policy (`tools/embark`)

- `rules.json` `strict: true` (default) with `accept_only: ["dark_fortress"]`: a FAILED criterion can be accepted only when it is in
  that list (goblin distance; in a goblin-dense world most tiles are near goblins). Everything else that fails is a hard reject:
  heavy/varied aquifer and a light one with no core below it within reach (`aquifer`), no trees (`trees`), no water source
  (`water`, incl. BUG-649 aquifer-only and BUG-426 bare-mountain gully), no hard stone (`stone`, `timber`), and also ore, evil,
  savagery, temperature, terrain, size, old sites. `--accept` refuses them in `embark.py` (argparse error) and in the in-game gate
  (`steps.gate`), and `best compromise` only offers dark_fortress acceptances.
- `strict` also refuses `--waive` of the site-killers when the panel did not show them (`hard_waive`: aquifer, trees, water,
  stone): missing data fails closed; scan the rectangle with `--tiles`/`--hover` instead. `--explore-first` is no longer a way
  around an unknown stone.
- **Vetted sites** (`tools/embark/sites.json`): a fixed list per world. `embark.py sites` lists them with their embark command;
  `embark.py sites add ID WX,WY,LX,LY [--note]` adds a rectangle only when the newest scan results hold it with verdict `ok` (or
  `review` whose unknowns are all waivable) under the strict rules; `embark.py embark --site ID` embarks there (the live gate still
  runs on the fresh read). Site choice in a vetted world = one `embark --site` call (minutes, no scan).

## 3. Config switches (all new, default ON)

| Switch | Default | Effect when off |
|---|---|---|
| `config/baseline.json` `startset.on` | true | module idle, P0 deliverable `startset` passes, follow ignores why=startset |
| `startset.parts` | `["shops","farm","pile","office","water"]` | a part left out is neither checked nor requested |
| `startset.shops` | `["Still","Carpenters"]` | the workshop types of part `shops` |
| `startset.retry_days` / `max_tries` | 7 / 3 | request cadence and bound |
| `startset.giveup_days` | 21 | days any part may stay not ok before the one-time DECISION_NEEDED `startset` (1..360) |
| `tools/embark/rules.json` `strict` | true | the old FR-08 acceptances and waivers |
| `rules.json` `accept_only` | `["dark_fortress"]` | ids that may still be accepted under `strict` |
| `rules.json` `hard_waive` | `["aquifer","trees","water","stone"]` | ids that may not be waived under `strict` |

`python -m dfpilot.lint --config` checks the `startset` section.

## 4. Deliberately not done

- No new combined "survival compound" template: the parts reuse the existing surface templates (startup shops, surface office,
  surface farm, cistern) plus one tiny new one (`foodpile`), so each keeps its live-tested site ranking.
- No well dug by the start set: water access goes through the existing cistern request (safe pipe from the nearest water, never
  free digging near water) and through the hard embark rule that a site must have a brook in the rectangle.
- No deconstruction of the surface set at hand-over and no change to where the core puts its own still (fortcore stage 1).
- No change to manager order handling (P8), the population cap (P4), gates (P5) or the drink-in-the-core rule (P4).
- The surface set is outside the walls: in a siege it is lost like any surface building. It is meant for year 1; the core's
  stage 1 brings the inner still.
- No siege or mode gate in the module itself: runner already freezes infra projects in SIEGE, and the placements are prio 1
  surface builds.
- The hand-over does not move the set inside: it only stops asking once the core exists and every part stands (also when those are
  the surface pieces). A later loss of the surface still or office is economy's (BUG-396/527) and the P0/P1 workshops' business.
- In a running mid-game fort the set also runs until hand-over; with a core and a missing part it places the core's office or
  workshops up to `max_tries` times, which can overlap economy's BUG-042/BUG-396 office repair (the dedupe of `cmd._place` keeps
  it from doubling buildings).
- No automatic world search: the vetted list is filled by hand after one `rank`/`scan` pass on the fresh world (Leitung step 3).

## 5. Live-Erwartung

1. In a fresh fort `state.ss.m` lists missing parts within the first game day and `events.jsonl` shows `PROJECT_REQUEST` with
   `why":"startset"` for `workshops` (types Still/Carpenters), `farms`, `foodpile`, `office`; `cli.log` shows `auto:startset_*`
   placements within minutes, without any `plan apply`.
2. Within the first season (before fortcore stage 1 is dug) a Still, a farm plot, a `dfllm-start` food pile and an Office zone with a
   built chair and table stand on the surface; the `status` phase line no longer shows `startset ...` and `ss.m` is empty; the first
   `BrewDrink` job runs before the core is finished; no thirst or starvation `DEATH` in years 1-3.
3. No silent P0 hold: whenever `status` shows `startset <part>` for more than ~21 game days, `events.jsonl` holds exactly one
   `DECISION_NEEDED` with `"id":"startset"` and a `why` naming that part's cause (`planned but not built (materials?)`,
   `water: no tile to pipe from / not scanned`, `missing after requests`), and `ss.f` names the part.
4. If fortcore stage 1 exists when that happens, the phase line shows the waiver `startset: start set escalated, fortcore stage 1
   stands ...` (`kernel.log` `phase P0: startset cannot be made ... by kernel`) and the phase moves to P1 within a game day.
5. After the hand-over (core Z4 and every part standing) `state.ss.d` = 1 and no further `why":"startset"` request appears for that
   fort. `embark.py embark X,Y --accept water --reason ...` (or trees/aquifer/stone/ore) is refused before any DF call; with a
   filled `sites.json` an embark takes one `embark --site ID` call (< 10 minutes).
