# BUG-419: map-specific coordinates are hard-coded in several repo scripts although README/COMPANION say they live in `config.lua`

- **Status:** fixed in 5b5249c
- **Severity:** S3 (wrong results on any other map, no crash; also the reason why `schacht status` crashes, BUG-402)
- **Area:** `lua/claude/muell.lua:20`, `kohle.lua:37`, `sperre.lua:124,136,181-186`, `stages.lua` (whole file), `bauprog.lua:20-59,116`, `zugaenge.lua:5`, `geo.lua:12,69`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", map 192 x 192 x 153, surface z133, fort centre 96/96/133), static analysis + live answers

## Command / steps
```
cd "C:/Users/admin/claude gordons projects/dfpilot-public/lua/claude"
grep -n "x - 99\|y - 95\|for z = 100, 146\|z <= 131 and x >= 40\|{ 136, 169\|ZMIN, ZMAX\|or 110\|or 97" *.lua
```

## Expected
README: "Fortress-specific values (squad name, water boxes, rally point) go there [`config.lua`]"; COMPANION.md: "Fortress-specific values live in `lua/claude/config.lua` (coordinates, burrows, grid stages in `stages.lua`)".

## Actual (repo copy; the live copy of muell.lua already differs: `z <= 135`)
- `muell.lua:20` `is_fort(z,x,y)`: `z <= 131 and x in 40..150 and y in 60..130` (Run-4/5 "Windrings" has its fort at z up to 135: the live file was patched to 135, the repo still has 131 -> `claude/muell status` undercounts loose corpses of the upper levels in the repo version).
- `kohle.lua:37` sorts coal candidates by distance to the shaft `(99,95)`.
- `sperre.lua:124` (`saeule_erreicht_fort`: shaft column `(136,169,...)` -> `(136,160,144)`), `:136` tunnel tiles `(137,167..169,138)`, `:181-186` "citizens behind the barrier" box `x135..137,y168..171,z<=143 or z<=117`; none read `config.KAV_BARRIEREN`.
- `bauprog.lua:20-59` six phases `O1..O6` for the east wing x163..186 at z141..144 plus blueprints `claude/bau_o*_*.csv` (not part of the repo), `:116` `for z = 100, 146`.
- `stages.lua`: raster stages for x59..170, y23..170 (documented as config-like, fine) but with Run-5 specific names.
- `zugaenge.lua:5` `ZMIN, ZMAX = 100, 136`; `geo.lua:12,69` default geo biome `110` (map "Canyonsyrups") and `ceil = 97`.
Live evidence of the effect: `claude/bauprog status` lists the Run-3 east-wing phases (`"O1": "Ostfluegel z144: Werkhalle ..."`, all `gestartet:false`, `waende_offen:0`) on a map where they are meaningless.

## Evidence
`Bugs/RESULTS-lua.md` (rows muell, kohle, bauprog, sperre, stages, zugaenge, geo); live `claude/bauprog status` is in the raw record.

## Suggested fix (optional)
Move to `config.lua` (`SHAFT`, `FORT_Z_MAX`, `ZUGAENGE_Z`, `BAU_PHASES`), or state in COMPANION.md that these scripts are Run-3/4 specific and must not be called by `df_llm_helper` on other maps (client `is_write` / services lists).

## Info needed
- Player: which of `muell`, `kohle`, `bauprog`, `geo`, `zugaenge`, `schacht` are still in use on the current map? Unused ones could be dropped from the public repo.
- Decided (player delegated the decision): keep muell, kohle, bauprog, geo, zugaenge and schacht; they read config values and are generic. Each header gets a "used for / needs config keys" note, COMPANION.md lists them as optional scripts; run-3-only parts stay behind `BAU_PHASES_RUN3`.

## Fix
muell (04eda95), sperre (59e973b), zugaenge, kohle, geo, bauprog read config values (`FORT_BOX`, `FORT_REFS`, `Z_MIN/Z_MAX`, `SCHACHT_PRUEF`, new `HINTER_SPERRE`, new `BAU_PHASES_RUN3 = false`). `stages.lua` stays (documented config-like data). Info needed (player): which of muell/kohle/bauprog/geo/zugaenge/schacht are still used.

Decision applied (5b5249c, muell/zugaenge headers in 4c66249): "Used for: ... Needs config keys: ..." in the headers of all six (kohle: stale "near the shaft (99,95)" text corrected), COMPANION.md has an "Optional scripts" table with purpose and config keys. Test `test_optional_scripts_say_what_they_need`.
