# BUG-187 A long-term patient holds a tool detail seat for good, and the diagnosis blames walk groups (BUG-128d)
Status: fixed (offline, live-untested)
Severity: high (the miners' second seat stayed with a resting patient for 1313 days)
Found: 2026-10-29, live test round 2, instance i4 (BUG-128d PARTIAL, NEW2), confirmed by the skeptic re-check
Module: `lua/dfllm/economy.lua` (`tools` cur loop, `tool_check`, `M.td_blockers`, `M.tool_tell`, `M.tool_guards`, new `M.tool_long_patient`)

## Actual
Miners = 42191 (pick) and 42435 (needs_healthcare, job Rest, no pick). TOOL_BLOCKED #33355: bk `jobs` ("can take none of the open dig jobs"),
in #33220 `none`. Every eligible adult counted as a member, so with `#cur == target` no join and no drop happened; `M.patient` was used only for
candidates.

## Fix
1. `M.td_blockers`: key `patient` ("N of M are patients (needs healthcare / Rest): they fetch no pick and take no job (id)") before `jobs`; a
   patient no longer counts as a `jobs` blocker. `tool_tell` says to take him off the detail.
2. `M.tool_long_patient`: a member who is a patient and has lacked the tool for `tools.block_days` (p.tblk `ms`, first seen without it). The
   kernel's own one goes off the detail (WORK_DETAIL `-` why `patient`), a player's one stays but does not count; either way a healthy
   candidate joins. The player's one keeps his first-seen tick (no flip-flop); TOOL_BLOCKED `d.g` says `patient members not counted N`.

## Tests
`tests/lua/test_economy_tools_b128.lua` BUG-187: td_blockers gives `patient`, not `jobs`; a kernel-added patient goes after block_days and the next
best joins; a player's patient stays uncounted for 16 days while 7 joins, d.g names him (fails on b805745).

## Live check
i4: within a few days the Miners lose 42435 (WORK_DETAIL `Miners - ... (patient, ...)`) or, if the player put him there, a healthy miner joins
beside him; a TOOL_BLOCKED that still fires has bk `patient` while a patient is a member.
