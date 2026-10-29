# BUG-304 plan check calls the trade token `cloth:plant` a fair-play ERROR
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-10-29, Run 15d (Drillchamber, FR-BUGS y376 spring and y378 spring d24)
Module: `dfpilot/plan.py` (check, fair_play_hits)

## Actual
`cmd trade.want` took `cloth:plant` (RULES names cloth:plant/silk/yarn), `plan propose` kept it (BUG-242 note) and also wrote `plant`,
then `plan check`: `ERROR fair play: $.trade.want[0] mentions 'plant'` (+[6]) and `warn fair play: $.notes mentions 'plant'`. The
player removed plant cloth from the plan, the very thing the Possessed moods 26396 and 26275 needed.

## Root cause
`plan.py` check ran the blocked-word filter (`BANNED` + config/allowlist.json `blocked`, which lists the DFHack command `plant`) over
every string of the plan with a whole-word match; `:` is a word boundary there, so the trade token `cloth:plant` and the token
`plant` matched like a command.

## Fix
`plan.fair_play_hits`: the plan's own trade.want/sell entries that are valid schema tokens (`kind[:sub]`, cloth/thread subs
plant/silk/yarn) are skipped, and in the notes a run of them (`gem,cloth:plant,plant`) or a single `kind:sub` token is dropped before
the match. The word in prose (`dfhack-run plant create`), in a build parameter or in any other field is flagged as before.

## Tests
`tests/test_bug303_304_glass.py`. Fail on 9ef2ccb.

## Live check
`dfllm plan propose` in a fort whose running trade.want holds `cloth:plant`, then `dfllm plan check`: no `fair play` line for
trade.want or notes.
