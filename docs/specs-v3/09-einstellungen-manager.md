# Spec v3-09: Settings Manager (`dfpilot settings`)

Priority: P2 | As of: 01.10.2026 (Run 5, Y109) | Status: implemented (v3), not yet live-tested | Framework: see `../specs-v2/README.md`

## Goal and Benefit
Safely change, back up and document game settings that are only read at start (`prefs/d_init.txt`: `POPULATION_CAP`, `STRICT_POPULATION_CAP`, `BABY_CHILD_CAP`, `VISITOR_CAP`). In Run 5 I set `POPULATION_CAP:75` and `STRICT_POPULATION_CAP:100` at the player's request by editing the file (backup `d_init.txt.bak-run5`). There is no DFHack field at runtime; the effect only comes after a restart (the population was already above it at 141).
**Expected gain:** traceable, reversible changes; no forgotten restart dependencies.

## Behavior
1. `dfpilot settings get [key]` reads `prefs/d_init.txt` (lines `[KEY:value]`), shows value, default, effect time (`immediate` / `after restart`), description (from `data/settings.yaml`).
2. `dfpilot settings set KEY value [--reason "..."]`: creates `d_init.txt.bak-<date>` first, changes exactly one line (format checked), logs (`state.db`, the player's quote in the exception register if it touches fair play), reports `takes effect only after a restart: <planned>`.
3. **Restart planner:** `settings pending` lists changes that only take effect after a restart; the digest shows `1 setting waiting for a restart (POPULATION_CAP 75)`.
4. **Restart help** (together with spec v2-09): before a restart pause, save, set `pause.hold`; afterwards restart the services and check the setting (`settings verify`: reads `d_init` and, if possible, behavior such as migrants/births).
5. **Effect check:** after the restart, population development: are migrants and births suppressed (population trend, `migranten.flag`)?
6. **Undo:** `settings revert KEY` restores the backup.

## Configuration
`settings: {file: prefs/d_init.txt, backup_dir: prefs/backups}`

## Fair Play
Settings are game menus (Settings); deliberate change only on the player's word; log entry with quote.

## Acceptance Criteria
1. `set POPULATION_CAP 75`: backup exists, exactly one line changed, the rest byte-identical (test).
2. Invalid key/value: refused, nothing changed.
3. `pending` shows the change until `verify` has passed after a simulated restart.
4. `revert` restores the original file byte-identically.
5. Write access only to the configured file and the backup folder.

## Fixtures/Tests
`d_init.txt` (Run 5, lines 25–26), backup file.

## Implementation (v3)
- **Code:** `dfpilot/features/settings.py` (`settings get|set|pending|verify|revert|restart-plan`, `check_hook`), known keys in `data/settings.yaml` (type `int` or `int_pair`, min/max, DF default, effect, description).
- **set:** validates key and value before reading or writing anything; `--reason` (the player's words) is required and goes into the `state.db` action log; the file is handled as bytes (line endings, Latin-1 bytes and the rest of the file stay byte-identical); after the write the file is re-read and must differ in exactly that one line, otherwise the original is written back. Backup `<backup_dir>/d_init.txt.bak-YYYY-MM-DD` (an existing backup with other content gets `-2`, `-3`, ...; the first backup of a key is kept for revert).
- **pending/verify:** `state.db` key `settings.pending`. `verify` needs the new value in the file AND a DF restart after the change: DF uptime (`dfhack.getTickCount()`, ms since process start) must be shorter than the age of the change. For population caps the current population is compared with the cap (hint about migrants). `check` shows the pending line at most every `hint_every_s` (30 min).
- **revert KEY:** puts the original line back; when no other change is pending the file is compared with the backup ("byte-identical" or a note).
- **Write boundary:** `_write` refuses every path except `settings.file` and paths below `settings.backup_dir` (`PermissionError`, tested). Default file: `<DF folder of dfhack_run>/prefs/d_init.txt`, default backup folder `<prefs>/backups`.
- **Tests:** `tests/test_settings.py`; fixtures `fixtures/v3/settings/` (synthetic d_init.txt with CRLF and the Run 5 lines 25–26, backup with defaults).
- **Deviations:** the quote is not written to the exception register (`data/exceptions.jsonl`): the population caps do not touch fair play, and acceptance 5 restricts writes to the d_init file and the backup folder; the quote is in the `state.db` action log. Births are not measured by `verify` (no data source), only the population vs. the cap.
- **Open live checks:** location of `d_init.txt` in DF 53 Steam (DF folder `prefs/` or `%APPDATA%/Bay 12 Games/Dwarf Fortress/prefs/`: set `settings.file`); DF defaults (200/220/1000:1000/100) against the real file; `dfhack.getTickCount()` really resets on a DF restart.
