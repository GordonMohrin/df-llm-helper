# BUG-448 the water scan is not refreshed after a finished aqshaft / cistern; the request draws the cistern again
Status: fixed (offline, live-untested); open: whether `plan propose` itself redrafted the aqshaft (not reproduced: the applied-builds set covers it)
Severity: medium
Found: 2026-11-05, Run 16d i4 Mazelanterns y404 (`runs/run-16d/FR-BUGS.md` "OBS aqshaft+cistern (y403) fertig, aber water_sources-Scan veraltet")
Module: `lua/dfllm/water.lua`, `dfpilot/plan.py` (`_piped_cistern`), `dfpilot/wake.py` (`_request_access`)

## Actual
y403s1b2 aqshaft 100 % and y403s1b3 cistern 100 %, then `bp sites hospital --fresh` still "no accepted water in Tiefe+", `inspect water_sources`: last finished 7.3 M ticks ago, 'scan queued for the next water run'. The scan ran only
weekly while no water was accepted (`ws_want` in `finish`) and on an inspect; a finished build never asked for one. The draft y404 listed aqshaft + cistern again (the player had them in s1 of y403).

## Fix
- `water.lua M.on['EV:PROJECT_DONE']`: tpl aqshaft or cistern -> `ws_want` at once and `m.water ws_redo` = now + `water.ws_redo` (3 days, 0 = no second scan; the cistern fills) -> one more scan; kern.log names it.
- `plan._piped_cistern` and `wake._request_access`: an aquifer cistern (p.water = aquifer, no pipe, BUG-434) answers the PROJECT_REQUEST cistern like a piped one, done or under way. It did not (only `p.path` counted), so the request stayed open
  and `request_facts` / follow drafted and placed another cistern beside the aquifer one.
- The aqshaft is not drafted again by `aquifer_late` / `aquifer_core_swap` (`fort.aqshaft` = any applied aqshaft, done ones included; bp files stay after PROJECT_DONE); checked, no change.

## Tests
`tests/lua/test_bug446_449_water.lua` (scan queued, redo, other templates), `tests/test_bug446_449_f28.py` (2).

## Live check
After the next aqshaft/cistern PROJECT_DONE kern.log: `water: aqshaft <id> finished: the water sources scan is queued`; `inspect water_sources` shows a fresh `tick`.
