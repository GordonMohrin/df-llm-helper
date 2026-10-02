# Lua helpers in the running game - test results (Tester "Lua im Spiel")

Date 2026-10-02, commit `6dedd96`, Windows 11 Pro, Python 3.14.3, DF 53.16 + DFHack, fort "Windrings", game date `27. Granite, Jahr 118` (year tick 31871) - **paused for the whole run and still the same date afterwards** (`claude/status`).
Scripts called live: `C:\Users\admin\claude gordons projects\dwarf-fortress\lua\claude` (DFHack script path); static checks on the repo files. Structure check `python tools/luacheck_min.py lua/claude/*.lua lua/*.lua` -> 64 files, 0 findings; `python -m df_llm_helper lint lua/claude lua/` -> see BUG-418.
Total: 50 `lua/claude/*.lua` + 14 `lua/pilot_*.lua` = 64 scripts (+ live-only `zugaenge_dbg.lua`). Bug numbers BUG-400 ... BUG-422 (reports in `Bugs/`, raw answers in `Bugs/evidence/BUG-NNN/`).

## Rules I followed
No `advance`/pause/tempo/timestream/keys/windows, no `--apply`/`--live`/`start`/`stop`/`once`/`run`/`on`/`off`, no ad-hoc Lua over the map (an ad-hoc timing snippet was blocked by the permission system and not retried), no whole-map scans (`ores`, `geo`, `zugaenge`, `erzdig`, `kohle run`, `pilot_perimeter scan` NOT run).
One slip: a shell typo ran `claude/advance clock` once at the very end (see the advance row and BUG-404); no effect (no popups present, still paused, same tick).
Honest list of edge-case calls of *write* sub-commands that I made **without effect** (invalid/missing id or no `--apply`, verified by the error/dry answer): `pilot_care labors` (no id), `pilot_remote cancel` / `labor` (missing/invalid id), `pilot_siege clear|kill|move` (unknown squad), `claude/aemter assign` (no code), `claude/positions assign` (refused as deprecated), `claude/mil create|add|remove|uniform|workmode|barracks|train|station|kill|release` (dry-run, no `--apply`), `claude/gefahr sim` (dry), `claude/pilot_batch` with read-only sub-commands (`claude/alert`, `claude/status`, `claude/area`, `claude/pilot_wd` dry).

## Side effects (before/after snapshot of `tools/`, `state/`, `metrics.csv`, `dfhack-config`)
Changed by my calls: `metrics.csv` (every `claude/report`, appends a row), `tools/out/handel.log` (+28 KB, every handel call logs its JSON), `tools/out/mil.log` (every mil call). Changed during the run but **not by me** (no script of mine writes them): `tools/heartbeat.txt`, `tools/out/waechter.alive`, `tools/out/perimeter_scan.json` (I only ran `pilot_perimeter result`, a read; another process wrote it). No flag files created/removed by my calls; `pause.hold`, `alert.flag` already existed (schau status shows `gate_reason: "pause.hold (Hauptthread arbeitet)"`).

## Table
Columns: script | read-only tested live | runtime (observed range) | JSON valid | static check | result. `text` = plain text by design.

