# BUG-846 `why <key> --raw` printed nothing and `inspect what=raw key=brew` exceeded 8 KB
Status: fixed (offline, live-untested)
Severity: medium
Found: 24.11. live look: the CLI printed nothing (exit 0) for `why brew --raw`; the reply was a `{trunc, bytes}` stub because the data was over the kernel's 8 KB reply limit.
Module: `lua/dfllm/dfraw.lua` (`R.find`, `R.paginate`, `R.brew`, `R.order`), `lua/dfllm/economy.lua` (`inspect.raw`), `dfpilot/cli.py` (`run_why`), `dfpilot/schema.py` (inspect `page`)

## Root cause
The truncated stub has no `lines`; `run_why` printed zero lines and returned 0. `R.brew` dumped 8 orders with full shop sheets.

## Fix
Dumps are cut into pages of at most 6,000 encoded bytes (`page` / `pages` in the reply, `--page N` in the CLI, inspect arg `page` 1..50); `brew` lists the orders first (2 in full, the rest one line, only the first shop of an order in full) and summarizes the Stills in one line each; an empty reply prints the kernel's message and exits 1.

## Tests
`tests/lua/test_neu4_cancel.lua` (paging, brew dump under 8 KB), `tests/test_neu4_cancel.py` (empty reply never silent, `--page` sent).

## Live-Erwartung
1. `python -m dfpilot why brew --raw` on a fort with 19 Stills / many orders prints the dump (page 1 of N) and 'page 1 of N: more with --page N'; `--page 2` prints the next page.
2. NOT promised: the line widths and field names of the real DF structs (still unverified offline; the dump prints `?`).
