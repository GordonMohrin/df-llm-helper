# BUG-056 Abstract HOSPITAL locations stay after their zones were deleted and take the doctors' posts
Status: fixed in 3713b78 (offline, live-untested): a hospital is a location with a zone; the posts of a
zoneless location are left alone; every water count already went by zones and now says how many locations are stale;
no player action deletes a location (documented)
Severity: medium (wrong decision: the live hospital's posts stayed empty)
Found: 2026-10-22, Run 11 (note 11): 8 abstract HOSPITAL locations after the zones were deleted, "no cleanup"
Module: `lua/dfllm/care.lua` (`hospital_posts`), `lua/dfllm/water.lua` (`phase_sites`, `finish`)

## Actual
After BUG-034's zone removals (and the hand deletions) the locations screen keeps its HOSPITAL entries (8 in Run 11).
`act.hospital_remove` says so itself: "the location itself stays". Nothing deleted them; the question was whether they
disturb anything.

## Cause / what they disturb (code audit at f17e2b3)
- `water.lua` builds `r.hosp` from ZONES (`ANY_ZONE` with a `location_id` of a HOSPITAL location, `phase_sites`), so
  `hosp`, `hosp_ok`, `hosp_out` (readiness `hospital_out`), the dry gate, `remove_dry`, the state and `bp sites hospital`'s
  water filter ignore a zoneless location already. `plan.py` counts `water.hosp` (zones). No disturbance there.
- **`care.hospital_posts` (`care.lua`, old 1747-1766) did disturb:** it listed the vacant posts (`occupation`) of EVERY
  HOSPITAL location, sorted them by id, and `phase_doctors_run` gave each doctor at most one post (`holders`) up to
  `posts_per_run`. The stale locations are the older ones (lower ids): with few doctors their posts came first and the live
  hospital's posts stayed empty ("with no hospital post filled the game posts no care jobs", FEATURE-004 note). With 8
  stale locations and 3-4 doctors the live hospital got none.

## Fix
- `care.hospital_posts` takes the posts of locations that have at least one hospital zone only; the vacant posts it left
  alone are counted (`doctors.stale`) and named once per change in kern.log ("N vacant post(s) of M hospital location(s)
  without a zone left alone").
- `water`: `locs = {total, live, stale}` in the run summary, `inspect water_sources` `locs`, one kern.log line per change.
- No cleanup: the DF locations screen offers no delete that a player's action reaches from the kernel's tools (the zone's
  location link is cleared by deleting the zone, the abstract building stays; `act.hospital_remove` doc, BUG-034). If a
  live read shows `dfhack.buildings` or the locations screen can retire one, a later fix adds the act; until then every
  count is robust against them.

## Tests
`tests/lua/test_care_fr.lua` (4 locations, one with a zone: the live hospital's posts are filled first, the stale ones
stay), `tests/lua/test_water.lua` (9 locations, 1 live: counts, no gate, no removal, `locs`; 8 locations without a zone:
no hospital, no gate). The care test fails on f17e2b3.

Related: BUG-034, BUG-036, BUG-040; note 11 of RUN11-offene-bugs-und-FR.md
