# BUG-176 A unit name longer than 40 bytes (an epithet in quotes) is cut inside the quotes: the curse record never matches
Status: fixed (offline, live-untested)
Severity: medium (a phantom were-form for a dead unit in status and curse_kill; a false bite=1)
Found: 2026-10-29, live test round 2 i2 (NEW8-long-name-truncation; 42235 'Kumil Akrulonam Dalkamennol Kadol "Tinshimmer the Lean
Reputation of Gems", Werecavy Planter')
Module: `lua/dfllm/care.lua` (`M.full_name`, `M.curse_env`), `lua/dfllm/curse.lua` (`M.look`, `M.finish`)

## Actual
care's `uname` cuts getReadableName to 40 bytes; the cut fell inside the quoted epithet, so the nickname strip failed and the index key was
'kumil akrulonam dalkamennol kadol "tin'. The report's record stayed 'n:<name>' (dead unit never forgotten); `M.finish` resolved such records by
the 28-byte display name `r.n`, which could never match either.

## Fix
- The curse library gets `care.full_name` (the whole readable name, UTF-8) and cuts only what it shows.
- `M.look` keys the record by the whole name (and the real-name key of BUG-173); `M.finish` resolves a name record by its key, not by `r.n`.

## Tests
`tests/lua/test_curse_live2.lua` BUG-176: an 85-byte name: TRANSFORM carries his id, no unresolved record, his death clears the state (fails on b805745).

## Live check
`dfllm cmd inspect '{"what":"curse"}'` lists no 'by name only' record for a cursed unit with a long epithet name; after such a unit dies
status no longer counts him 'in were-form'.
