# BUG-422: small cosmetic / robustness findings in the Lua helpers (orders flag lists, file-handle leak, answer sizes, aemter numbers, pilot_siege visitors)

- **Status:** fixed in 157b535
- **Severity:** S3
- **Area:** `lua/claude/orders.lua:222-227,373`, `lua/claude/gesund.lua:399`, `lua/claude/aemter.lua:~93`, `lua/claude/mood.lua` (`plan`), `lua/claude/units.lua`, `lua/pilot_care.lua`, `lua/pilot_siege.lua:~19`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", date `27. Granite, Jahr 118`)

## Findings
1. **`claude/orders status` condition text glues flag sets together**: `cond_text` concatenates `flaglist(c.flags1) .. flaglist(c.flags2) .. flaglist(c.flags3)` without a separator (flaglist joins with `+` only inside one set). Live: `"bed": "AtLeast 40 BOULDER[non_economichard]; LessThan 6 WEAPONRACK"` (should be `non_economic+hard`). `order_sig` (orders.lua:231) uses the same concatenation, so two different flag combinations could produce the same signature (`"ab"+"c"` vs `"a"+"bc"`), which the "recognise own orders by signature" logic relies on.
2. **File handle leak** `gesund.lua:399`: `local new = not io.open(CSV_FILE, 'r')` opens the CSV for reading and never closes it (the next line opens it again for append). Harmless for the GC but it accumulates handles on Windows between collections; use `local f0 = io.open(...); new = not f0; if f0 then f0:close() end`.
3. **`claude/aemter status`** prints `responsibilities` as numbers (`[25, 28]`), because `df.entity_position_responsibility[rk]` is applied to the *name* key `rk` of `pos.responsibilities`; the header promises "index fields", names would be more useful (e.g. `["MANAGE_PRODUCTION"]`). Cosmetic.
4. **Answer sizes** (token cost for the LLM): `claude/mood plan` 145,292 bytes / 1.3 s (all 174 citizens x skills), `claude/units` 49,276 bytes, `claude/pilot_care status` 57,806 bytes, `claude/pilot_tools status` 49,614 bytes, `claude/pilot_remote status` 39,546 bytes, `claude/gesund status` 22,653 bytes, `claude/gesund gedanken` 46,592 bytes. `claude/buildings` silently truncates to the first 150 of the list (flag `truncated: true`, `counts` complete) - without a z the truncation order is the engine's, not by importance. No limit parameters except `buildings`/`pilot_hygiene status`.
5. **`pilot_siege.lua` `friendly()`** treats `isVisitor` as friendly. `lua/claude/gefahr.lua:96` documents that `isVisiting/isVisitor` are **true for Forgotten Beasts** (`visitor_uninvited`) and uses a different test. If a beast ever gets `isInvader` it would be excluded from `status.invaders` and from `kill` targets. (Hypothesis from the source comment; no live case, `invaders: []` now.)
6. `claude/report` builds `local sq = df.squad.find(...)` that is never used, and `ent.squads` is not nil-checked (`report.lua:~128-131`); harmless in a loaded fort.
7. `claude/gefahr`, `mil`, `pickfix`, `handel` write a log line on **every** call (also reads) to `tools/out/*.log` / `mil.log`; see BUG-416 item 5 for growth.

## Evidence
`Bugs/evidence/BUG-422/orders_status.out.txt` (item 1), `aemter_status.out.txt` (item 3), `mood_plan_head3000.out.txt` (item 4, first 3000 bytes of 145,292).

## Suggested fix (optional)
Per item above; items 4/7 only if you want to cut tokens/log growth.

## Info needed
none.
- Decided (player delegated the decision): trim fields that no Python consumer reads and that make answers big, only where grep in `df_llm_helper/`, tests and `data/` proves it; compact default with `--full` for the old output.

## Fix
1 flag sets joined with `+` (cond_text and order_sig), 2 CSV probe handle closed, 3 responsibilities as names, 5 pilot_siege visitors friendly only when not invaders, 6 report nil checks; 7 logs rotate (c3b327d). 4 (answer sizes) not changed: needs a decision which fields to drop (wontfix for now).

Item 4 applied (157b535). Proof by grep: no parser for `claude/mood plan` or `claude/gesund gedanken`; `claude/gesund status` is only read by the snapshot service parser (`running`); `features/tools.py` never reads the citizen `name` of `pilot_tools status`. Compact defaults, `--full` = old answer:
- `claude/mood plan`: only citizens with an at-risk mood skill (workshop missing/under construction or material below minimum), one text per skill, material stock once (`material`), `ohne_risiko` count.
- `claude/gesund status`: `buerger` only with stress >= LOW or at rest, plus `buerger_anzahl`; `claude/gesund gedanken`: the 15 most stressed citizens, aggregates complete.
- `claude/pilot_tools status`: no `name` per citizen.
Not trimmed (every field is read by a parser): `claude/units` (snapshot), `pilot_care status` (care.py), `pilot_remote status` (features/remote.py). `buildings` already has a limit. Tests `test_gesund_status_and_gedanken_are_compact_by_default`, `test_mood_plan_compact_keeps_only_risky_skills`, `test_pilot_tools_status_leaves_names_out_unless_full`.
