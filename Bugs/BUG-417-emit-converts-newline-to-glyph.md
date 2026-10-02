# BUG-417: `util.emit` runs `df2utf` over multi-line strings: newlines become the CP437 glyph `◙` (U+25D9)

- **Status:** open
- **Severity:** S3
- **Area:** `lua/claude/util.lua:14-24` (`to_utf8` / `emit`), visible in `lua/claude/gefahr.lua` (`handle()` text), any script that emits strings containing `\n` or other control characters
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", date `27. Granite, Jahr 118`)

## Command / steps
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/gefahr sim 539 96 96 133        # dry run, no flag/pause/alarm; unit 539 = dead forgotten beast
```

## Expected
`"ereignis"` contains real line breaks (`\n` in JSON), as built in `gefahr.lua:handle()` with `table.concat(lines, '\n')`.

## Actual
```
"ereignis": "12:08:19 GEFAHR-ALARM (gefahr.lua) 27. Granite, Jahr 118 [TROCKENLAUF]◙A/FEATURE_BEAST FORGOTTEN_BEAST_27 id 539 ... zone=nah dist=0 erreichbar=true◙Zuflucht: burrow=0 civ ..."
```
(`dfhack.df2utf` maps byte 0x0A to the CP437 picture glyph U+25D9 `◙`; tabs (0x09) would become `○`, 0x0D `♪` ...). A consumer that splits the text on `\n` sees a single line.

## Evidence
`Bugs/evidence/BUG-417/gefahr_sim_539.out.txt`.

## Analysis (reporter's hypothesis)
`df2utf` is meant for DF strings (CP437) and also converts control characters 0x01-0x1F. `emit` applies it blindly to every string.

## Suggested fix (optional)
In `to_utf8`: `t[k] = dfhack.df2utf(v):gsub('\xE2\x97\x99', '\n')` (U+25D9 = `E2 97 99`), or split by `\n` before converting and re-join afterwards. Combine with the single-conversion fix of BUG-401.

## Info needed
none.
