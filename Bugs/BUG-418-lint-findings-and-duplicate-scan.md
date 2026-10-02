# BUG-418: `df_llm_helper lint lua/claude lua/` exits 1 (pilot_caravan L07 without a register entry), prints every `lua/claude` finding twice, and 5 L10 "undiscovered tile" warnings are real fair-play notes

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
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
- Decided (player delegated the decision): `claude/dig` designates undiscovered tiles blindly, exactly like a player dragging a dig box over unrevealed rock: no tiletype/shape read, no skipping based on hidden info; revealed tiles keep the current checks. (The FP09 lint error of pilot_caravan stays as documented: the player's standing permission for `flags1.left` is not a register entry of the public repo.)

Decided (player delegated the decision): shipping the public repo without an FP09 consent is correct: a consent is per player and lives in the git-ignored `data/exceptions.local.jsonl`; the shipped L07 finding stays as an expected, documented one.

## Fix
`lint_paths` de-duplicates files; `bauprog.shape_at` skips undiscovered tiles; LINT-FINDINGS.md updated. FP09: decided, see below; `claude/dig`: decided, see below.

Decision implemented (367df0a): lint uses `ExceptionRegistry` with its local register (`exceptions.local.jsonl` merged) and maps a lint rule to the runtime rule of the same action (`L07`<->`FP09`, `L06`<->`FP08`), so the player's FP09 consent also silences L07 (before, lint only accepted an `L07` entry). Without consent the L07 message says: `needs the player's consent FP09 in data/exceptions.local.jsonl (python -m df_llm_helper exception add FP09 --local --reason 'stuck merchants' --ja '<player quote>')`; `exception add --local` writes the git-ignored file. `docs/LINT-FINDINGS.md`, `docs/MANUAL.md`, `data/README.md` updated. Test: `tests/test_bugs_decided.py::test_bug418_*`.

Decision applied (4446691): for a hidden tile `claude/dig` reads only `designation.hidden` and the configured barrier boxes (new `config.in_sperr_box`, split out of `is_sperre` so no tile is read), then designates; output field `blind` counts these tiles. Header rewritten accordingly. Test `test_dig_designates_hidden_tiles_blindly_without_reading_their_shape` (map mock: a hidden open tile is designated like a hidden wall, zero tiletype reads of hidden tiles) and `test_dig_header_documents_blind_designation`.
