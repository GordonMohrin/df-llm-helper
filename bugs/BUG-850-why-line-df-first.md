# BUG-850 `why brew` / `why <key>`: DF's reason was not the first thing of the line; `why ws:<id>` knew no stockpile
Status: fixed (offline, live-untested)
Severity: low
Found: Run 17d i4 Girderroots, 24.11.2026 (lead's live look): `why brew` printed the job kind and cause first and DF's words only inside the text; `why ws:<stockpile id>` answered 'no workshop or furnace'.
Module: `lua/dfllm/jobwhy.lua` (`J.line`, `J.find0`, `J.attach_df`)

## Fix
`J.line` starts with the DF line ('DF cancelled brew drink from plant 412x in 7 d: Needs empty food storage item (last 2 d ago) | order 5358 ...') when the result carries `df`, and the text no longer repeats it; without a DF reason it ends with the reader's health (BUG-847). `why ws:<id>` on a stockpile id says 'building <id> is a stockpile, not a workshop: why <id> --raw (key pile:<id>) dumps it'.

## Tests
`tests/lua/test_bug847_848_reader_pile.lua` ('item 4', 'BUG-848 raw dumps'); the BUG-841 tests still pass unchanged.

## Live-Erwartung
`python -m dfpilot why brew` on i4 starts with 'DF cancelled brew drink from plant ...' once the tally has entries (BUG-847); `why ws:<stockpile id>` names the pile dump.
