# BUG-634 O1 lost three times (a no-op `bridge.rebuild` reset the count), `levers:O1` names no reason, `seal` says 'nothing to close' beside an open perimeter, the perimeter wanders
Status: fixed (offline, live-untested); open: no wall plan that closes the whole rim in one build, the raise/recall during a siege is not changed
Severity: medium
Found: 2026-11-10, Run 16d i4 Trumpetrealms y383-y437 (round 19 notes R7, R9, Z2, Z5; FR-BUGS 'O1 3. Mal zerstoert', 'levers:O1 nennt keinen Grund', 'Perimeter wandert')
Module: `lua/dfllm/seal.lua` (`bridge.rebuild`, `KP.ordinal`), `lua/dfllm/gate.lua` (`M.lever_why`), `lua/dfllm/readiness.lua` (`check_levers`, `M.state`), `lua/dfllm/util/contract.lua`, `dfpilot/schema.py`, `dfpilot/brief.py` (`line_unready`), `dfpilot/cmd.py` (`_open_other`, `_wander_note`, `seal_openings`)

## Actual
(a) O1 (the outer drawbridge) was destroyed by cave dragons at y383, y435 and y437; `perimeter.stop_after` is 2 and replaces a bridge by wall + door at the second loss to building destroyers, but the third loss was needed. R0 `levers:O1` stood for years after O1 was rebuilt without saying what its levers wait for. BREACH `O1 not up at T+900` with a citizen walking onto the bridge.
(b) Status said `perimeter open 37 days (levers lost O1)`, `seal at=last` said `nothing to close`. After every seal a new `floor way in` appeared (72,86 / 79,68 / 65,121 / 78,57 / 24,2,143); 27 seal projects finished in the run.

## Root cause
- (a1) `seal.lua` verb `bridge.rebuild` (M.verbs['bridge.rebuild']) stored `st.ans[name] = bd` even when no lost bridge waited for the order (cli.log: three calls, each `no lost bridge waits for a rebuild (lost 1 times, 1 with building destroyers); answer stored`). The stop rule counts `bd - st.ans` (KP.verdict): the second loss (bd 2 - ans 1 = 1 < 2) was rebuilt, the third replaced it. The kern.log of the third loss shows the rule firing (`replaced by wall + door (lost 3x ... y383,y435,y437)`), so the rule worked; the order moved it by one loss.
- (a2) `readiness.check_levers` knew only the count (`levers:<B>`); gate knew each lever's state (`lever_report`: none / site / built / job / linked) and the mechanisms (`economy.mech_free`), but no text reached the player. In i4 the new O1's levers were not linked again because the fort had no mechanism (`no non-economic hard stone`).
- (a3) The gate_fail at T+900: `gate: O1 raise held 450 ticks: only units on the footprint, within 2 steps or walking within 13 steps hold it` (citizens walking in over the bridge, by design, BUG-621); O1 was destroyed `last up, BREACH`, i.e. the dragons toppled the raised bridge: the hold did not cause the loss. Not changed.
- (b1) The open perimeter `levers lost: O1` is no way in. `cmd.seal_openings` only knew ways in (`ready.ents`, SIEGE_UNREADY, SEAL_LEAK) and said 'the last entrance check names no open way in'; status (`ready.pd`/`pw`) counts lost levers and bridges as open. Two readings of the same state, no word that they differ.
- (b2) Entrance detection and seal share the kernel's check (`seal.entrance_doors` -> `readiness.entrances` -> `ready.open`/`ents`; `cmd.current_openings`, BUG-322/374/455). What differs is the list length (ents 3, SIEGE_UNREADY 6, seal at most `SEAL_MAX`) and the age; the wandering itself is the surface changing (plants, new openings, `OPEN_CONFIRM` 2 days) and one door per wake outrun by it.

## Fix
- `bridge.rebuild` with no lost bridge waiting stores nothing and says `nothing stored: the counts stay, replaced by wall + door at the 2nd loss to building destroyers (1 so far)` (`KP.ordinal`); the order for a waiting lost bridge is unchanged (the counts start again from it).
- `gate.lever_why(name)`: `O1: 1 of 2 levers linked: lever x,y,z stands, not linked to this bridge (2 d, no link job); lever ... is placed, not built; 0 mechanisms free (no stone); last link refused: ...` (200 bytes); a destroyed bridge says so. `readiness` publishes it as state `ready.lw` while `levers:<B>` blocks (contract.lua, schema.py, CONTRACTS appendix); status/brief print `levers: <text>` after the blockers (`brief.line_unready`).
- `cmd._open_other`: `seal at=last` 'nothing to close' now says `the open perimeter (N d) is not a way in but 'levers lost: O1': a seal has no tile for it`, the lever reason and the way out (link the levers, `inspect what=defense`, the keeper replaces a lost bridge by wall + door). The answer stays a `SealClosed` (plan check passes it, plan apply leaves it out).
- `cmd._wander_note`: from 4 finished seal projects within 2 game years the seal answer (`close=auto` only) adds `the perimeter wanders: N seals ...` and offers `close=wall` (a constructed wall is no door the destroyers break; the kernel's reach check still applies) and `inspect what=entrances` / `seal at=audit`.

## Tests
`tests/lua/test_bridge_rebuild.lua` (+1: BUG-634 second loss replaced after a no-op order), `tests/lua/test_bug634_levers_why.lua` (2), `tests/test_bug634_f41_gate.py` (5). No siege-traffic test was added: nothing that raises, lowers or recalls was touched (the existing siege traffic tests of BUG-621/622, 564/568 and 478/481 pass).

## Live check
Trumpetrealms (or any fort with a lost lever): `dfllm status` shows `levers: O1: ...` with the lever states; `bridge.rebuild` on a standing bridge answers `nothing stored`; `seal at=last` with an open perimeter by levers names it; after 4 seals in 2 years the seal reply carries the `wanders` note.
