# BUG-053 Miners hold no pick for 1081 and 144 days beside 16 and 100 free picks lying loose; no pick is ever made or asked for
Status: fixed in 9eca0c3 (offline, live-untested; the DF-side cause is not decided offline): the diagnosis names the
population-level blockers `forbidden` / `off_group` / `owned`, free tools the members lack for `tools.stale_days` stop
counting as stock (the forge and the caravans make up the picks), usable loose tools get a weapons stockpile `dfllm-tools`
near the open dig jobs (act.tool_pile) restricted to picks and battle axes, and the lacking members ask for the equipment
update again when it stands
Severity: high (wrong decision: the Miners detail idles for years, every dig project stalls 'slot yielded', idle 74 %)
Found: 2026-10-23 (notes 19 and 34 of bugs/RUN11-offene-bugs-und-FR.md; the live root cause of BUG-023), Run 11 Kilrudrabed y487
and Run 12 y501 (a reclaimed fort), from the game session
Module: `lua/dfllm/economy.lua` (census `classify`, `tool_check`, `tool_diag`, `td_blockers`, `plan_picks`, `metal_plan`,
`T.toolpile`, `M.pile_site`), `lua/dfllm/act.lua` (`tool_pile`), `config/baseline.json` `economy.tools`

## Actual
- Note 19 (Run 11 y487): `Miners: 5 of 6 hold no pick for 1081 days, 16 free picks (16 loose) at 157,57,139` - the picks lie
  loose, outside the miners' walk group/burrow (the session's reading).
- Note 34 (Run 12 y501 summer d49, a reclaimed fort whose items were all forbidden, note 29): 74 % idle (31 of 42), 409
  unclaimed jobs; `Miners: 1 of 6 can take none of the first 4 open dig jobs (off their walk group or burrows), 144 days, tool
  pick why loose`; 102 picks in the fort, `pick_free` 100, 'loose'; every new dig project (bedrooms, office, barracks) stalled.

## Expected
Miners get picks. When the fort's picks cannot be handed out, the report says why and the fort makes or buys the picks it
needs instead of counting the unusable ones as stock.

## Cause
Proven from the code (f17e2b3):
1. **Nothing gives a pick a home.** The only weapon stockpile the kernel builds is fortcore's melt pile (`dfpilot/bp/fortcore.py:152`,
   `pd name=dfllm-melt automelt=true`), and `baseline.lua:321-323` (`melt_keep` = pick, battle axe, crossbow;
   `config/baseline.json:22`) makes it refuse picks, axes and crossbows by design (live L1b: it had taken the spare picks and
   marked them for melting). No template builds another weapon pile (the barracks has racks and stands, not a pile). So a free
   pick lies where it fell, `loose` in tool_check's words (`free - bins`, `economy.lua:3284`), for ever.
2. **The economy counted every pick as stock.** `M.plan_picks` (`economy.lua:4878-4880`): `have = r.inv.w_pick` - all picks in the
   fort except forbidden ones and merchants' - against the demand `st.want.pick` (<= the miners, 6); `metal_plan`
   (`economy.lua:4928`) the same. With 16 or 100 picks `short` was 0: no forge order (`picks`), no `trade.want pick`, for
   1081 and 144 days, while TOOL_BLOCKED named the loose picks every cadence.
3. **The report sampled the wrong picks.** The census lists the first `M.TOOL_LIST` = 8 tools of a kind in item-vector order
   (`economy.lua:730`) and the diagnosis reads the first `TD_PICKS` = 4 of them free-first (`economy.lua:3005`); 100 picks
   on another walk group or in a ruin's far corner could fill the list while the reachable ones were never listed, and the
   population facts (how many forbidden, owned, off the group) were not counted at all: `td_blockers` only knew the sample.
4. **Forbidden tools on a tile the kernel does not know or on another walk group** are skipped by `T.forbid`
   (`economy.lua:6483`: `known_tile` and not `far`) without a trace; the report had no key for "every pick is forbidden".
