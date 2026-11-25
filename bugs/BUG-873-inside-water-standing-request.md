# BUG-873 nobody ever built water inside the fort on i1: the kernel's requests (no_water once, hospital_water, patient_water never) were not answered and no request stood for 'no accepted source inside'
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i1 Diedplank: PROJECT_REQUEST cistern no_water 2x, hospital_water 2x, patient_water 0x in six years; AUTO_FAIL BUG-424 'no safe access to the water at 101,95,143'; the aquifer fallback of request_drafts served patient_water only; i4 got no_water 1x, hospital_water 1x.

## Root cause
`lua/dfllm/water.lua` had no request for 'no accepted wet source inside the fort'; `dfpilot/plan.py` `CISTERN_WHY` lacked hospital_water; `request_drafts` used the aquifer fallback for patient_water only and `_cistern_due` / `_aq_cistern_due` refuse once any cistern was applied (`(cistern, None) in done`); `dfpilot/wake.py` `_request_access` returned for good when ANY aquifer/piped cistern project existed (done or not) and followed only no_water / patient_water.

## Fix
Kernel: `M.inside_water` (every run): counts accepted wet non-emergency sources with `inn` (Kern+, the refuge, a Z4 box); none while citizens live and the manifest has Z4 -> `PROJECT_REQUEST cistern why=inside_water` every `water.inside_every` (7 d), none while a cistern project is pending; state `water.inw` (inside sources) and `water.wout` (citizens outside while inw is 0); brief/status says `WATER ONLY OUTSIDE: N citizens outside, cistern asked`. plan: CISTERN_WHY += hospital_water, inside_water; `_inside_cistern`: the aquifer cistern when an aquifer level is known, else the bucket-fed one with a fill source, whatever was applied before; no_water without a pipe route falls back to it. follow: `_request_access` answers inside_water / hospital_water: aquifer first when `_aq_known()` (also with a water tile), else the piped route; a FINISHED cistern does not answer it, one under way does, at most `WATER_INSIDE_MAX` (3) per fort.

## Tests
`tests/lua/test_bug871_877_water.lua` (request once per inside_every, pending, state inw/wout), `tests/test_bug872_873_inside_water.py` (drafts, follow rules).

## Live-Erwartung
On a fort whose only accepted water is outside: within 7 game days a PROJECT_REQUEST cistern why=inside_water, state water.inw 0 / wout N, the brief line WATER ONLY OUTSIDE (PROMISED); follow places `bp.place cistern water=aquifer` when an aquifer level is known, and `inspect water_sources` lists a source in Kern+/fort once it is built and wet (an offline Lua+Python chain, never run live; NOT promised that the basin fills or that the placement finds a site).
