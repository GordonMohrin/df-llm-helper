# BUG-224: a stale `pause.hold` (reason "karawane" / "alarm") keeps the game paused for a long time; nothing warns, the caravan never arrives

- **Status:** open
- **Severity:** S2 (game frozen for the player, approaching caravan can never reach the depot because no ticks run)
- **Area:** `df_llm_helper/waechter.py` / `caravan.py` / `digest.py` (writers/readers of `tools/pause.hold`)
- **Reported:** 2026-10-02, commit `ae17fff`
- **Environment:** Windows 11, Python 3.14, game running, fort dates 21. Limestone y120 and 8. Malachite y121.

## Command / steps
1. A citizen goes berserk (`BERSERK_CITIZEN` wake alarm); the hold file `tools/pause.hold` with text `alarm` is written.
2. The danger is over a minute later (unit struck down); nobody deletes the hold.
3. 15 min later the game is still paused (`df.global.pause_state == true`, frame counter stands still); `digest` shows no hint. Same with text `karawane`: a caravan was `Approaching` (3706 ticks left) while the game was paused by the hold, so it could never arrive; `trade step` stayed IDLE for 8 minutes.

## Expected
`digest`/`check`: `!! pause.hold stale (age 15 min, reason "alarm", no active danger) - game is frozen`; the wake filter emits it once; optional `autopilot` releases holds older than N minutes when no danger is active.

## Actual
No message; the orchestrator found it only by chance (`claude/advance run` did nothing visible, the military agent reported "game stands still").

## Evidence
none recorded; `tools/pause.hold` content `alarm` / `karawane`, `pause_state=true`, frame counter unchanged over 10 s.

## Analysis (reporter's hypothesis)
Writers of `pause.hold` exist in `siege.py`, `caravan.py`, `waechter.py`, `freeze_guard.py`, `settings.py`, `perf.py`, `camera.py` but there is no common owner/expiry. Suggest a hold file with `reason`, `ts`, `max_age_s` and a check that reports `stale hold` when the game is paused, no danger is active and the age exceeds the limit.

## Nachtrag 2026-10-02 (spaeter am Tag, Live): zwei weitere Ursachen fuer "Spiel steht"

1. **`pause.hold` wird bei jedem Alarm geschrieben, aber nie automatisch geloescht.** Schreiber: der Python-Waechter (`waechter.py`, `_hold("alarm")`) und die Lua-Skripte `claude/gefahr.lua` (schreibt `pause.hold` mit Text `gefahr HH:MM:SS`) und `claude/watchdog.lua`. Der einzige Ablauf im Code ist `waechter.py` ~Zeile 222: nur Holds mit Text, der mit `gefahr` beginnt, nach > 20 min. Holds mit `alarm` oder `karawane` laufen nie ab, und wenn der Waechter nicht laeuft, gar nichts.
2. **Ein offenes `dwarfmode/Squads/Default`-Fenster haelt das Spiel an** (UI-Pause, **kein** Hold, keine Datei): `pause.hold` fehlt, `alert.flag` fehlt, trotzdem Frame-Zaehler steht, `claude/advance run` ohne Wirkung. Der Waechter (`UNPAUSE_RE` / `CLEAR_CMD`, `waechter.py` ~Zeile 234) entscheidet nur ueber Fokus `dwarfmode/Default`, das Squads-Fenster wird nicht erkannt und nicht geschlossen.
   - Manuelle Loesung (live bestaetigt): `df.global.game.main_interface.squads.open = false` und danach `df.global.pause_state = false`.
   - Erwartet: `digest`/`check` meldet `!! game frozen: squads window open (focus dwarfmode/Squads/Default), no pause.hold`; der Waechter schliesst das Fenster (nur wenn kein Squad-Befehl in Arbeit ist) und hebt die Pause auf.
3. Zusammenspiel mit BUG-225: ein Hold/Squads-Fenster verhindert `claude/handel open --live`; der Trade-Flow sollte beides sehen.

Info needed: Fixture der Antwort von `claude/status` (Fokus-String) bei offenem Squads-Fenster; Spieler kann sie mit `dfhack-run lua "print(dfhack.gui.getCurFocus()[1])"` aufnehmen und unter `Bugs/evidence/BUG-224/` ablegen.
