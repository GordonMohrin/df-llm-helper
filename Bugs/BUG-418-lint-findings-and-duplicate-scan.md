# BUG-418: `df_llm_helper lint lua/claude lua/` exits 1 (pilot_caravan L07 without a register entry), prints every `lua/claude` finding twice, and 5 L10 "undiscovered tile" warnings are real fair-play notes

- **Status:** fixed in b0a2741
- **Severity:** S3
- **Area:** `df_llm_helper/lint.py` (scan of nested dirs), `data/exceptions.jsonl` (only an `"example": true` row), `lua/pilot_caravan.lua:21`, `lua/claude/bauprog.lua:83`, `mood.lua:82,213`, `gesund.lua:200`, `raster.lua:128`, `dig.lua` / `probe.lua`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3 (no game needed)

## Command / steps
```
cd "C:/Users/admin/claude gordons projects/dfpilot-public"
python -m df_llm_helper lint lua/claude lua/
python tools/luacheck_min.py lua/claude/*.lua lua/*.lua          # structure check
```

## Expected
Each finding once; exit code 0 for a clean repo (or a documented, accepted exception).

## Actual
- Structure check: `64 files, 0 with findings` (all `function/if/for ... end` blocks balanced, no unterminated strings - good).
- `lint lua/claude lua/`: `11 findings (1 errors)`, exit 1; the 5 warnings of `lua/claude/` appear **twice** because `lua/` already contains `lua/claude/` (6 unique findings). `lint lua` alone: `6 findings (1 errors)`; `lint lua/claude`: `5 findings (0 errors)`.
- The single error: `lua\pilot_caravan.lua:21: L07 setting unit 'left' (stuck traders, exception required)`. By design this needs an entry in `data/exceptions.jsonl` quoting the player's consent (README: "Exceptions only via an entry..."); the file ships only the ignored example row for FP09, so the shipped repo never lints clean.
- L10 (`getTileType` without `designation.hidden` check): `bauprog.lua:83` (`shape_at` used by `rect_walls`/`rect_open`: `claude/bauprog status` reports `waende_offen` = number of WALL tiles in the planned east wing, i.e. shape information of **undiscovered** rock; live answer shows `waende_offen: 0` for all phases because the wing is already dug, but the code path is the leak), `mood.lua:82,213`, `gesund.lua:200`, `raster.lua:128` (own fort coordinates / reachability checks - low risk). Not reported by the linter but the same class: `claude/dig` designates and counts `WALL` tiles without a hidden check (header says "only if the tile is discovered/not open" - the code has no such check) and `claude/probe` reads hidden neighbours deliberately (documented in its header as a safety probe).

## Evidence
`Bugs/evidence/BUG-418/lint_raw_output.txt`, `lint_lua_claude_only.txt`, `lint_lua_only.txt` (verbatim output incl. exit code).

## Suggested fix (optional)
De-duplicate paths in `lint.py` (resolve + set); decide whether the shipped lint should be green (e.g. a `"example": false` row for FP09 conditional on the player, or `# fp-ok: FP09` marker in pilot_caravan.lua that the linter honours); make `bauprog.rect_walls` count only `not hidden` tiles (or report `null` for hidden ones); fix the `dig.lua` header or add the check.

## Info needed
- Player: is it acceptable that the repo's own lint run reports the FP09 error? Is the `dig.lua` behaviour (designating undiscovered wall tiles) allowed under the fair-play rule?

## Fix
`lint_paths` de-duplicates files; `bauprog.shape_at` skips undiscovered tiles; LINT-FINDINGS.md updated. Info needed (player): FP09 entry in `data/exceptions.jsonl` so the shipped lint is green (pilot_caravan L07), and whether `claude/dig` should skip undiscovered tiles (header corrected, behaviour unchanged).
