# BUG-273 seal first paused the workshops project whose Carpenter's would make the seal's own door (deadlock)
Status: fixed (offline, live-untested)
Severity: high (the fort hung 20 days: SEAL_STUCK, food 27 d, drink 20 d, 9 of 14 idle; the player cancelled the seal)
Found: 2026-10-29, Run 15 Drillchamber (y372 summer), fix6-runner-seal
Module: `lua/dfllm/runner.lua` (`Q.door_shop`, `Q.door_need`, `paused`, `note_pause`)

## Actual
kern.log:100 `seal first: c1a187448501ce4301 with 1 piece open (door 102,124,144) runs first; paused: c1a187433a25b12d07 farms,
c1a1874371caf47508 workshops, y372s0b0 fortcore`. The door waited for buildingplan 'door x1 (0 free, 3 ordered)'; the door orders
needed a Carpenter's workshop that only the paused workshops project would build (status `orders 55 stuck 37 (workshop missing 37)`).
Root cause: `SEAL_PAUSES = {work, beds, supply}` and `kind_of` classes a workshops project as work; nothing asked whether the seal
itself waited for that project.

## Fix
A workshops project that builds a Carpenter's or a Mason's workshop (not skipped, or added) is the seal's enabler and is not
paused while the lead seal has an open door or hatch whose building waits for its item (economy.build_state who = buildingplan) and
neither shop stands built (the WORKSHOP_ANY list; unreadable: no claim). The seal-first kern.log line names it
(`(ws workshops go on: Carpenter's/Mason's for door x,y,z)`). Not built: fortcore stage 1 and mood requests are not classed as enablers.

## Tests
`tests/lua/test_runner_seal_fix6.lua` `BUG-273 ...` (fails on 2b9c009).

## Live check
A fort without Carpenter's/Mason's and a new seal with a door: kern.log `seal first: ... runs first (<id> workshops go on:
Carpenter's/Mason's for door x,y,z)`, `dfpilot status` rows: the workshops project not `paused: seal`; once the Carpenter's stands
it is paused again until the door is built.
