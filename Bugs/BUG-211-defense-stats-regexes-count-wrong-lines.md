# BUG-211: `defense stats` counts job-cancel and sparring lines as trap/attack messages, reads the whole 146 MB gamelog on every call (10 s), and prints a false `!!` alarm; `--tail` accepts 0/negative values

- **Status:** reopened (retest 2026-10-02): 'siege'/'thief' still match combat lines ('troll siege engineer', 'goblin thief'): 273 of 283 invasion announcements are false
- **Severity:** S2 (meaningless numbers + false alarm "enemies bypass the lane? check claude/zugaenge")
- **Area:** `df_llm_helper/features/defense.py` `gamelog_stats` (regexes `\btrap\b`, `caught|cage`, `load`, `siege|ambush|vile force|attack`), `_stats` (`read_text().splitlines()`, `if args.tail:`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, paused), fort date 27. Granite, Jahr 118; `E:\...\Dwarf Fortress\gamelog.txt` = 146,562,292 bytes

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper defense stats
python -m df_llm_helper defense stats --tail 500
python -m df_llm_helper defense stats --tail -5
python -m df_llm_helper defense stats --tail 0
```

## Expected
Only real trap events are counted (a trap fired / a creature was caught); attack lines mean enemies attacking the fort, not wrestling between soldiers; runtime does not depend on the file size; a negative or zero `--tail` is rejected.

## Actual
```
$ python -m df_llm_helper defense stats                (10.7 s)
Defense stats (gamelog): trap lines 7994 (caught 7970, hits 0, load messages 7935), attack lines 110595
$ python -m df_llm_helper defense stats --tail 500
Defense stats (gamelog): trap lines 0 (caught 0, hits 0, load messages 0), attack lines 75
!! attacks without any trap message: enemies bypass the lane? check `claude/zugaenge` (spec v3-01)
$ python -m df_llm_helper defense stats --tail -5      (10.2 s: counts everything except the first 5 lines)
$ python -m df_llm_helper defense stats --tail 0       (10.5 s: = no tail)
```
Sample of the matched lines (`Bugs/evidence/BUG-211/gamelog_samples.txt`): the "trap lines" are `Nil Zanegetest, Miner cancels Load cage trap: Needs empty cage.` (matches `trap`, `cage` -> "caught", `load` -> "load message"); the "attack lines" are `The wrestler attacks the militia captain but She jumps away!` (sparring) and `The siege operator latches on firmly!`. `defense status` itself looks right (58/58 stone traps loaded, cage 4, lever 1, weapon 18 = 81 traps = `claude/buildings` `Trap: 81`).

## Evidence
`Bugs/evidence/BUG-211/` (outputs, `gamelog_samples.txt`).

## Analysis (reporter's hypothesis)
The regexes were written without real message texts ("Message texts are NOT verified live" in the docstring). Real DF texts to use instead: trap events look like `... is caught in a cage trap`/`... is struck by`/`The stone-fall trap ...` (needs verification against a real attack; none in this gamelog); invasion messages are announcements such as `[AMBUSH_*]`/`siege` markers (see `alert.flag`: `[AMBUSH_SNATCHER] Snatcher! Protect the children!`). Exclude lines containing `cancels`, `suspended the construction`, `attacks the` + `but .* jumps away` (sparring).

## Suggested fix (optional)
Stream the file from the end (seek to the last N MB), cap `--tail` to >= 1, use `^`-anchored/announcement-based patterns, count `cancels Load .* trap` separately as "reload problems".

## Info needed
Gordon / next real attack: please copy 20 gamelog lines around a trap firing (`caught in a cage trap`, `... stone-fall trap ...`) and around the arrival of an invasion into `Bugs/evidence/BUG-211/` so the cloud session can write the real patterns. Not testable without time running.

## Fix
`gamelog_stats`: job lines (`cancels`, `Load ... trap`, suspend/construction) are no trap events; `cancels Load ... trap` counts as `reload problems`; attacks = invasion announcements only (vile force, ambush, siege but not `siege operator`, snatcher, thief, ...), sparring is ignored; the file is read from the end (last 8 MB), `--tail` must be >= 1. Test: `test_bug211_*` (`fixtures/bugs/BUG-211/gamelog_samples.txt`). Info still welcome: real trap/invasion lines of the next attack to verify the patterns.

## Retest 2026-10-02
Run against the live gamelog (read only, 146 MB file): runtime 1.7 s (was 10 s), `--tail -5` / `--tail 0` refused (rc 2), job-cancel lines are `reload problems 2`, sparring ignored. Still wrong: the invasion pattern matches ordinary combat lines.
```
$ python -m df_llm_helper defense stats --gamelog "<gamelog.txt>"
Defense stats (gamelog): trap events 0 (caught 0, hits 0), reload problems 2, invasion announcements 283
!! invasion without any trap event: enemies bypass the lane? check `claude/zugaenge` (spec v3-01)
```
Matches in the last 8 MB by pattern: `siege` 223 (e.g. "The militia captain hacks the troll siege engineer in the right foot ..."), `thief` 50 ("The spinning rock salt misses the goblin thief!"), real announcements: `an ambush` 7, `snatcher` 2, `vile force` 1. Suggested: anchor on announcement texts only ("A vile force of darkness has arrived", "An ambush!", "Snatcher!  Protect the children!", "... have come") and drop the bare `siege`/`thief` words.
