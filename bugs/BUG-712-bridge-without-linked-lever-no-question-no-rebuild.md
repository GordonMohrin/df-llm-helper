# BUG-712 A bridge with no linked lever at all: nobody asked, nothing rebuilt the levers
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-10, Run 16b i2 Whirledrampart y430 (GATE_FAIL 'B2 not up after 715 ticks (no_lever)', 'O1 not up after 900 ticks (no_lever)' at every siege, SIEGE_START 'siege again (bridge_stuck): B2: no_lever; O1: no_lever' flickering with BREACH; inspect defense 'B2: 0 of 3 levers linked, lever 122,134,140 stands, not linked (1672 d, no link job)'; DECISION 'bridge B1: no linked lever inside the refuge' (E20); the manifest's Mechanics workshop 'no longer stands', DF refused the rock jobs ('Needs non-economic hard stone'), ACT_FAIL 'needs 2 free reachable mechanisms, 0 found')
Module: `lua/dfllm/gate.lua` (`M.lever_states`), `lua/dfllm/readiness.lua` (`ask_leverless`, `ready.ll`), `lua/dfllm/economy.lua` (`M.mech_need`), `dfpilot/bp/fortcore.py` (`_lever_retrofit` kind 3), `dfpilot/brief.py`, `dfpilot/schema.py` + `lua/dfllm/util/contract.lua` (`ready.ll`)

## Root cause
`gate.refuge_gaps` (readiness.lua `request_audit` -> `rt.rlg`, `ask_reflevers`) lists only bridges that HAVE a linked lever but none inside the refuge ("levers: is readiness' own blocker"). A bridge with no linked lever at all (B2, O1) was the R0 blocker `levers:<B>` and nothing else: no DECISION_NEEDED named it, so the question named only B1, and its command (`retrofit=2`) builds only the refuge levers, never the main levers at the Z3 / Z4 strips (the ones that had gone). `economy.mech_need` counted 2 mechanisms per unlinked lever and none for a lever that is placed and not built (1 each).

## Fix
- `gate.lever_states(K)`: per manifest bridge ALL manifest levers by state (`n, none, site, built, job, linked, age, stale, why`), like `refuge_levers` but not limited to the refuge.
- readiness: `ready.ll` = the bridges of the R0 `levers:` blocker with no linked lever (PEACE); `ask_leverless`: DECISION_NEEDED `bridge_levers` (A) every `DEF.ask_days` (30) days, with `d.cause` none (no lever stands: command `bp.place tpl=fortcore site=same stage=3 retrofit=3`), unbuilt, unlinked (free mechanisms, last refusal), link_job / link_stale; a fort that cannot make a mechanism gets the cause first (no hard stone, no stone, no Mechanics workshop) with the caravan command. brief shows `NO LINKED LEVER on B2,O1`.
- fortcore `retrofit=3` (stage 3): the rooms, the six main levers and the three refuge levers (`retrofit=2` plus the main ones); a lever that stands is skipped by quickfort, the manifest fragment is the same.
- `economy.mech_need` adds one mechanism per lever that is placed and not built.

## Tests
`tests/lua/test_bug712_714_levers.lua` (none / unlinked / control), `tests/test_bug712_714_levers.py` (retrofit=3 tiles, manifest, param range, schema).

## Live check
`ready.ll` and a `bridge_levers` DECISION_NEEDED in a fort with a lever-less bridge; `bp.place ... retrofit=3` puts six more `Tl` sites. Open: no mechanism can be made without hard stone and a Mechanics workshop: the question names it, the kernel does not dig for stone itself; a bridge with no lever that cannot be fixed still has no gate (siege keeps its `bridge_stuck` fallback).
