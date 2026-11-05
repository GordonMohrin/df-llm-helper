# BUG-485 `plan propose` warns "fair play: $.notes mentions 'aquifer'" about its own notes
Status: fixed (offline, live-untested)
Severity: low (a warning in every draft near an aquifer; the player had to check that it was a false alarm)
Found: 2026-11-05, Run 16a i1 Basementflew (FR-BUGS "plan propose Hinweis fair play: $.notes mentions 'aquifer'")
Module: `dfpilot/plan.py` (`fair_play_hits`, `_command_use`, `PROSE_WORDS`)

## Actual
The blocked terms (config/allowlist.json `blocked`: DFHack commands) include ordinary English words (`aquifer`, `plant`, `source`, `caravan`, `lever`, `reveal` ...); the plan's own BUG-130 / aquifer notes are prose, but `fair_play_hits` read every word of the notes.

## Root cause
`fair_play_hits` matched a blocked term anywhere in `notes` (whole-word match only; BUG-304 dropped just the plan's own trade-token runs).

## Fix
Words in the notes are not actions. `PROSE_WORDS` (the ordinary English words among the blocked terms) count in the notes only in command position (`_command_use`: right after dfhack-run / dfhack / dfllm / lua, inside backticks, after a `$ ` prompt); a tool name that is no everyday word (fastdwarf, digv, createitem ...) is flagged in the notes as before; every other plan string (build params, labels) is checked as before, an ERROR as before.

## Tests
`tests/test_bug482_486_f30misc.py` (prose is no command, commands and tool names are, build params still are), `tests/test_bug303_304_glass.py` (adapted: prose 'plant seeds' is no hit, `dfhack-run plant create` and a backticked `plant` are), `tests/test_cli_plan.py` (unchanged: 'fastdwarf' stays a warning).

## Live check
`plan propose` / `plan check` on a fort with an aquifer: no "fair play: $.notes mentions 'aquifer'" line.
