# BUG-233 status/brief hide the manager deadlock; RULES and the decision text ask for a click at a workshop
Status: fixed (offline, live-untested)
Severity: medium (the game session could not see what held the fort for a year, and the advice it got was impossible)
Found: 2026-10-29, Run 15 Guildcleans (y372-y373), `runs/run-15-guildcleans/FR-BUGS.md`
Module: `dfpilot/brief.py` (`manager_line`), `lua/dfllm/economy.lua` (state `orders.byp`, `office_check` texts),
`dfpilot/wake.py` (`MANAGER_HINT`), `RULES.md` §7 DECISION_NEEDED `manager_office`

## Actual
Status showed `orders: 13 unvalidated, oldest 58 d: the manager has no office zone` and nothing about a way out. The DECISION_NEEDED
manager_office text said `not built: no free chair; add it at a workshop by hand`, RULES §7 the same (`= add the task at a workshop
by hand`), and the wake line's `next:` was the generic `ask Gordon in chat`.

## Fix
The reason of a missing office zone reads `no office (chair+table needed)`; state `orders.byp` (str <= 80) says what the kernel does
(`kernel adds workshop tasks: chair, table, door x3`, `no Carpenters: workshop requested for ...`, `workshop tasks wait for logs or
stone: ...`); status and brief print `manager: N orders unvalidated for D days: <reason> -> <what the kernel does>`. The decision's
fix text says `the kernel adds it as a workshop task`; the wake hint for DECISION_NEEDED manager_office names the kernel's tasks and
the office template; RULES §7 (edited in place, still 300 lines) names `orders.bypass_days` and MANAGER_BYPASS instead of the click.
`dfllm next` suggests nothing new for it (the interrupt's TELL PLAYER is the decision line).

## Tests
`tests/test_bug231_233_manager.py` (`test_status_says_why_and_what_the_kernel_does`, `test_nothing_asks_for_a_click_at_a_workshop`),
`tests/test_bug042.py` (the line's new form, worst-case tokens with `byp`), `tests/lua/test_manager_bypass.lua` (state
`orders.mgr`/`orders.byp`), `tests/lua/test_economy_drink.lua`, `tests/lua/test_economy_orders.lua`. All fail on 6dc0f19.

## Live check
`dfllm status` in a fort whose orders wait for the manager: the line `manager: N orders unvalidated for D days: no office
(chair+table needed) -> kernel adds workshop tasks: chair, table` (after `orders.unval_days`, the arrow part after
`orders.bypass_days`); `dfllm brief` the same; the wake line of DECISION_NEEDED manager_office ends with the kernel's tasks.