| Script | lesend getestet | Laufzeit | JSON gültig | statische Prüfung | Ergebnis |
|---|---|---|---|---|---|
| claude/advance | nein (Regel: kein advance); `clock` **1x versehentlich** ausgeführt (Tippfehler im Shell-Aufruf): `paused:true`, Datum/Tick unverändert, keine Popups vorhanden | 0.1 s | ja | gelesen | BUG-404, BUG-405 |
| claude/aemter | status, assign/vacate/repair/nolabors `--dry`, Randfälle | 0.06-0.11 s | ja | gelesen | ok (BUG-422 #3 kosmetisch) |
| claude/alert | status | 0.06-0.09 s | ja | on/off gelesen | ok |
| claude/arbeit | nein (kein Status-Befehl) | - | - | gelesen | BUG-407 |
| claude/area | Standard + 8 Randfälle | 0.07-0.11 s | text | gelesen | BUG-408, BUG-410 |
| claude/auslastung | status, report | 0.09-0.12 s | ja | gelesen (start/stop/hud nicht) | ok |
| claude/bauhelp | Modul, direkt aufgerufen (leer) | 0.06 s | - | gelesen | ok |
| claude/bauprog | status | 0.11-0.19 s | ja | gelesen, L10 | BUG-418, BUG-419 |
| claude/buildings | ohne Arg, z, ungültiges z | 0.06-0.07 s | ja | gelesen | ok (liefert max. 150 Einträge) |
| claude/cam | nein (verändert Kamera) | - | - | gelesen (ruft `schau.hold(120)` schon vor der Argumentprüfung) | ok |
| claude/config | ja (+ Arg `aquifer`) | 0.46-0.62 s | ja | gelesen | BUG-416 |
| claude/dig | nur Usage-/Fehlerzweige | 0.06-0.07 s | ja | gelesen | ok (BUG-418: kein Hidden-Check) |
| claude/erzdig | nein (Standard = designiert) | - | - | gelesen | BUG-407, BUG-415 |
| claude/essen | status | 0.16 s | ja | gelesen | BUG-407 |
| claude/felder | list, foo | 0.06-0.14 s | text / leer | gelesen | BUG-410 |
| claude/gefahr | status, selftest, sim (dry), foo | 0.07-0.13 s | status: **nein**, Rest ja | gelesen | BUG-400, BUG-412, BUG-417 |
| claude/geo | nein (Ganzkarte) | - | - | gelesen | BUG-415, BUG-419 |
| claude/gesund | status, krypta, gedanken, foo | 0.08-0.17 s | ja | gelesen (rest/release/seed/amt/slabs nicht) | BUG-422 |
| claude/handel | status, plan, broker, prep, release, mark, open, select, confirm, accept, abort, finish, scan, foo (alle ohne `--live`) | 0.07-0.30 s | ja | gelesen | BUG-403 (statisch, nicht ausgeführt) |
| claude/killorder | nein (nicht im Live-Skriptpfad) | - | - | gelesen | BUG-420 (Hinweis) |
| claude/kohle | status | 0.07-0.09 s | ja | gelesen (`run` ~9 s laut workload.py) | BUG-411, BUG-415 |
| claude/material | status | 0.24 s | ja | gelesen | BUG-407 |
| claude/migranten | status, plan | 0.06-0.42 s | status: **nein** | gelesen (scan/start/stop nicht) | BUG-400, BUG-401 |
| claude/mil | status, report, equip, routines, enemies, plan, tabelle, guard, train/station/kill/release/create/add/remove/uniform/workmode/barracks (dry), Randfälle | 0.06-0.20 s (2x 8-9 s) | ja (`report`/`tabelle` text) | gelesen | BUG-401, BUG-407, BUG-421 |
| claude/mood | status, dry, werkstaetten, plan | 0.08-1.32 s (plan 145 KB) | ja | gelesen (prebuild nicht) | ok (BUG-422 #4) |
| claude/muell | status, foo | 0.08-0.20 s | ja / leer | gelesen (dump nicht) | BUG-410, BUG-419 |
| claude/orders | status, list | 0.10-0.11 s | ja | gelesen | BUG-407, BUG-422 |
| claude/ores | nein (Ganzkarte) | - | - | gelesen | BUG-415 |
| claude/pickfix | Plan ohne `--apply` | 0.07 s | ja | gelesen | ok |
| claude/pilot_batch | 10 Anfragedateien (Leerzeichen im Pfad, kaputtes JSON, BOM, ...) | 0.07-0.18 s | ja (1 Absturz) | gelesen | BUG-413, BUG-420 |
| claude/pilot_wd | mode ohne `--apply` | 0.06-0.07 s | ja | gelesen | ok (Duplikat: BUG-420) |
| claude/positions | Liste, foo, assign (verweigert) | 0.06-0.10 s | ja | gelesen | ok (veraltet) |
| claude/probe | 7 Fälle inkl. außerhalb | 0.06-0.08 s | ja | gelesen | ok |
| claude/raster | status | 0.45-0.48 s | ja | gelesen (start/stop/next/reset nicht) | BUG-411 |
| claude/report | ja | 0.24-0.28 s | ja | gelesen | BUG-416 (schreibt metrics.csv) |
| claude/schacht | status, ohne Arg, foo | 0.07-0.25 s | status: **Absturz** | gelesen | BUG-402 |
| claude/schau | status, profile, foo | 0.07-0.10 s | ja | gelesen (say/show/start... nicht) | ok (profile fehlt live: BUG-420) |
| claude/sperre | Modul, direkt aufgerufen (leer) | 1.11 s | - | gelesen | BUG-402, BUG-419 |
| claude/stages | Modul, direkt aufgerufen (leer) | 0.10 s | - | gelesen | BUG-419 |
| claude/status | ja | 0.15-0.21 s | ja | gelesen | ok |
| claude/task | list + 6 Randfälle | 0.06-0.10 s | ja | gelesen (add/destroy nicht) | ok |
| claude/tempo | status | 0.06-0.19 s | ja | gelesen (on/off/suspend/resume/load/say nicht) | BUG-416 |
| claude/timer | Modul, direkt aufgerufen (leer) | 0.07 s | - | gelesen | BUG-405 |
| claude/trinken | status | 0.13-0.25 s | ja | gelesen (lager/once/start nicht) | BUG-406, BUG-407 |
| claude/ueberwacher | nein (Standard schreibt Flags) | - | - | gelesen | BUG-407 |
| claude/units | ja | 0.08-0.11 s (49 KB) | ja | gelesen | ok |
| claude/util | Modul, direkt aufgerufen (leer) | 0.10 s | - | gelesen | BUG-400, BUG-401, BUG-417 |
| claude/watchdog | status, ohne Arg | 0.07-0.09 s | ja | gelesen (start/stop nicht) | BUG-411 |
| claude/workdetail | list, foo | 0.07-0.09 s | ja | gelesen (assign nicht) | ok |
| claude/zugaenge | nein (~10 s laut Header) | - | - | gelesen | BUG-415, BUG-419 |
| claude/pilot_caravan | release ohne `--apply` | 0.06-0.09 s | ja | gelesen, Lint L07 | BUG-418 |
| claude/pilot_care | status (58 KB), Fehlerzweige | 0.06-0.09 s | ja | gelesen | ok (BUG-422 #4) |
| claude/pilot_defense | status (18 KB) | 0.07-0.11 s | ja | gelesen | ok |
| claude/pilot_digcheck | dump (9 Fälle) | 0.06-0.10 s | ja (1 Absturz) | gelesen | BUG-409 |
| claude/pilot_hygiene | status (3 Varianten), report, mark ohne `--apply` | 0.06-0.26 s | ja | gelesen | ok |
| claude/pilot_mood | need, Fehlerzweige | 0.07-0.10 s | ja | gelesen (release-cutgems nicht) | ok |
| claude/pilot_perimeter | Usage, result | 0.07-0.09 s | ja | gelesen (scan/start nicht) | ok (BUG-415: `scan` synchron) |
| claude/pilot_reach | check (5 Fälle), dump (6 Fälle, bis 180k Kacheln) | 0.06-0.31 s | ja | gelesen | BUG-409 |
| claude/pilot_remote | status (3 Varianten), Fehlerzweige | 0.07-0.11 s | ja | gelesen | ok |
| claude/pilot_siege | status, Fehlerzweige | 0.06-0.10 s | ja | gelesen | BUG-409, BUG-422 #5 |
| claude/pilot_tools | status (50 KB) | 0.09-0.10 s | ja | gelesen | ok |
| claude/pilot_water | scan, near, Randfälle | 0.06-0.07 s | ja | gelesen | BUG-414 |

(`lua/pilot_batch.lua` / `lua/pilot_wd.lua` in the repo root are the English duplicates of the two `lua/claude/` rows, BUG-420.)

## Only testable in motion (running game time), please ask the player
- `claude/advance <n>`, `run`, `0` and the timer/timestream interaction (BUG-405), `claude/tempo on|off|suspend|resume|load` (timestream switching, flapping), `claude/watchdog start|stop` and `claude/mil guard start|stop` (periodic jobs, slow motion, civil alert, siege flag), `claude/gefahr fire|firetest` (pause + flags + alarm), `claude/schau start|mode|show` (camera director, rate limits), `claude/auslastung start` (HUD, CSV, threshold flag).
- Work loops: `claude/arbeit`, `essen`, `trinken`, `material`, `orders`, `raster`, `kohle`, `bauprog` (`once/start/next`), `erzdig`, `pickfix --apply`, `muell dump`, `mood prebuild`, `gesund start/rest/release/amt/slabs`, `ueberwacher`, `migranten scan/start` (needs a new citizen), `mood` watch with a real strange mood, `claude/task add|destroy`, `claude/dig`, `claude/workdetail assign`, `claude/aemter assign|vacate|repair|nolabors` (without `--dry`), `claude/alert on|off`, `claude/cam`.
- Caravan flow (needs a caravan at the depot): `handel prep|mark|open|select|confirm|accept|release --live`, `pilot_caravan release --apply`.
- Combat: `pilot_siege kill|move|clear`, `mil kill|station|release --apply --experimental`, `claude/schacht open|seal|notzu|tuer`.
- Whole-map scanners with real runtime: `claude/ores`, `claude/geo`, `claude/zugaenge`, `claude/erzdig --dry`, `claude/kohle run`, `claude/pilot_perimeter scan` (BUG-415).
