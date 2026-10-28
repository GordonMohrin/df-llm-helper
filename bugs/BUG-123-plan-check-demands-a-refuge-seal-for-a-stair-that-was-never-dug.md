# BUG-123 `plan check` demands `seal at=refuge` as the first build for a manifest stair on undug, unrevealed rock; the seal then fails with "the tile is not revealed" and every build including the hospital is blocked
Status: fixed (offline, live-untested)
Severity: high (wrong decision: the hospital stayed unbuilt, only an empty plan could be applied)
Found: 2026-10-28, Run 14 (y710), game session note 102 and its Nachtrag
Module: dfpilot/cmd.py (refuge_stair, seal_openings), dfpilot/plan.py (refuge_projects, refuge_gate), lua/dfllm/seal.lua (refuge_stair, refuge_trust)

## Actual
y710 Spring d1 (Run 14, pop 12): `plan check` ERROR "refuge: the civilians' stair enters Tiefe+ below 77,68,125 without a hatch ... add
{"tpl":"seal","site":"S1","p":{"at":"refuge"}}" as the first build before any other (the hospital too). The seal itself failed
(`bp.sites.rank(seal): ... hatch at 77,68,125: the tile is not revealed`). The player looked in the game: 77,68,125 was undug,
unrevealed rock, there was no stair. Later a stair was built there and the check worked.

## Cause
`cmd.refuge_head` read the stair head only from the fort manifest (refuge anchor + `stairs.civ`), never from the map. A manifest entry
without a stair on the map (a fragment of a plan that was never dug, or a save older than the manifest, note 101) stayed a head for
ever: `seal_openings` took the entry kind where the snapshot said `?`, `plan.refuge_projects` set `head_open`, `refuge_gate` made it an
ERROR. The kernel did the same: `seal.refuge_trust` wanted a hatch at the manifest head (`no hatch at ...`, R0 `refuge_trust`).

## Fix
`cmd.refuge_stair` (and the Lua twin `seal.refuge_stair`) read the head on revealed tiles only (fair play: nothing is revealed): state
`nostair` when the head tile is revealed and no stair, or nothing of the stair column is revealed as a stair. `plan check` warns
`refuge: no stair found (not dug) at the manifest's stair head x,y,z; the stale manifest entry is kept, no hatch is demanded`, never an
error; the manifest is not edited (the entry is flagged: `inspect what=refuge` `trust.hatch.state = nostair`); `seal at=refuge` for it
is a `SealClosed` (plan check passes it with a note, plan apply leaves its blueprint out); the kernel's `refuge_trust` asks for no
hatch. Tests: `tests/test_refuge_stair_102.py`, `tests/lua/test_seal_refuge.lua` (BUG-123).

Related: BUG-031, BUG-049, BUG-047, note 101 (TIMELINE_RESET), BUG-123, BUG-124, BUG-125
