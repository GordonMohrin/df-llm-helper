# BUG-427: `lever list` shows drawbridges always as "raised"; the real state is `gate_flags.raised`

- **Status:** fixed in 795f73b
- **Severity:** S2 (wrong state shown; automation reading it decides wrongly about the defence line)
- **Area:** `lever list` (Lua side of `lever`), `defense`, `pilot_*` scripts that read the bridge state
- **Reported:** 2026-10-03, commit `841361d`
- **Environment:** Windows 11, game running (DF 53.16 + DFHack), Run 5, after the second invasion

## Command / steps
```
python -m df_llm_helper lever list
python -m df_llm_helper lever pull --id 4407
```
1. `lever list` for a lever linked to a drawbridge: output says "raised" regardless of the real state.
2. `lever pull --id N` toggles the bridge (up <-> down), but the list keeps saying "raised".
3. The real state is in `gate_flags.raised` of the bridge building.

## Expected
`lever list` (and `defense` / `pilot_*`) read `gate_flags.raised` of the linked building.

## Actual
Always "raised". Live confirmed by the orchestrator: lever 4407 toggles bridge 4406; linking in Lua works (FP10: mechanisms via `moveToBuilding`). In the night of the second invasion the bridges were up.

## Evidence
none recorded as raw files.

## Analysis (reporter's hypothesis)
The state shown does not come from `gate_flags.raised` of the building.

## Suggested fix
Read `bld.gate_flags.raised` for bridges, print `raised`/`lowered`; document that `lever pull` toggles; add `lever set --id N --state raised|lowered` that pulls only if the real state differs. Update `defense`/`pilot_*` readers.

## Acceptance (fixture based)
Fixture bridge with `gate_flags.raised = false` -> `lowered`; with `true` -> `raised`; `lever set` does not pull when already in the target state.

## Info needed
Raw output of `lever list` plus `gate_flags` of the bridge before and after a pull.

## Fix
The `lever` command the orchestrator used was not part of the repo (no `lever` code existed here), so it is added with
the state read from the right place:

- `lua/pilot_lever.lua` (new, installed as `claude/pilot_lever`): `list` (read only) follows each lever's
  `linked_mechanisms` -> `BUILDING_TRIGGERTARGET` ref -> target building and reads the state FROM THE TARGET:
  bridge `gate_flags.raised` (fallback `gate_flags.closed`, field name reported) -> `raised`/`lowered`, `moving` while a
  raising/lowering/opening/closing flag is set; floodgate `gate_flags.closed`, door/hatch `door_flags.closed` ->
  `closed`/`open`. Also the lever's own `state` and queued PullLever jobs. `pull <id>` queues one PullLever job (the
  UI's "Pull the lever"; it toggles), refused while one is queued. `set <id> raised|lowered|open|closed` pulls only
  when the linked targets are not in that state; no pull when already there, while a pull is queued, while a bridge
  moves, or when linked targets disagree.
- `python -m df_llm_helper lever list|pull --id N|set --id N --state S` (`df_llm_helper/features/lever.py`;
  `--file` for a recorded list). `claude/pilot_lever list` is registered as a pure read.
- `defense status` adds `Bridges: #4406 lowered` from `pilot_lever list` (silent when the script is missing).
- Docs: `docs/manual-v3/08-defense.md`.
- Tests: `tests/test_lua_claude.py` (`test_bug427_*`: `raised=false -> lowered`, `true -> raised`, `closed` fallback,
  moving; `set` does not pull when already in the target state, pulls once otherwise, not while a pull is queued),
  `tests/test_lever.py` (lines, Python mirror of the set rule, CLI list/set/pull, defense bridge line).

## Info needed (live check)
After `install-lua --apply`: `python -m df_llm_helper lever list` with bridge 4406 up, then
`lever pull --id 4407`, wait until a dwarf pulled, `lever list` again: the state must flip and the `field` must read
`gate_flags.raised`. If it says `gate_flags.closed` or `?`, record `dfhack-run lua "printall(df.building.find(4406).gate_flags)"`
before and after the pull (the DF 53 flag name decides the fallback order).

