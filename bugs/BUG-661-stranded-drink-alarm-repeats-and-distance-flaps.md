# BUG-661 STRANDED / stranded_drink / thirst alarms repeat for citizens who drink outside; the distance flaps; the suggested cistern command finds no site
Status: fixed (offline, live-untested)
Severity: low (noise; the real risk is that the player learns to ignore class-A alarms)
Found: 2026-11-10, Run 16c i3 Wallfree y391-y405: STRANDED / DECISION_NEEDED `stranded_drink` / `thirst` every few days for 1-2 citizens on walk group 2258 at a stable thirst ~26,000 (they drink at the cavern lake zone 17718, 0 dead); events.jsonl:6130-6195
Module: `lua/dfllm/siege.lua` (`cut_off`, `M.anchor`, `episode`, `dry_decision`, refused branch), `lua/dfllm/water.lua` (`stranded_fix`, `src_dist`), `lua/dfllm/economy.lua` (`alarm_check`)

## Actual
- `zone 17718 at 91,59,142 is 7 / 23 / 25 / 31 / 35 / 39 / 40 / 69 tiles off` for the same group: the distance was measured from `e.pos`, the position of the FIRST stranded citizen the walk-group list gave. The group is the whole fort and its surface; the citizen walks about.
- The announcement record (`CAD`) was keyed by the citizen ids, so every other citizen going over the mark was news ("grew"); the `thirst` DECISION came every 7 days with `thirst_woke` only.
- `dfllm bp sites cistern --near 90,90,146 --within 20 --fresh` answered `no site within 20 tiles ...; the nearest candidate 110,29,146 is 62 tiles away` (cli.log:2466): the command in the alarm was not executable.
- (Not a bug of the alarm: `drink 0 d` with `5 forbidden` is the cook-ingredient line of an ORDER_STUCK; the drink days are 0 because the citizens drink at the zone.)

## Root cause
`siege.lua` `cut_off` (e.pos = first citizen), `dry_decision` / refused `stranded` (ids = the citizens), `economy.lua` `alarm_check` (weekly only), `siege.lua` `dry_decision` (`--within 20`).

## Fix
- `siege.M.anchor`: a drink case's position is the stranded citizen nearest to the nearest accepted water (`water.src_dist`), and the nearest one seen for the group in the episode (`mem.str_anc`): one distance that only falls, and `--near` is a point of their own walk group.
- `siege.episode`: the announcement set is the group (`g<id>`) and the tokens are `n<most stranded in the episode>` and `fight` (thirst over `FIGHT_THIRST`): one STRANDED `refused` and one `stranded_drink` per episode, again when MORE are stranded or the thirst crosses the dehydration line. The episode ends (record cleared) when the group has drink.
- `economy.alarm_check`: the `thirst` decision once per episode (`p.thirst_ann`), again only when more citizens are thirsty than the last one announced; the episode is over after 30 days without thirst.
- The cistern command carries `--within 80` (`siege.CISTERN_WITHIN`, `water.stranded_fix`): `bp sites` ranks nearest first within the radius, so it returns the nearest site however far (with its distance in `why`).

## Tests
`tests/lua/test_stranded.lua` (BUG-661: anchor, one alarm, worse = announced; BUG-391 adapted), `tests/lua/test_economy.lua` (thirst once per episode), `tests/lua/test_bug615_617_water_deaths.lua` (`src_dist`, `--within 80`).

## Live check
Wallfree-like fort: one STRANDED `refused` and one `stranded_drink` per episode, `fix` with one distance; the cistern command prints a site (the nearest, maybe far). Open: no template digs the walk path (ramp/stair) to the water, so the fix text still says "open a walk path" without a command; `thirst` still offers the `farms surface=1` command whether or not `bp sites` has a site; the anchor is runtime memory (a reload may announce once more).
