# BUG-111: digest drops inbox lines beyond the display limit for good; the hint "+N more inbox lines (... bus read)" points to a place where they are not

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S2 (an agent message such as "caravan is here" can be lost without trace)
- **Area:** `df_llm_helper/digest.py:210-243` (`inbox_items`: all fresh lines go into `new_hashes`, only `max_lines` are shown, the rest only counted in `skipped`), `digest.py:319` (hint text), `df_llm_helper/pilot.py:129-134` (`bus_lines`)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, mock `fixtures/run5` + temp folder (no game needed). Live observation: `digest --scope essen/trinken/gesundheit` showed 5 inbox lines each from markdown inboxes written in the morning.

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-111/repro.py
```
A `tools/scopes/inbox-orchestrator.md` with 10 messages (`- von <scope>, HH:MM: text`, the legacy path still documented in MANUAL section 3/6), then `digest`.

## Expected
Either all new messages are shown (they are the only way a scope agent talks to the orchestrator), or the omitted ones stay *unseen* and appear in the next digest / can be listed with the command named in the hint.

## Actual
```
> a 12:39: a7  ... > a 12:34: a2                           (6 shown, newest first)
> +4 more inbox lines (python -m df_llm_helper bus read)
$ bus read --to orchestrator        ->  no unread messages for orchestrator
$ digest                            ->  No change since 12:21 (2 open: Caravan, Hunger).
$ digest --full                     ->  (inbox is not part of --full)
```
The 4 omitted lines (`Tunnel fertig`, `KARAWANE IST DA, bitte handeln`, `Vorrat 20 Tage`, `a1`) were marked as seen (`inbox_seen`) when the digest was built and are never shown again.
`bus read` cannot return them because markdown inbox lines are not in the bus; only a manual `bus import` (not mentioned anywhere in the hint) copies them (all 10 again, including the 6 already shown).
Truncation is also "newest first", so the *oldest* - often the first, most important - message is the one that is dropped. With the bus path (`bus post`) the same happens in `bus_lines()`: `bus.read()` marks messages read (limit 50) and the digest then truncates them.

## Evidence
`Bugs/evidence/BUG-111/repro.py`, `output.txt`.

## Analysis (reporter's hypothesis)
`inbox_items` returns `new_hashes` for every fresh line, including those not shown. Only the shown ones should be remembered (`seen`), the rest should stay pending, or be stored into the bus (`bus.post`) so that the hint is true.
The bus read in `bus_lines` has the same consume-before-show problem.

## Suggested fix (optional)
Add only displayed hashes to `inbox_seen`; show "+N more (still unread; call digest again or `bus read`)". For the bus: `bus.read(limit=n_display)` instead of 50, or ack only the shown ids.

## Info needed
Cloud session: is `digest.inbox_max_lines` = 6 meant to be a hard cap per call? If yes, the remainder must stay pending until the next call.

## Fix
`inbox_items` remembers only shown lines (and text duplicates of them); omitted lines and lines cut by the token budget stay unread and come with the next digest (`> +N more inbox lines (still unread: shown by the next digest)`). Bus messages are read without marking and only the shown ones are marked read. Decision for the Info question: `inbox_max_lines` is a per-call cap with carry-over. Tests: `test_bug111_*`, adapted `tests/test_digest.py`/`tests/test_scenarios_cli.py`.
