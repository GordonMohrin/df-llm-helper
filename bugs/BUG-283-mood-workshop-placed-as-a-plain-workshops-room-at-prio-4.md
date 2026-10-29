# BUG-283 the workshop a mood needs is placed as a plain 12-shop workshops room at prio 4 and waits 27 days
Status: fixed (offline, live-untested)
Severity: high (the glassmaker's mood failed 54,481 ticks after the late claim)
Found: 2026-10-29, Run 15 Drillchamber y375 (kern.log: `queued c1a187c6d6b8b13011 (workshops, 3 stages)` at tick 151375446,
`build: 2 manager orders` only at 151402957, done 151407760; claim at 151407628)
Module: `lua/dfllm/care.lua` (mood_seen), `lua/dfllm/runner.lua` (kind_of, sorted), `dfpilot/wake.py` (follow)

## Actual
care asked `PROJECT_REQUEST {tpl=workshops, n=1, why=mood}` without types (`care.lua:705-709`, base) and only while no other
workshops project was pending; follow's generic branch (`wake.py:728`, base) placed the whole template (every missing moodable
shop, a dug room) at the default prio 4; the runner treated it as plain `work` (paused by seal first, care first, the rebuild
policy) behind older projects. The furnace came 27 days later.

## Fix
`M.mood_shop_ask`: with economy's `mood_shops` view, ONE `PROJECT_REQUEST workshops why=mood types=[...]` of only the shops the mood
needs (his skill's shop missing on the map, then the chain shops of the missing materials, BUG-284), again after
`mood_act_every` while uncovered; the plain request only without that view. follow: why=mood with types goes the typed branch
(only those types, prio 1, `need` keeps them; a new set of mood shops is no cooldown repeat). runner `M.mood_types(sid, types)`:
the types per mood; a workshops project that builds one is kind `mood` (never paused) and sorts with the hospital before the rest;
the answer is what no mood-only project covers yet. An ended mood clears it (`M.mood_gone`).

## Tests
`tests/lua/test_mood_emergency.lua` (typed request at once, not repeated, gone when the shop stands; runner: rebuild policy and
mood_types), `tests/test_bug282_285_moods.py` (follow params/prio/need, plain request kept). Fail on 64df679.

## Live check
At the next mood without his shop: events `PROJECT_REQUEST ... why=mood types=[...]`, cli.log `auto:mood` with `prio 1` and the
`skip` of every other type, kern.log `queued <id> (workshops, ...)` and no `paused:` for it in `dfllm status`; the claim follows
within days (popup `has claimed a ...`). If the shop's room needs a long dig, note how long from request to claim.
