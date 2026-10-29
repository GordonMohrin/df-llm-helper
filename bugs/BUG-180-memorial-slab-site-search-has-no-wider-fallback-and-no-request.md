# BUG-180 A memorial slab with no free 3x3 within 16 tiles of the seeds waits: no wider search, no request
Status: fixed (offline, live-untested)
Severity: medium (ghosts stay unserved until the citizens seed happens to land near free floor)
Found: 2026-10-29, live test round 2 instance i4 (NEW5; skeptic confirmed in code and kern.log)
Module: `lua/dfllm/care.lua` (`MEM.grid`, `MEM.widen`, `MEM.request`, `MEM.place`), `config/baseline.json`

## Actual
`MEM.grid` scanned only `coffin_scan_r` (16) around crypt, core and citizens on the seed's level. kern.log 292509129 and 292537671
'memorial: slab 2947187 of ghost unit 42171 waits: no free 3x3 floor ... within 16'; placed later only because the citizens seed moved.

## Fix
- `MEM.grid(K, c, r, R, cap)` takes a radius and a tile-read cap (`G.cut`; the why then says `capped`).
- `MEM.widen`: no site within `coffin_scan_r`: the seeds are searched again at `care.mem_scan_wide` (default 32, 48), `mem_scan_reads` (10000) reads each.
- `MEM.request`: no site for `mem_req_days` (3, 0 = off) game days in a row (`p.mem_nosite.since`): PROJECT_REQUEST tombs n=1 why=memorial
  (follow places a tombs dig: a new crypt room), rate-limited together with the coffin request (`tomb_request_every`).

## Tests
`tests/lua/test_fix2_tombs.lua`: a hall 25-31 tiles from the core gets the slab; no floor at all: one request after 3 days, none with mem_req_days 0 (both fail on b805745).

## Live check
At the next ghost with a loose memorial and no free 3x3 near the crypt/core: kern.log `memorial: ... placed at` beyond 16 tiles, or `waits: ... within 48 of ...`; after 3 game days `dfllm events --type PROJECT_REQUEST` shows `tombs: a crypt room for the memorial slabs (...)` with d.why memorial.
