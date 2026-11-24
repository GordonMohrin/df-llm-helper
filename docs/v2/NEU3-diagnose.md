# NEU3 diagnostics: forts die of thirst with thousands of brewable plants (BUG-839, BUG-840)

Status: offline, live-untested. Branch `neu3-fass`. **NEU4 (docs/v2/NEU4-ursache.md) supersedes the switch table: `cx_cure` is now ON, gated by DF's own cancel reason; the stall line leads with it.** Decision of the lead: stop guessing, diagnostics first, so that one live look names the cause.

## Situation

Run 17 i1 Diedplank y380 and i2 Whirledrampart y485: thousands of brewable plants, drink 0, and 'brews ordered, none ran'. The brew order is validated, has no
item condition (after the kernel's own cure), a Still has room, brewers exist, and DF still creates no job or a job nobody takes (MakeBarrel job 1430329 on i2
unworked for 54 days; i1 'Needs logs' beside 183 free logs; the `why` input scan '0 match' against a census of thousands; build jobs untaken beside idle citizens).
Round 51 (BUG-779) and BUG-834..838 acted on a guessed cause (no empty containers); two verifiers rejected it. Nothing in any log shows DF's own reason.

## What this release does

1. The acting cures are config switches in `economy.diag`, all **off** by default (`config/baseline.json`, `economy.DEFAULTS.diag`, `lint --config`):

| Switch | Default | Cure behind it |
|---|---|---|
| `cx_cure` | false | container reserve = a quarter of the brews open and the phantom verdict (off: constant reserve 3 as BUG-779), the plant stockpiles' `max_barrels` freeze (`act.pile_barrels`; a freeze left behind is given back), the Carpentry / Stone crafting labor holds (`cx_labor`), direct MakeBarrel tasks on the Carpenter sheet (`cx_direct`) |
| `mgr_chores` | false | Herbalism, Spinning, plant processing, giving water off for the manager (off: Farming only, as BUG-547) |
| `still_pin` | false | the `pinned to one Still` verdict (BUG-838) and its re-make of the brew orders |
| `stall_line` | **true** | the weekly `raw stall` line (reporting) |

Reporting stays on: the `by my count` text of the container verdict, jobwhy labor names / conditions / `scan_unreliable`, the chore named in `why`.
The act verbs stay in the contract (`pile_barrels`, `labor_set carpenter ...`, `ws_task MakeBarrel`), nothing calls them without a switch; the player's own `labor.set` works.

2. Read-only raw dumps (`inspect what=raw key=<k>`, CLI `python -m dfpilot why <k> --raw`). Lua: `lua/dfllm/dfraw.lua`, a library like `jobwhy`.
   Output: `{kind, key, lines[], n, clipped}`, at most 140 lines of 290 characters.

