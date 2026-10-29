# BUG-217 The memorial request never fires under care's pacing
Status: fixed (offline, live-untested)
Severity: medium (a memorial slab with no site waits for ever; its ghost keeps haunting)
Found: 2026-10-29, live round 4 (E:/DF-test4, Trussroads region2-site90) and its skeptic; follows BUG-180
Module: `lua/dfllm/care.lua` (`MEM.place`, `phase_memorials_run`)

## Actual
Slab 2991783 (ghost 40329) waited three times, at ticks 295461831, 295492602 and 295520968 ('waits: no free 3x3 ... within 4
of crypt ...'), and no PROJECT_REQUEST why=memorial came in 59000 ticks (49 game days). `MEM.place` kept the episode start
`since` only when the last failed search was at most 2 x coffin_retry (7200 ticks) ago. Under care's pacing and demotion the
memorial searches came 28000-31000 ticks apart, so every search began a new episode (since = now), and `MEM.request` never saw
mem_req_days (3 days) pass.

## Fix
`p.mem_nosite` records the slab id (`sid`). A failed search for the same slab keeps `since` however far apart the runs are; the
2 x coffin_retry window still applies to a different slab. `phase_memorials_run` ends the episode (`p.mem_nosite = nil`) when
no loose memorial slab is left (or no ghost at all), so a stale episode cannot carry into a later slab. Placing a slab ends it
as before.

## Tests
`tests/lua/test_fix2_tombs.lua`: 'BUG-217: memorial searches far apart ...' and 'BUG-217: no loose memorial slab left ...',
both fail on 5e9e719.

## Live check
A loose memorial slab with no free 3x3 within the wide radii (or the radii cut in memory): kern.log shows 'memorial: slab ...
waits' runs far apart, and after mem_req_days game days of waiting one PROJECT_REQUEST tpl=tombs why=memorial comes;
`state.a.json` m.care.mem_nosite keeps one `since` and names the slab in `sid`.
