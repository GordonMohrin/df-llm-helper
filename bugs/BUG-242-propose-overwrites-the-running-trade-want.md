# BUG-242 plan propose overwrites the running trade.want
Status: fixed (offline, live-untested)
Severity: medium (the apply would have dropped the food and seed wants set for food_low; the caravan buys the old list)
Found: 2026-10-29, Run 15 Inkintense y373 (FR-BUGS.md "plan propose überschreibt trade.want")
Module: `dfpilot/plan.py` (`propose`, new `live_trade`, `auto_plan`, CLI `plan propose`)

## Actual
`propose` copied `trade` from the applied plan, else the default `bar:iron, anvil, cloth`. Gordon's `cmd trade.want` with food
and seeds (food_low decision) is an override in the kernel (trade.lua) that lasts until the next plan.reload, so applying the
draft would have replaced it by the old list. The player added the tokens to the file by hand.

## Fix
`live_trade(save_dir)` reads the `verb:trade.want` lines of `<save>/cli.log` written after plan.json's time (the last apply's
reload ends the override) and merges their `want` / `sell` lists in order, as the override does; a line whose reply was ERR is
skipped. `propose(..., live=...)` starts `trade` from them (the CLI and follow's `auto_plan` pass it); the metal, leather and pick
goals still put their tokens in front. The notes say "BUG-242: trade.want kept from the running cmd trade.want: ...".
The state has no trade.want key, so the kernel's list itself is not read (no new state field).

## Tests
`tests/test_bug241_244_plan_propose.py`: `test_live_trade_reads_the_cmd_after_the_last_apply`,
`test_propose_keeps_the_running_trade_want` (fail on 6dc0f19).

## Live check
`dfllm cmd trade.want '{"want":["food","seeds","cloth"]}'`, then `dfllm plan propose`: the draft's trade.want is food, seeds,
cloth (with bar:iron in front while the fort has no ore) and the notes name it; after `plan apply` a new propose takes the
plan's list again.
