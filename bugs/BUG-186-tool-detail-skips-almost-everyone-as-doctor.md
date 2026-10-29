# BUG-186 The tool details skip almost every citizen as a "doctor": SUTURING and DRESSING_WOUNDS are on by default in DF 53.16
Status: fixed (offline, live-untested)
Severity: high (no healthy miner could join; TOOL_BLOCKED for 1313 days)
Found: 2026-10-29, live test round 2, instances i1, i2, i3, i4 (NEW1), confirmed by the skeptic re-check
Module: `lua/dfllm/economy.lua` (`M.DOC_LABORS`, `M.tool_cand_skip`)

## Actual
BUG-128 skipped every candidate with a doctor labor on, including SUTURING and DRESSING_WOUNDS. DF 53.16 turns both on for nearly every citizen
(i4: 48 of 53 on, DIAGNOSE/SURGERY/BONE_SETTING 4 each). TOOL_BLOCKED #33355 `g` read `skipped pat 6 doc 29`: 1 eligible adult left.

## Fix
`M.DOC_LABORS = {DIAGNOSE, SURGERY, BONE_SETTING}`; a unit whose current job is a hospital job (`M.DOC_JOBS`: DiagnosePatient, Surgery,
SetBone, Suture, DressWound, ApplyCast, PlaceInTraction, CleanPatient) or who holds `CHIEF_MEDICAL_DWARF` (`M.DOC_POS`) is a doctor too.

## Tests
`tests/lua/test_economy_tools_b128.lua` BUG-186: 22 citizens with both default labors on: four miners join, the one suturing right now does not;
BONE_SETTING and the chief medical dwarf are skipped (fails on b805745).

## Live check
At the next TOOL_BLOCKED or a dig backlog: `d.g` `skipped pat N doc M` with M about the number of real doctors (i4: 4), and a `WORK_DETAIL Miners +`.
