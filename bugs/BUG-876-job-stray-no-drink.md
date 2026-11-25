# BUG-876 with no drink stock the outside-errand guards never ran: no errand cancelled, no hunt stopped, MISSING never sounded
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i1 Diedplank: drink 0 for years (`classes.drink groups []`), 0 MISSING events, 6 citizens 'unknown, never found' far out (28619, 29260, 24165, 26277, 29619, 29261); i4 (with drink) emitted MISSING 4x.

## Root cause
`lua/dfllm/seal.lua` `M.job_stray`: `if nd == 0 or nf == 0 then return end` sat before stray_errands, hunt_errands and missing_watch.

## Fix
With no drink or food group the citizens' main walk group (`group_counts`) is the one to measure against (`good = {main}`); all three guards run. With drink and food the rule is unchanged.

## Tests
`tests/lua/test_bug876_stray_nodrink.lua` (a stray errand cancelled with no drink anywhere, control with drink).

## Live-Erwartung
On i1 (drink 0): kern.log 'HuntVermin ... cancelled: the vermin hunt leads him N tiles from the citizens inside' for far hunts and MISSING (A) for citizens farther than 40 tiles for 3 days (PROMISED offline). That the drowned citizens were drinking at the moment is not shown.
