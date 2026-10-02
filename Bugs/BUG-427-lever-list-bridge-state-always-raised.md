# BUG-427: `lever list` shows drawbridges always as "raised"; the real state is `gate_flags.raised`

- **Status:** open
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
