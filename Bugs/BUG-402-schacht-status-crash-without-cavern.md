# BUG-402: `claude/schacht` / `claude/schacht status` crashes with a Lua traceback when no cavern barrier is configured (KOPF = nil)

- **Status:** open
- **Severity:** S2
- **Area:** `lua/claude/sperre.lua:137-146` (`kopf_state`), `:390-407` (`status`), called by `lua/claude/schacht.lua:46`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", date `27. Granite, Jahr 118`), `config.lua` in the Run-5 state (`KOPF = nil`, `KAV_BARRIEREN = {}`, `KAV_ORDER = {}`)

## Command / steps
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/schacht status       # same for: claude/schacht (no argument)
```

## Expected
`config.lua:220` states: "Without cavern access KAV_BARRIEREN/KOPF/SCHACHT_D_SAEULE are empty (nil or {}) -> gefahr.lua/sperre.lua/schacht.lua then do nothing cavern-specific." So `status` should return a JSON object (e.g. `{"kopf":{"state":"n/a"},"barrieren":{}, ...}`) and exit code 0.

## Actual
exit code 1, stdout:
```
...de gordons projects/dwarf-fortress/lua/claude/sperre.lua:49: attempt to index a nil value (local 't')
stack traceback:
	...de gordons projects/dwarf-fortress/lua/claude/sperre.lua:49: in global 'tile_info'
	...de gordons projects/dwarf-fortress/lua/claude/sperre.lua:138: in global 'kopf_state'
	...de gordons projects/dwarf-fortress/lua/claude/sperre.lua:392: in field 'status'
	...e gordons projects/dwarf-fortress/lua/claude/schacht.lua:46: in local 'script_code'
	...team\steamapps\common\Dwarf Fortress\hack\lua\dfhack.lua:1117: in function 'dfhack.run_script_with_env'
	(...tail calls...)
``` `claude/schacht foo` (usage branch) works; `claude/sperre` as a command is silent (module, no CLI; took 1.1 s once).

## Evidence
`Bugs/evidence/BUG-402/schacht_status.out.txt`, `schacht_noarg.out.txt`, `config.out.txt` (shows `run5_unset:false` and no KOPF/KAV data).

## Analysis (reporter's hypothesis)
- `sperre.status()` -> `kopf_state()` -> `tile_info(C().KOPF)`; `C().KOPF` is nil in Run 5, `tile_info(t)` indexes `t[1]` (sperre.lua:49).
- Other callers have the same hazard: `sperre.step_kopf` (218-239), `set_lock('kopf', ...)` (380 handles nil via `not t`, OK), `saeule_erreicht_fort()` (sperre.lua:123-133) uses **hard-coded** coordinates of the old Run-3 map (136,169,100 ...), so on any other map its result (used by ueberwacher/UEBERWACHUNG B4b) is meaningless; see also BUG-419.
- `gefahr.lua:300-308` already guards with `C().KAV_ORDER or {}` (works: `claude/gefahr status` OK), `schacht.lua`/`sperre.lua` do not.

## Suggested fix (optional)
In `sperre.status()` return early `{ aktiv = false, hinweis = 'keine Kavernen-Sperre konfiguriert' }` when `C().KOPF == nil and next(C().KAV_BARRIEREN) == nil`; guard `kopf_state()` the same way.

## Info needed
- Player: is `claude/schacht` supposed to work on the current map (Windrings, no shaft/cavern barrier)? If the whole script is Run-3 only, say so in COMPANION.md and in the `df_llm_helper` rules that call it (`grep -rn schacht data/ df_llm_helper/`).
