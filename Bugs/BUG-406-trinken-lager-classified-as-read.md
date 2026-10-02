# BUG-406: `claude/trinken lager` writes stockpile settings but is whitelisted as a read command (`_READ_SUB`); `_NO_STATUS` is stale for bauprog/raster

- **Status:** fixed in 9f7b226
- **Severity:** S2 (false "read" classification disables the write protections: loop guard, `max_per_hour`, state.db log)
- **Area:** `df_llm_helper/client.py:63-68` (`_READ_SUB`, `_NO_STATUS`), `lua/claude/trinken.lua:156-187,262-263`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", date `27. Granite, Jahr 118`)

## Command / steps
```
python - <<'EOF'
from df_llm_helper.client import is_write
for c in ("claude/trinken lager", "claude/trinken status", "claude/bauprog status", "claude/raster status",
          "claude/mil tabelle --file", "claude/mil tabelle --say", "claude/advance clock"):
    print(c, "->", "WRITE" if is_write(c) else "read")
EOF
```
(I did not run `claude/trinken lager` live because it writes.)

## Expected
`lager` applies `p.storage.max_barrels = want` to **every stockpile** (`trinken.lua:181`, `lager(true)` at line 263), so it must count as a write. Only `claude/trinken status` (which calls `lager(false)`) is read-only.

## Actual
`"lager"` is in `_READ_SUB` (client.py:63) -> `is_write("claude/trinken lager")` is False. Also:
- `claude/mil tabelle --file` (writes `tools/out/mil-tabelle.txt`) and `--say` (in-game announcement) are classified read because of the `tabelle` sub (minor, S3).
- `claude/advance clock` is classified read although it dismisses popups (BUG-404).
- `_NO_STATUS = {"claude/arbeit", "claude/ueberwacher", "claude/bauprog", "claude/raster"}` (client.py:68, comment: "scripts WITHOUT a status command"): `claude/bauprog` and `claude/raster` **do** have `status` (and default to it): verified live `claude/bauprog` and `claude/raster status` return JSON without side effects (`Bugs/evidence/BUG-411/raster_status.out.txt`). The conservative result is only a false "write" (workload checks cannot use them as free reads), `workload.py:171` already works around it for raster.

## Evidence
`Bugs/evidence/BUG-406/trinken_status.out.txt` (live `claude/trinken status`: shows the `lager` list with `max_barrels` that `lager` would rewrite; read-only call).

## Analysis (reporter's hypothesis)
`_READ_SUB` is matched on the second token only; `lager` meant "show stockpile roles" in an earlier version (`lager(false)`), the apply flag was added later (`trinken.lua:156 lager(apply)`).

## Suggested fix (optional)
Remove `"lager"` from `_READ_SUB`; add explicit `("claude/trinken", "lager")` handling (`is_write` True). Remove bauprog/raster from `_NO_STATUS`. Treat `--file`/`--say` as write for `mil tabelle`.

## Info needed
- Cloud session: grep `data/` and `df_llm_helper/` for callers of `claude/trinken lager` (rule/runbook may rely on it being "free").

## Fix
`client.is_write`: `lager` removed from `_READ_SUB` (no caller relied on it), `--file`/`--say` make a command a write, bauprog/raster removed from `_NO_STATUS`; ueberwacher stays conservative because older installed copies still run a round for `status`.
