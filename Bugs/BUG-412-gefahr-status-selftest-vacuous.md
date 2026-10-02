# BUG-412: `claude/gefahr status` reports `selbsttest: []` ("alarm system alive") because it scans first; `gefahr sim <unknown id>` answers with empty lists

- **Status:** fixed in 6003340
- **Severity:** S3 (misleading health check; no automatic consumer found in `df_llm_helper`)
- **Area:** `lua/claude/gefahr.lua:326-329` (`status`), `:289-296` (`selbsttest`), `:332-339` (`sim`)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**, fort "Windrings", date `27. Granite, Jahr 118`)

## Command / steps
```
cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress/hack"
./dfhack-run.exe claude/gefahr status
./dfhack-run.exe claude/gefahr sim 99999 1 1 1
```

## Expected
1. `selbsttest` lists `ALARMSYSTEM: gefahr-Scan seit N Ticks nicht gelaufen ...` when the watchdog/guard scan job has stopped (that is what the test is for, see header "Self-test for the supervisor (alarm system alive?)").
2. `sim` with a non-existing unit id says so.

## Actual
1. `status` does `local S = scan()` (line 326), which sets `ST.last_scan_tick = now` (gefahr.lua:~178), and only then evaluates `selbsttest()` while building the answer (line 329). The condition `(now_tick - ST.last_scan_tick) > 600` can therefore never be true when called through `claude/gefahr status` - the check always reports "alive", even with the watchdog stopped. Live: `"scans": 375` on the first call, `439` at the end of the session (each CLI call increments the counter itself); `"selbsttest": []`. The other caller (`ueberwacher.lua:41`, direct `gf.selbsttest`) is unaffected.
2. `claude/gefahr sim 99999 1 1 1` -> `{ "aktionen": [], "sim": [] }` (the id is ignored in `scan()`: `local u = df.unit.find(id); if u then ...`).

## Evidence
`Bugs/evidence/BUG-412/gefahr_status.out.txt` (also contains the float defect, BUG-400), `gefahr_sim_unknown_unit.out.txt`.

## Suggested fix (optional)
Evaluate `local st = selbsttest()` **before** `scan()` in the `status` branch; in `sim`/`fire`, return `{error='Einheit '..id..' nicht gefunden'}` when `df.unit.find(id)` is nil (for `fire` the missing-argument case currently dies in `simids[nil] = s`: `claude/gefahr fire` without arguments raises a Lua error; **not run** because `fire` is live - it pauses the game and switches the civil alert on).

## Info needed
none.

## Fix
`status` evaluates the self-test before its own scan; `sim`/`fire`/`firetest` answer with an error for unknown units or missing coordinates.
