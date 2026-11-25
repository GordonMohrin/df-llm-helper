# BUG-859 `wait` slept through a popup pause (3 real minutes) and `trade.want add` was lost at the next plan apply
Status: fixed (offline, live-untested)
Severity: medium
Found: Run 17 i2 Whirledrampart (a noble-claim popup paused the game for 3 real minutes; PAUSED_BY_DF only after 5 min); Run 17 round 4: 'trade.want add ersetzt statt zu ergaenzen'.
Module: `dfpilot/alarm.py` (`sys_reasons`, `_POPUP_SEEN`, `SYS_NEXT`), `dfpilot/session.py` + `config/wake.json` (`wait.popup_s`), `dfpilot/plan.py` (`live_trade`, `apply_trade_ops`, `propose`), `lua/dfllm/trade.lua` (`lost`, the reply)

## Root cause
1. The wake list of `wait` (`sys_reasons`) knew KERNEL_STALE, DEADMAN and FOLLOW_OFF; a pause by a popup (`owners.pause == popup`) was reported only by the kernel's PAUSED_BY_DF after `resume.minutes` (5) and by `follow`'s 30 s hint, never by `wait`.
2. The kernel's `trade.want add / remove / sell_add / sell_remove` do merge (BUG-440, tested), but `plan.live_trade` (the running cmd the plan draft keeps, BUG-242) read only `want` / `sell`: a player who only ADDED tokens had them replaced by the draft's own list at the next `plan apply`. A `want` / `sell` replacement and a full list (40 tokens) also dropped tokens without a word.

## Fix
1. `sys_reasons`: the game paused by a popup for `wait.popup_s` (20, range 0..3600) real seconds in this process -> a `POPUP_PAUSE` wake `the game stands paused by a popup (N s seen): "<popup text>" | next: dfllm cmd resume (...)`; the clock resets when the pause ends or is the player's.
2. `live_trade` returns `want_ops` / `sell_ops` (the add / remove changes since the last replacement of that list, in order); `propose` applies them to the draft's lists (`apply_trade_ops`, trade.lua's rule: added tokens in front, removed out, no doubles, 40 at most). The kernel's reply names what a change took out: `; dropped from the want list: a,b` (and `sell list`).

## Tests
`tests/test_neu7_vorrat.py` (popup wake, live_trade ops, apply), `tests/lua/test_bug858_859_halt_trade.lua` (dropped text).

## Live-Erwartung
1. A popup pause: a `wait` call that sees `owners.pause == popup` returns `WAKE POPUP_PAUSE: ... | next: dfllm cmd resume` after `popup_s` (20 s) (PROMISED while the call runs; a pause that began before the call counts from the call's first look). Not woken: the player's own pause, pause:df (PAUSED_BY_DF handles it).
2. `trade.want '{"add":["wood"]}'` followed by `plan propose`: the draft's trade want list starts with `wood` and the notes say 'BUG-242: trade.want kept ...'. A `want` replacement answers `; dropped from the want list: ...`.
