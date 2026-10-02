# BUG-109: `plan blueprint` reports errors (zone keys `n f t p w`, quoted CSV cells, filled workshop footprints) for blueprints that quickfort accepts and that were used in the live game

- **Status:** open
- **Severity:** S2 (false alarms on the fair-play/validation path; a valid blueprint is refused, exit 1)
- **Area:** `df_llm_helper/planners/blueprint.py:28` (`ZONE_KEYS = frozenset("mbhDBoTda")`), cell parser `blueprint.py:160-215` (no CSV quote handling -> `E_CELL`), overlap check `blueprint.py:290-320` (`E_OVERLAP`), `blueprint.py:375` (`W_COLS`)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**), fort "Windrings", date `27. Granite, Jahr 118`; the blueprints are the real files of `<DF>/dfhack-config/blueprints/claude/`

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-109/repro.py                      # 10 sample files copied next to the script
python -m df_llm_helper plan blueprint "<DF>/dfhack-config/blueprints/claude/"*.csv      # all 475 real blueprints (in chunks of 60)
```

## Expected
Blueprints that quickfort runs (they were *used* in the live game: e.g. `handel_jeweler.csv` -> `Jewelers: 1` in `claude/buildings`) validate without errors.

## Actual
Of the 475 real blueprints: **402 ok, 73 with findings** (`all_475_real_blueprints_summary_raw.txt`): 127x `W_COLS`, 93x `E_CELL` (22 files), 28x `E_ZONEKEY` (9 files), 10x `E_OVERLAP` (3 files).
At least **32 files are false errors**, three causes (all verified against DFHack's own quickfort source/manual in the game folder, copied to the evidence folder):

1. **Zone keys** - validator allows only `m b h D B o T d a`; quickfort's zone table (`hack/scripts/internal/quickfort/zone.lua:105-127`, `quickfort_zone_keys_from_game_zone.lua.txt`) has
   `m b h n p w j f s o D B a d t T g c`. Real blueprints use `n` (pen/pasture, 20x), `f` (fishing), `t` (animal training), `w` (water source), `p` (pit/pond):
   `E_ZONEKEY unknown zone key 'n' (allowed: BDTabdhmo)` for `handel_weide.csv`, `essen4_fischzone.csv`, `essen5_train.csv`, `hosp_pond.csv`, `wasser_s1.csv`, ... (9 files).
   (The labels in the code comment at `blueprint.py:26` are correct - `h` Dining Hall, `T` Tomb - the set is just incomplete; the comment says it came from "layout notes, section 9".)
2. **Quoted CSV cells** - `"n{name=""Nestbox 13""}"`, `"b{name=""Verwalter-Schlafzimmer"" assigned_unit=manager}(3x3)"` are normal CSV quoting (needed because the cell contains `"`); the validator splits on `,` itself and reports
   `E_CELL invalid character '"' in key '"n'` (22 files: `nest13.csv`, `office.csv`, `bedroom_zone.csv`, `r3_hospital_zone.csv`, `r3g_taverne.csv`, ...). Use the `csv` module.
3. **Filled footprint** - quickfort accepts the key in every tile of a building (`quickfort-user-guide`: "Or you can fill out the entire footprint like this: `wm wm wm / wm wm wm / wm wm wm`", `quickfort_user_guide_excerpt.txt`).
   `handel_jeweler.csv` (3x3 of `wj`) gives 8x `E_OVERLAP 'wj' overlaps 'wj'`.

   `W_COLS` (127x, 40 files) fires on ordinary ragged rows (`,,` filler lines, trailing commas) that quickfort ignores - it is noise as a warning.
   (Two more `E_OVERLAP` hits, `r5_z117_training_build.csv` `a(8x1),r(8x1)` and `wirt_sp7_so.csv` `g{...}(8x3),,,,,,,u{...}(7x3)`, look like real overlaps; not part of this bug.)

Output excerpt (`output.txt`):
```
...\blueprints\handel_weide.csv:
  2:1 error E_ZONEKEY unknown zone key 'n' (allowed: BDTabdhmo)    (x20)
...\blueprints\nest13.csv:
  2:1 error E_CELL invalid character '"' in key '"n' (cell '"n{name=""Nestbox 13""}"')
...\blueprints\handel_jeweler.csv:
  2:2 error E_OVERLAP 'wj' overlaps 'wj' (line 2, column 1) on level 0
[exit=1]
```

## Evidence
`Bugs/evidence/BUG-109/`: `repro.py`, `output.txt`, `blueprints/*.csv` (10 real samples), `all_475_real_blueprints_summary_raw.txt`, `quickfort_zone_keys_from_game_zone.lua.txt` (DFHack source, `zone.lua` lines 100-128), `quickfort_user_guide_excerpt.txt`.

## Analysis (reporter's hypothesis)
The validator was written from the project's own blueprints ("zone keys `m b h D B o T d a`", PLANNERS.md) and tested with synthetic bad files only; the repo fixtures `fixtures/run5/blueprints_ok/` (10 files) never use these features.

## Suggested fix (optional)
Take the zone key set from quickfort (`m b h n p w j f s o D B a d t T g c`), parse rows with `csv.reader`, treat adjacent identical building keys as one building when they fill the footprint, downgrade `W_COLS` to info or drop it, and add 5-6 of the real files from the evidence folder as `blueprints_ok` fixtures.

## Info needed
Gordon / cloud session: should `plan blueprint` be the gate in front of `quickfort run`? If yes, this must be fixed before; if it is only advice, make the exit code 0 for warnings and show errors as "possible". Also see BUG-110 (no map-bounds check from the CLI).
