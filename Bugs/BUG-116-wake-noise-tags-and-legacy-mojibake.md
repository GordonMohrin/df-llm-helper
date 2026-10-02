# BUG-116: `wake` raises "WAKE critical" for harmless message types (VOMIT, RESOLVE_SHARED_ITEMS, DODGE_FLYING_OBJECT, NO_BREAK_GRIP, MASTERPIECE_CRAFTED) and prints legacy mojibake

- **Status:** fixed in 626d04f
- **Severity:** S3 (noise; the purpose of `wake` is "no wake-up without need for action")
- **Area:** `df_llm_helper/wake.py:31-33` (`NOISE_TAGS`, matched with `.match(tag)` = prefix only), `df_llm_helper/waechter.py:35-39` (`CRITICAL` regex matches words like `goblin`/`thief` anywhere in the text), `df_llm_helper/toolsfs.py:137-140`
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3; samples are verbatim lines of the live `dwarf-fortress/tools/events.log` (4326 lines, written Sept.-Oct. 2026 by the PowerShell watcher)

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-116/repro.py          # baseline wake on an empty log, then the 9 sample lines
```

## Expected
Combat details, item bookkeeping, vomiting and artwork announcements do not wake the orchestrator; names are readable.

## Actual
`wake` prints one `WAKE critical [...]` line per distinct text for these tags (live log excerpts, `sample_events_from_live_log.txt`):
```
WAKE critical [VOMIT]: The goblin thief vomits.
WAKE critical [RESOLVE_SHARED_ITEMS]: The goblin spearman gains possession of the ({silver spear}).
WAKE critical [DODGE_FLYING_OBJECT]: The goblin Pikemaster jumps out of the goblin Pikemaster's flight path!
WAKE critical [NO_BREAK_GRIP]: The goblin hammerman is unable to break the grip of ...
WAKE critical [MASTERPIECE_CRAFTED]: Ral Stukosidräth has created a masterpiece ☼cherry wood figurine of goblins☼!
```
Statistics of the real log (`live_events_log_tag_statistics.txt`): 4001 CRITICAL/KRITISCH lines in 54 tags; 10 VOMIT, 5 RESOLVE_SHARED_ITEMS, 2 DODGE_FLYING_OBJECT, 1 NO_BREAK_GRIP, 2 MASTERPIECE_CRAFTED would wake (each line has different text -> not de-duplicated).
On the live game a single `wake` (after the state was reset, see BUG-103) produced ~100 such lines; the real wake-ups (AMBUSH_*, UNDEAD_ATTACK, BERSERK_CITIZEN, CITIZEN_DEATH x38) are buried between them.
Root causes: (1) the watcher marks a message CRITICAL if its *text* contains `goblin|thief|...` (`waechter.CRITICAL`), so a goblin figurine is "critical"; (2) `NOISE_TAGS.match(tag)` is anchored at the start, so `NO_BREAK_GRIP` is not matched by `BREAK_GRIP`, and `VOMIT`, `RESOLVE_SHARED_ITEMS`, `DODGE_FLYING_OBJECT` are simply missing.

Second symptom (S3): lines written by the old PowerShell watcher contain CP437 mojibake of UTF-8 (`├«ton Uristelbel`, `Γÿ╝bronze figurine of goblinsΓÿ╝`, 40 lines in the live log) and `wake` prints them unrepaired,
although `journal.fix_mojibake()` exists (`journal.py:44`). (Printing them also triggers BUG-112 on a cp1252 console.)

## Evidence
`Bugs/evidence/BUG-116/repro.py`, `output.txt`, `sample_events_from_live_log.txt`, `live_events_log_tag_statistics.txt`.

## Analysis (reporter's hypothesis)
Decide by *tag* (an allow-list of alarm tags: `AMBUSH_*`, `UNDEAD_ATTACK`, `BERSERK_CITIZEN`, `CITIZEN_DEATH`, `CITIZEN_TANTRUM`, `FEATURE_BEAST`, `GUARD`, `PERF`, ...) instead of a deny-list; keep `NOISE_TAGS` as a fallback with `search`.
In `waechter.py` classify with the tag too (do not match words in the free text for `MASTERPIECE|VOMIT|DODGE|...`). Apply `fix_mojibake` to the printed text.

## Suggested fix (optional)
As above; add the 9 sample lines as a test (`wake` must print only the 2 `CITIZEN_DEATH` lines).

## Info needed
Gordon / cloud session: which tags should wake the orchestrator? Candidate allow-list from the statistics file: AMBUSH_SNATCHER, AMBUSH_SNATCHER_SUPPORT, AMBUSH_AMBUSHER_NATURE, UNDEAD_ATTACK, CITIZEN_DEATH, BERSERK_CITIZEN, CITIZEN_TANTRUM, GUARD.

## Fix
`NOISE_TAGS` matched with `search` (so `NO_BREAK_GRIP` is noise) and extended by `VOMIT`, `RESOLVE_SHARED_ITEMS`, `DODGE_FLYING_OBJECT`, `MASTERPIECE_CRAFTED` (these four are not even counted as combat noise); printed text goes through `fix_mojibake` (+ the `Γÿ╝` = `☼` case). Unknown tags still wake (fail-safe deny list; the allow-list question stays with Gordon). Test with the 9 live sample lines: only the 2 `CITIZEN_DEATH` lines wake.
