# Spec 09: Restart and Load Runbook (`dfpilot reboot`)

Priority: P0 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-09), not yet live-tested | Framework: see README.md

## Goal and Benefit
After every restart or loading of a save, the Lua permanent jobs no longer run (DFHack repeat does not survive loading). In Run 5 this caused idle (38–66) and supply worries to rise until I noticed; the player occasionally reloads the game.
**Expected gain:** avoids 20–40 min of unnoticed undersupply, approx. 20 calls saved.

## As-Is State
Runbook `rb19_dienste_starten` and the autopilot rule "restart services" exist (four services from SPEC F2). Missing: extended list (raster, kohle, mil guard, tempo, migranten, schau), the detection "new game loaded" and loading via the title menu without desktop.

## Behavior
1. **Detection:** `world.frame_counter` jumps back, the report ID drops (the watchdog already detects "new game") or the focus changes `title → dwarfmode`.
2. **Load helper** (optional, only at the player's request): title menu via `tools/embark/findclick.lua`: "Continue active game" → world → `Folder: autosave 1`; window 150x66.
3. **Service list** `data/services.yaml` (name, start command, check command): watchdog, ueberwacher, arbeit, orders, auslastung, trinken, essen, material, gesund, migranten, mil guard, `claude/raster start`, `claude/kohle start`, `claude/tempo load`.
4. **Recovery:** check via `repeat-util` query (`claude-*=true`), start missing services, then measure idle (`check`).
5. **Time limit:** after loading, stay paused until all services run, then `advance run`; deadman unchanged.
6. **Log:** digest line "Neustart: 11 Dienste gestartet" (German; restart: 11 services started).

## Configuration
`reboot: {services_file: data/services.yaml, auto_load: false, wait_s: 20}`

## Fair Play
Only menu and script starts as before.

## Acceptance Criteria
1. Test "all services stopped": after `reboot` all run according to the check command, dependencies in the right order (config before services).
2. Test "service already running": no double starts (idempotence).
3. Test "save loaded, map not yet": waits and starts only at `isMapLoaded`.
4. Self-test checks that every service line has a check command.

## Fixtures/Tests
`repeat-util` queries (`claude-watchdog=true ...`), title menu text buffer, `fixtures/run5/*status*`.
