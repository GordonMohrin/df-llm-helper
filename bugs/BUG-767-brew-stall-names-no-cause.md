# BUG-767 Five brew orders stand 74 days beside a Still, 3,882 plants and 12 empty barrels: the report said "none ran", not why
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16b i2 Whirledrampart y449 aut d43 (events #17389 DECISION drink_low block `brewstall`: "5 brews ordered, none ran for 74 days (still stands, plants 3882, empty barrels 12)"; drink 243 -> 45 days; the player's `bp.place workshops only=Still rebuild=1` did not help, `inspect orders` named no reason).
Module: `lua/dfllm/economy.lua` (`M.brew_diag`, `M.brew_cause`, `M.brew_watch`, `M.brew_spec`), `lua/dfllm/act.lua` (`ws_profile_open`, `labor_set brew`)

## Actual
BUG-760 made `auto: brew` honest and added the `brewstall` block, but the kernel only counted. Nobody looked at what DF's manager needs before a Still gets a brew job: the Still's workshop profile lets the order in (general orders > 0, no permitted-worker list without a brewer, a skill window that holds a brewer), the order's own item conditions hold (DF counts "2 unrotten plants with DRINK_MAT" and "an empty food-storage item" its own way, not as the census does), a citizen holds the Brewer labor and is free to take the job. The stall lasted until the player gave up.

## Root cause
`economy.lua` `drink_block` (the `put('brewstall', ...)` entry) and the missing watch: no code read the Still (`building.profile.max_general_orders`, `permitted_workers`, `min_level/max_level`, `building.jobs`, the job's worker), the brewers (Brewing labor holders and the job each does) or the orders (`workshop_id`, `item_conditions`). The live cause in i2 is not readable offline (the 74-day-old state is gone; the runtime log has no Still sheet); the candidates the code can now tell apart are the ones DF checks.

## Fix
- `M.brew_diag` (read-only) and `M.brew_cause`: the first failing check, in words with the Still's id and place and the brewers named with their jobs: `Still 7 at x,y,z takes no general orders (max_general_orders 0)`, `takes only its N permitted workers and none holds Brewing`, `takes workers of skill a-b and no brewer is in that window`, `nobody holds the Brewer labor`, `the Still holds N brew jobs nobody works; all M brewers are busy: Name id (job), ...` / `idle brewers: ...; DF did not assign it`, `all suspended`, `N brew orders pinned to workshop W that is no standing Still`, `the manager gave no Still a job (valid orders, item conditions: DF counts items its own way)`, `a brewer works at the Still: slow, not stuck` (no action).
- `M.brew_watch` (daily, T.watch): valid brew orders whose amount left has not moved for `BREW_STALL.days` (6) days beside a standing Still, brewable plants and an empty barrel: the cause is told once (ORDER_STUCK `brewing stalled ...`, kind `worker` / `input`; kern.log with the full text; again after 30 days) and cured: closed profile -> `act.ws_profile_open` (general orders 10, permitted list cleared, skill window 0-3000); nobody holds Brewing -> `act.labor_set brew` for an idle adult (`M.labor_assign`); every brewer busy -> one more brewer; no job at the Still, a pinned order, a profile or labor fix -> the open dfllm brew orders are taken down and made again with no item condition at the top of the manager's list (`p.brewx`, `M.brew_spec`, as the cook stall BUG-629; ends when the drink days reach the plan's target and no brew order is open).
- The drink decision's `brewstall` text now ends `; cause: <text>` (`st.brewx`).
- `act.ws_profile_open(Still id)`: new act function (owner economy, contract + schema), only a Still, no job or order or building created or removed. `act.labor_set` knows `brew` (on).

## Open
Which of the causes was true in i2 stays unproven until a live run; the `building.profile` fields (`max_general_orders`, `permitted_workers`, `min_level`, `max_level`) are read through pcall and fail closed (no cause named from a missing field). Needs a Kernel reload.

## Tests
`tests/lua/test_bug767_brew_cause.lua` (8): no job -> relaxed order; profile with 0 general orders; permitted list without a brewer; nobody holds Brewing; every brewer busy (named with jobs, extra brewer); idle brewer; a working brewer / a moving order / a pinned order; the decision text.