5. **The two notes, read with the code:** the quoted messages carry `16 loose` and `tool pick why loose` - tool_check adds
   `forbidden` to `why` and the where-list when `forb > 0`, `reserved` for `res`, `bin` for containers
   (`economy.lua:3283-3286`), so in both cases the 16 and 100 picks were **free, not forbidden, not reserved, not in a bin**
   (the reclaim's forbidden items were freed by the player's `unforbid all`, note 29). Note 34's quoted blocker is `jobs`
   alone (the text 'off their walk group or burrows' is `td_blockers`' `jobs`; `d.blk` joins every blocker with '; ' and the
   event message appends the first): if the quote is complete, `labor`, `tool2`, `alert`/`burrow` and `walk` did not hold for
   the sampled records (a pick on the member's group, a member with the labor). Note 19's
   blocker text is not in the quote.

Not provable from the code: why DF's equipment update handed none of the free picks out (see "Not decided offline").

## Fix
- **Census:** `w_<tool>_far` (free, on another walk group than the citizens: `snapshot.far`) and `w_<tool>_use` (free, reachable,
  not owned, not marked for melting). The listed 8 prefer the tools on the citizens' group (`M.tool_listed`), the diagnosis
  and `tool_where` read near, then far, then forbidden (`M.tool_rank`).
- **Diagnosis keys (population level, first in `bk`):** `forbidden` (every tool of the kind is forbidden: "all 100 picks are
  forbidden (the daily unforbid could not free them)"), `off_group` ("16 of 16 free picks lie on another walk group than the
  citizens (the first at 157,57,139)"), `owned` ("16 of 16 free picks are owned by a dwarf"). They are cause tokens like the
  others (a new one is news, util/cadence).
- **Stale tools:** free tools the members of a detail lack for `tools.stale_days` (14), with no member-side cause (`labor`,
  `tool2`), stop counting in `plan_picks` and `metal_plan` (`M.tools_have`): the forge makes picks (`picks`), else
  `economy.trade_wants` asks the caravans. The count is fixed when the tools turn stale (`rec.stn`), so picks made later
  are stock: at most `want` picks are made, never an endless supply. Fair play: work orders and a trade want.
- **Tool pile:** when usable tools (`use` > 0) lie loose while the members lack them for `pile_days` (7) - and no member-side
  cause holds - `T.toolpile` (daily, PEACE/RECOVERY) places a weapons stockpile `dfllm-tools` (`act.tool_pile`: quickfort place
  mode key `p`, 3 x 2) on the nearest revealed plain floor within `pile_r` (12) tiles of the first open job of the detail on
  the citizens' walk group (`M.pile_site`: no building, no pending designation, not a cavern tile, not on the attack path -
  manifest Z1/Z2/killboxes -, at most `pile_reads` tile reads), once per `pile_every` (28) days; a pile named `dfllm-tools`
  that stands is not made again. It is then restricted to picks and battle axes (`stockpiles import -m disable cat_weapons`,
  then `-m enable cat_weapons -f pick,battle axe`, as baseline restricts the melt pile; three tries). DF's haulers fill it; the
  kernel never moves an item. When the pile is placed and again when it is restricted the lacking members ask for the
  equipment update again at once (`M.pile_ask_again`, `tools.equip_update`), not after `repair_days`.
  Tools on another walk group get no pile: neither members nor haulers reach them.
- TOOL_BLOCKED `d.pile` (`dfllm-tools placed at x,y,z (3x2)` / `stands` / `nosite: why` / `refused: why`; a new state is news),
  `inspect workload key=tools`: `pick_far`, `pick_use`, `pile`, `piles`, `stale`. Config `economy.tools` `stale_days`, `pile`,
  `pile_days`, `pile_w`, `pile_h`, `pile_r`, `pile_reads`, `pile_every` (`fairplay.ECONOMY_LIM`, `lint --config`, the mirror
  test). Contracts: TOOL_BLOCKED, census, `act.tool_pile` (CONTRACTS §5, `util/contract.lua`, `schema.py`), RULES §7 row.

## Not decided offline
- **Why DF hands out none of the free picks.** The code and the notes exclude forbidden, reserved, bins (and, for note 34, labor,
  second tool labor, burrow/alert and a pick off the member's walk group for the sampled picks); they do not decide
  between an owner (a ruin's picks keep `flags.owned` of dwarves who are gone: `owned` now names it), DF's own free list
  (`pool`), a work-tool pair with another unit (`pair`/`upair`) and the missing stockpile. Decides, all read-only: the next
  TOOL_BLOCKED `bk` and `picks`/`units` records (`dfllm cmd inspect '{"what":"workload","key":"tools"}'`), kern.log
  `tools: Miners blocked (...)`.
- **Does a pile change anything?** Decides: after `tool pile: dfllm-tools ... placed`, the stockpile on the tiles (the pile's
  contents), `inspect ... key=tools` `pick_free`/`pile`, and whether the Miners hold picks a few days after the two equipment
  update requests; if not, `stale_days` makes the forge/caravans the way out.
- **Is `stockpiles import -m enable cat_weapons -f pick,battle axe` the right filter syntax for a pile that starts with every
  weapon?** The disable call is baseline's proven form; the enable call mirrors it. kern.log says `could not be restricted`
  (three tries); the pile then accepts every weapon (3 x 2 tiles, bounded). Quickfort's `p` is the weapons key (the melt pile
  `pd` = weapons + armor).

## Tests (fail on f17e2b3)
`tests/lua/test_economy_tools_a3.lua` (new, fixtures of the two notes: 16 free picks on another walk group at 157,57,139 with 5
of 6 miners without one - `off_group`, `pick_far` 16, no purchase before 14 days, `trade_wants` pick x5 after; 100 loose usable
picks of a reclaim - the pile after 7 days near the dig jobs on revealed floor, its restriction, one pile only, the picks asked
after 14 days; the equipment update asked again; `pile` false, a pile that stands, `pile_every`, no site, no pile outside PEACE;
the stale count fixed; all forbidden with a refused unforbid - `forbidden` first; owned - `owned`; the tool list prefers near
tools), `tests/lua/test_act_supply.lua` (`tool_pile`), `tests/lua/test_economy_jobs.lua` (the census counts),
`tests/test_military_a3.py` (config validation, the Lua defaults mirror, the act table, the event field).

## Live check
See the CHANGELOG entry (2026-10-23, package A3).

Related: BUG-023 (tool details, TOOL_BLOCKED), BUG-024, FR-40 (workload), DECISIONS 14 (loose tools), notes 19, 29, 34
