# BUG-236 the player's `lever` down is accepted and then silently overridden
Status: fixed (offline, live-untested)
Severity: high (the player cannot open a gate by hand in PEACE)
Found: 2026-10-29, Run 15 Guildcleans (i2), fix5-gate
Module: `lua/dfllm/gate.lua` (`verbs.lever`, `M.want`, `M.up_refusal`, `M.hold_*`, `M.lever_hold`, `set_want`, MODE handler,
`manifest_pass`), `config/reflex.json`, `dfpilot/fairplay.py`

## Actual
Live data: Run 15 Guildcleans, instance i2, `E:/DF-test2/dfllm-runtime/r15-guildcleans-site97` (kern.log, events.jsonl, commands.log, cli.log; read only). `python -m dfpilot cmd lever {"bridge":"B1","want":"down"}` replied 'ok queued B1 down' twice (LEVER jobs 20775 at
151347680 and 21087 at 151386397); within 100 ticks siege's refused rescue wanted B1 up again (BUG-234), gate cancelled the job
(commands.log cancel_own_lever_job only) and no kern.log line said why. GATE_FAIL's `since` 151386473 is that override.

## Fix
`lever` down holds the bridge down for `gate.lever_hold_days` game days (config/reflex.json, 0..28, default 3; 0 = no hold;
persisted m.gate.hold). While it runs, in PEACE without a lockdown, `gate.want(b, 'up', why)` with a why other than `lever:*` is
refused with the reason ('held down by the player's lever (llm) for N more ticks; a threat ends the hold', kern.log once a day) and
the D-14 up peace gates leave it down. A lockdown, a mode other than PEACE (threat or drill) or `lever up` ends it with a kern.log
line; it ends by itself at its tick. The reply says '; held down N days'. Any want that replaces a player's lever want is named in
kern.log ('gate: B1 up (x) replaces the player's down (lever:llm)'); a matching want takes the lever's why. No automatic drill
while a hold runs ('lever hold B1').

## Tests
`tests/lua/test_fix5_gate.lua` `BUG-236: ...` x2 (fail on 6dc0f19).

## Live check
`dfllm cmd lever {"bridge":"B1","want":"down"}` in PEACE: reply '... held down 3 days', kern.log 'gate: B1 held down by lever',
B1 down within a minute and still down a day later; `dfpilot status` drill hold 'lever hold B1'.
