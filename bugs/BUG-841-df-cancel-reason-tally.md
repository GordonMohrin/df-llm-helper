# BUG-841 DF's own cancel reason was never read: the kernel judged stalls by 'no job yet' and guessed the cause
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i2 Whirledrampart / i1 Diedplank, 24.11.2026 (live look by the lead): DF's gamelog.txt holds 86,405 x 'cancels Brew drink from plant: Needs empty food storage item.' (i2) and 2,729 x the same plus hundreds of 'Make wooden door / bucket / cabinet / crafts: Needs logs.' (i1). The jobs EXIST and DF cancels each with a reason; `dfpilot why` said 'unknown', brew_watch said 'by my count', the ladder said 'build a Still'.
Module: `lua/dfllm/cancelwhy.lua` (new), `lua/dfllm/economy.lua` (`cancel`, `M.cw_tally`, `M.cw_note`, `M.df_reason`, `M.df_count`, `M.cx_reason`, `M.df_text`, `brew_watch`, `drink_why`, `jw_ctx`), `lua/dfllm/jobwhy.lua` (`J.df_match`, `J.attach_df`), `lua/dfllm/dfraw.lua` (`R.stall_line`), `lua/dfllm/runner.lua` (PROJECT_BLOCKED waits), `dfpilot/leiter.py`, `dfpilot/brief.py`

## Root cause
`economy.cancel()` already received every CANCEL_JOB announcement (eventful REPORT) and counted per day and kind, but kept only the last reason since the load (`st.call`) and surfaced none of it: no consumer printed DF's words. The container verdict said 'DF says Needs empty food storage item' from a census count, not from DF.

## Fix
A persisted rolling tally per job kind and reason (`cancelwhy.lua`, m.economy `cw`, `economy.cancel.days` 7 days, at most 40 kinds a day, 8 reasons a kind, 14 days kept). Consumers: `why` (r.df {why, n, days, last, text}: 'DF cancelled brew drink from plant 412x in 7 d: Needs empty food storage item (last 2 d ago)', a guessed cause becomes `df_reason`), brew_watch (a verdict is proven only when DF's reason supports it: `M.df_supports`; without it 'by my count'), the stale-order ORDER_STUCK, the runner's PROJECT_BLOCKED waits (construction cancels), the weekly `raw stall` line (leads with `DF: ...` or `DF: no cancel reason seen`), the drink cause (state `stock.dwhy`, new flag `stock.dcx`), the ladder's NAECHST for Versorgung (barrels, not a Still, when `dcx`). Counts are lower bounds (eventful queue drops, folded repeats).

## Tests
`tests/lua/test_neu4_cancel.lua` (tally bounds and window, persistence across a reload, why / stall line text, drink cause), `tests/test_neu4_cancel.py` (state fields, ladder, status).

## Live-Erwartung
1. i2 / i1 `python -m dfpilot why brew` and `why order:<id>` print a line that starts with 'DF cancelled <job> <n>x in 7 d: <DF's reason>' with the count and 'last N d ago'; the weekly kern.log `raw stall` line begins 'DF: DF cancelled ...' (or 'DF: no cancel reason seen' when DF said nothing).
2. status / brief 'drink:' line on i2 leads with 'DF cancels Brew <n>x in 7 d: Needs empty food storage item'; the ladder's NAECHST for Versorgung names MakeBarrel, not `bp.place ... only=Still`.
3. NOT promised: the counts are lower bounds; a reason DF never announces (no CANCEL_JOB) is not seen; the eventful REPORT path is verified live only through the CANCEL_LOOP events in events.jsonl (the reason text path is verified against the gamelog wording, not against a live tally dump).
