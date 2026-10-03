# BUG-224: a stale `pause.hold` (reason "karawane" / "alarm") keeps the game paused for a long time; nothing warns, the caravan never arrives

- **Status:** fixed in c7602ac
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

## Fix
- `df_llm_helper/holds.py`: limits per reason (`holds.max_age_min` in the config: alarm 15, gefahr 20, karawane 10,
  caravan 10, trade 30 min, others 30). A hold is stale when it is older than its limit and nothing justifies it:
  for alarm/gefahr no `siege.flag`, no `alert.flag` younger than 5 min (`holds.alert_active_min`) and no snapshot
  danger; for karawane/trade no running trade automaton (a running trade protects its hold up to 60 min).
- `guard.py` (runs in `check`): a stale hold gives one critical warning per hold, e.g.
  `!! [guard] pause.hold stale (age 15 min, reason "alarm", no active danger) - game is frozen; delete tools/pause.hold
  if nothing needs the pause` (plus an events.log line). `digest.py` was not touched; the warning reaches the digest
  through the warnings table.
- `waechter.py`: deletes a stale hold (`holds.auto_release`, with `alert.flag` for alarm holds), logs it and leaves a
  warning; the old `gefahr` 20-minute rule is kept unchanged. A `karawane` hold of an approaching caravan without a
  trade is released after 10 min, so the caravan can reach the depot.
- Squads window (addendum 2): the watcher sees `dwarfmode/Squads/...` in its status line; open with time standing still
  (paused or frame counter unchanged) for `holds.squads_close_s` (30 s) -> `main_interface.squads.open=false` (like
  Escape) and `claude/advance run` when no pause.hold/alert.flag exists; warning `game frozen: squads window open
  (focus ...), no pause.hold - closed and resumed`. Never during an alarm (danger hold, siege.flag, fresh alert.flag)
  and never while time runs (the player uses the window). `claude/handel open` also closes it first.
- Addendum 3: the trade automaton sees both (BUG-225: `danger` and focus blockers).
- Lua writers (`claude/gefahr.lua`, `claude/watchdog.lua`) are unchanged (gefahr.lua is edited elsewhere); their texts
  `gefahr HH:MM:SS` / `karawane` already start with the reason the expiry uses.
- Tests: `tests/test_live_trade.py::test_bug224_*` (stale rules, check reports once, watcher releases alarm/karawane,
  keeps an alarm hold during a siege, closes the Squads window after 30 s, leaves it alone during an alarm or while
  time runs).

## Info needed
- Fixture still wanted: watcher status line with the Squads window open, i.e. the output of the watcher's CLEAR_CMD
  (`P 0 dwarfmode/Squads/Default fc=... yt=...`) and `dfhack-run lua "print(dfhack.gui.getCurFocus()[1])"`, under
  `Bugs/evidence/BUG-224/`. If the focus string differs from `dwarfmode/Squads/...`, the token in `waechter.py`
  (`"/Squads"`) must be adjusted.
- Live check: write `alarm` into `tools/pause.hold`, wait 16 min without alert.flag/siege.flag: `check` shows the
  stale-hold line once, the watcher deletes the hold and the game runs again.