| Key | Prints |
|---|---|
| `order:<id>` | job_type, reaction, amount_left/total, `status` flags by name (validated, active), frequency, `workshop_id` (the pinned shop), material fields, every field of the order once generically, each item condition (compare, value, item_type, subtype, material, flags1-3, reaction class / product) and its generic dump; then every workshop that could take it (plus the pinned one) with id, position, build stage, building flags, `forbidden` flag, deconstruction job, walk groups of its ring, limiting burrows, profile (max_general_orders, min/max level, permitted_workers, blocked_labors), the job list (id, type, flags, order id, worker or none, completion), stockpile links give/take; and the labor holders (below) |
| `brew` | the same for every brew order (up to 8) and every Still |
| `job:<id>` | job_type, flags, order_id, worker, holder building, the labor and skill DF derives (`df.job_type.attrs` labor / skill / skill_stone / skill_wood / skill_metal, then `J.labors`), each job item (item_type, subtype, material, quantity, min_dimension, vector_id, reaction_class / product, flags1-5 names, filled), general_refs, attached items, the shop, the holders |
| `items:<logs\|plants\|barrels\|VECTOR>` | items of the vector counted by exclusion reason: forbid, dump, in_job, in_building, on_fire, rotten, owned, trader, melt, hostile, in a claimed container, outside the civil-alert burrow, other walk group, unwalkable tile, hidden tile; counted first-reason-only and as hit counts, the census value beside; a flag the game does not have is listed under `fields not readable on this DF`. `plants` counts brewable (DRINK_MAT) plants and growths, `barrels` the empty ones |
| `manager` | his unit, job, labors on, walk group, the office (zone, box, chair / table built, walk path from him, DF's room value, zone walk group), orders total / unvalidated / active, ManageWorkOrders jobs, DF's manager timer (`?` if no field of that name exists), the kernel's causes |
| `ws:<id>` | one workshop as above |

Holder rows (`holder <id> <name> job=.. burrows=.. in_own_burrow_with_shop=.. civ_alert=.. in_civ_burrow=.. walk_group=.. same_as_shop=.. squad=.. soldier=..
mood=.. flags=[..] child_or_baby=.. job_available=.. status=..`) list the citizens holding the labor, `status` = the first that applies of mood, soldier, profile,
burrow_own, burrow_civ, far, busy, unavailable, free. Not readable: DF's "on break" state (no known field), printed nowhere.

Field safety: no DF structure source is installed next to the game (only `symbols.xml`), so no field name is taken on trust. Every read is a pcall; an
unreadable field prints `?`, never `0`, and never raises. Each struct is also dumped generically with `pairs`, which prints the real field names. The first
live dump therefore also shows which of the names used here are wrong.

3. The stall line. `economy.stall_log(kind, key)` writes ONE `kern.log` line per stall and game week (`7 * DAY` ticks), from:
   - `brew_watch` (kind `brew`, before any cure changes the state): `raw stall brew: orders=N valid=V active=A left=L pinned=[ids] | stills=ID(stage s/m jobs= susp= work= maxgen= pinned= forbid=) | brewers=N [free= busy= burrow_own= burrow_civ= far= soldier= ...] | plants: seen= ok= first[reason=n ...] census[...] | barrels: ...`
   - the stale-order scan (kind `order`): flags, pinned shop, shop stage / jobs / max_general_orders, labor holders by status;
   - the 'no builder took it' build state (kind `build`): the site, builders by status, main walk group, civil-alert burrows.
   `economy.diag.stall_line` false switches it off.

4. `J.labors` for a bare MakeBarrel-like job (no shop key, no material class) falls back to wood, then rock: CARPENTER instead of 'labor not known'.

## Hypotheses and the dump line that decides each

| | Hypothesis | Confirmed by | Refuted by |
|---|---|---|---|
| H1 | The civilian-alert burrow excludes stockpiles / shops | `why <job> --raw` / `why order:<id> --raw`: `civ_alert=<ids>` with `in_civ_burrow=false` on the holders and `status=burrow_civ`; `items:logs` / `items:plants`: `outside_civ_burrow=N` close to the total; stall line `burrow_civ=` | `civ_alert=off` and `outside_civ_burrow` absent |
| H2 | Walk groups split (citizens, items, shops on different groups after seal walls) | holder rows `same_as_shop=false` / `status=far`; `ws ... walk_groups=` differs from `citizens' main walk group`; `items:` `other_walk_group=N`, `unwalkable_tile=N`; `manager`: `walk group: him X, citizens' main Y`, office zone walk_group | one shared group everywhere, `other_walk_group` absent |
| H3 | An order pinned to an unusable shop | `order:<id>`: `workshop_id=<id>` and `pinned workshop <id> does not exist`, or the pinned `ws` with `stage a/b` unfinished, `deconstructing=true`, `max_general_orders=0`, 10 jobs; `brew`: `pinned=` beside a second Still with `jobs=0` | `workshop_id=-1`, or the pinned Still built with room |
| H4 | Workshop profile / max_general_orders | `ws ... profile: max_general_orders=0`, `permitted_workers` listing nobody who holds the labor, min/max level outside the holders' skill, `blocked_labors` containing the labor; holder rows `status=profile (not on the permitted list | labor blocked there | skill N outside a-b)` | `max_general_orders` > 0, `(none listed: all)`, level window open |
| H5 | Item flags (in_job / claimed / forbidden by the kernel's own reservations: mood reserve, trade hold, 'held back' unforbid) | `items:logs` / `items:plants` / `items:barrels`: `no exclusion` far below the census value with `forbid`, `in_job`, `in_claimed_container`, `owned` large; `fields not readable` names flags the game lacks. Compare with `census says:` | `no exclusion` about equal to the census value |
| H6 | The manager does not validate / has no office | `manager`: `orders: N, unvalidated N`, `job=` a chore, `office: chair_built=0`, `walk_path_from_him=false`, `zone` nil, no `ManageWorkOrders jobs`; `order:<id>`: `status=[active]` without `validated` | orders `unvalidated 0` and `validated` in every order status |
| H7 | A labor is missing (Carpentry on nobody) | `job:<id>` / `order:<id>`: `labor CARPENTER: 0 holder(s)` or `derived labor: ? (none derived)` | holders listed, `free=` > 0 |
| H8 | DF's job dispatch cooldown (nothing in the dumps blocks: DF just has not assigned it) | every other line clean: holders `free`, `same_as_shop=true`, items `no exclusion` = census, shop built with room, order validated and not pinned, and the job still has `worker=none` over days (the `raw stall` line repeats unchanged week after week) | any of H1..H7 shows |

Reading order for one stall: `why brew --raw` (order flags, pinned shop, Still jobs, holders), `why job:<id> --raw` for the job nobody works (items, labor, holders),
`why items:<need> --raw` for the need ('Needs logs', plants, empty barrels), `why manager --raw` when orders stay unvalidated. If no hypothesis shows, H8 stands
and the repeated stall line proves the time.

## Live-Erwartung

After a kernel reload, `python -m dfpilot why brew --raw`, `why order:<id> --raw`, `why job:<id> --raw`, `why items:logs --raw`, `why items:plants --raw`,
`why items:barrels --raw` and `why manager --raw` on i1 and i2 return the dumps above; a stalled brew, a stale order or an untaken build writes one
`raw stall` line to `kern.log` within one game week and again every following week while it holds. Unreadable fields show `?`.

## Risks

- Field names are unverified against the live DF (no structure source here): the generic dump lines name the real ones; a wrong name shows `?`.
- The item scans read up to 6,000 items and 3,000 tiles per call (read only, one call by hand, one per stall and week by the line).
- `snapshot.hidden` reads one tile flag per point (snapshot owns map reads).
- With the cures off a fort behaves like the build before BUG-834: the container and manager failures are not cured until a switch is turned on.
