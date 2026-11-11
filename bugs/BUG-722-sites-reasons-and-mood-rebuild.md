# BUG-722 `bp sites hospital` 'no valid site on the snapshot' without a reason; the MOOD line recommends a place that is refused for a gone shop
Status: fixed (offline, live-untested)
Severity: low
Found: 2026-11-10/11, Run 16a i1 Basementflew (`bp sites hospital` = 'no valid site' with accepted water in the fort), Run 16d i4 Trumpetrealms y461 (MOOD line `{tpl:workshops,site:S1,p:{only:Jewelers}}` refused '0 free sites', worked with `p.rebuild=1`)
Module: `dfpilot/bp/sites.py` (`_rooms_funnel`, `rank`), `lua/dfllm/care.lua` (`ws_fix`), `lua/dfllm/economy.lua` (`mood_shops`)

## Fix
- `sites.rank` (hospital with accepted water, no candidate at all): 'no valid site on the snapshot (N anchor tile(s) on the Z4 floor, 4N placements: a with no open door tile, b whose room meets rock, a wall, liquid or leaves the map, c in a keep-out box, d on the refuge level, e fit; nearest accepted water: ...)'.
- `economy.mood_shops` lists `gone` (the missing types the manifest has in `gone`); `care.ws_fix` names `{"only":"<type>","rebuild":1}` for such a shop (one type per call).

## Tests
`tests/test_bug722_sites_reason.py` (2), `tests/lua/test_bug722_mood_rebuild.lua` (2).
Open: the funnel is read for the hospital with water only (other room templates keep their messages); a `workshops` rebuild still needs the old site free (BUG-656).
