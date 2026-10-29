# BUG-249 curse check greps the werecavy lines of an older fort in the same gamelog
Status: fixed (offline, live-untested)
Severity: low (a false curse alarm, or a real one missed among old lines)
Found: 2026-10-29, Run 15 Guildcleans (E:/DF-test2): three "transformed into a werecavy" at gamelog lines 93143-94588, all
before this fort's embark at line 94803
Module: `dfpilot/cli.py` (`dfllm gamelog`, `gamelog_since`, `run_gamelog`); PLAYBOOK.md (dwarf-fortress-v2) curse line

## Actual
PLAYBOOK step 2 runs `tail -c 3000000 gamelog.txt | grep -E "has been cursed|transformed into a were|vampire"`. DF appends
every game of an install to one gamelog.txt, so the tail held the previous fort's curse lines.

## Fix
`dfllm gamelog [--since-embark] [--marker TEXT] [--grep RE | --curse] [--tail N]` reads `<DF>/gamelog.txt` (CP437) without a
fort runtime; `--since-embark` keeps only the lines after the LAST embark line ("Strike the earth!" or "*** STARTING NEW GAME
***", case-insensitive; `--marker` overrides) and says when none was found; `--curse` = the PLAYBOOK pattern. Output: the
line count, the embark line, the number of matches and the newest N matches with their line numbers.

## Tests
`tests/test_bug245_250_embark_tools.py::test_bug249_...` (an old fort's werecavy before "Strike the earth!" is skipped; without
`--since-embark` it is found; `--marker`; missing file). Fails on 6dc0f19.

## Live check
`python -m dfpilot gamelog --since-embark --curse` in a DF folder that held an older fort (E:/DF-test2): the header names the
embark line of this fort; no line of the old fort is listed. If it says "no embark line found", read the gamelog line written
at the embark and pass it with `--marker`. PLAYBOOK step 2 should switch to this command (dwarf-fortress-v2, not part of this
branch).
