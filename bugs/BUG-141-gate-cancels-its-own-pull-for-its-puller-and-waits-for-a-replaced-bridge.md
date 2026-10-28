# BUG-141 gate cancels its own lever pull because the puller stands next to the bridge (100 pulls, no GATE_FAIL), and keeps wanting a bridge seal replaced
Status: fixed in the fix-live-siege commit (offline, live-untested)
Severity: high (endless lever jobs; BREACH waits for a bridge that does not exist)
Found: 2026-10-28, live test instance i3 (E:/DF-test3, region2-site90 Trussroads y717), workflow wf_190bd773-8de, confirmed by its verifier
Module: lua/dfllm/gate.lua (`control`, `M.giveup`, `M.not_up`, MODE handler)

## Actual
- 100 LEVER `pull X25718 up` events about 200 ticks apart (36 in one BREACH), no GATE_FAIL `no_effect`, no LEVER_NOEFFECT. Lever 25729 at
  108,100,131 lies two tiles from the footprint 110-112,100,131; the worker 41696 stood at 109,99, and kern.log said
  `gate: X25718 up still waits for citizen 41696 next to it`.
- B1, replaced by a wall and a door (inspect defense `B1 replaced/-`), stayed in `gate.not_up` (`why=no_lever`): BREACH `waiting for B1 up:
  no_lever`, GATE_FAIL `B1 not up after 902 ticks (no_lever)` each epoch.

## Cause
- `holders()` counted the job's own worker (within `M.MARGIN` 1 of the footprint) as a unit holding the raise; the pending pull went stale
  `blocked` and was cancelled by gate itself. That path never reached `M.noeffect`, so `gate.pull_cap` (BUG-114) never fired.
- `set_want`, `M.not_up` and the MODE handler skip only `st.gone`; `gone_check` marks a bridge gone only when gate once saw it complete, and B1
  was replaced before this timeline.

## Fix
- The pending pull's current worker next to the footprint (not on it) holds nothing. Pulls cancelled for units on or next to the footprint
  count per bridge and mode; after `gate.pull_cap` of them the BUG-114 give-up parks the levers for `gate.giveup_wait` and GATE_FAIL (A)
  `why blocked` with `pulls`, `wait`, `units`, `lever` names who stood there; `not_up` says `blocked: N pulls, no pull for M more ticks`.
- A manifest bridge `seal.replaced` lists, with no bridge on its footprint, is gone for gate (`st.gone`, no want, no pull, no GATE_FAIL,
  not in `not_up`, no BRIDGE_DESTROYED); a bridge built there again lifts it as before (`rebuilt`).

## Tests
`tests/lua/test_bug141_gate_puller.lua` (3, all fail on dec5132).
