# BUG-124 a real refuge stair whose hatch tile is not revealed makes the seal fail ("the tile is not revealed") with no way out for the player
Status: fixed (offline, live-untested)
Severity: medium (a dead end: the seal was demanded and not plannable, the player had no hint what to do)
Found: 2026-10-28, Run 14 (y710), game session note 102 and its Nachtrag
Module: dfpilot/cmd.py (refuge_stair), dfpilot/bp/sites.py (_seal), lua/dfllm/seal.lua (refuge_stair, hatch_ask)

## Actual
Note 102 wanted: when the hatch tile is not revealed, move the hatch to the nearest revealed tile of the same stair, or ask the player to
look at the tile (DECISION_NEEDED). The seal ranking only said "hatch at x,y,z: the tile is not revealed".

## Fix
- State `moved`: the head tile is not revealed, another tile of the same stair above the refuge level is: `seal at=refuge` closes the
  nearest revealed one (`cmd.refuge_head` returns it, `plan check` demands the seal there and warns "hatch moved to ..."); the kernel
  (`seal.refuge_trust`) wants the hatch there too (`trust.hatch.man` keeps the manifest's tile).
- State `hidden`: the stair is real (its refuge-level tile is a revealed stair) but no tile for the hatch is revealed: `plan check` warns
  (never an error) and the kernel raises one `DECISION_NEEDED refuge_hatch` (`util/cadence`: a game month and 30 min, again only for a
  changed tile) asking the player to look at the tile in the game; `refuge_trust` says `hatch tile x,y,z not revealed`, no R0 blocker.
- `bp.sites._seal`: the message names the tile, the snapshot id and what to do (`look at the tile in the game, then dfllm bp sites seal
  --fresh; never reveal it by tool`).
Tests: `tests/test_refuge_stair_102.py`, `tests/lua/test_seal_refuge.lua` (BUG-124).

Related: BUG-031, BUG-049, BUG-047, note 101 (TIMELINE_RESET), BUG-123, BUG-124, BUG-125
