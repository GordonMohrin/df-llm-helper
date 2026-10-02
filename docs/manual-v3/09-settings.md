# Settings: `dfpilot settings` (spec v3-09, live-untested)

**What it does:** changes `d_init.txt` keys that DF reads only at start, with a backup, a log entry and a
restart planner. Known keys: `POPULATION_CAP`, `STRICT_POPULATION_CAP`, `BABY_CHILD_CAP` (`a:b`), `VISITOR_CAP`
(`data/settings.yaml`). Anything else is refused.

## First: set the file path
`config.yaml`: `settings: {file: "<path to prefs/d_init.txt>", backup_dir: "<folder>"}`. Default is the DF folder of
`dfhack_run` + `prefs/d_init.txt` and `prefs/backups`. Check where DF 53 really keeps it.

## Commands
- `python -m dfpilot settings get [KEY]`: value, DF default, effect (after restart), description, pending change.
- `settings set KEY VALUE --reason "<the player's words>"`: only on the player's word; backup
  `d_init.txt.bak-YYYY-MM-DD` first, exactly one line changed. Output: `takes effect only after a restart: KEY VALUE`.
- `settings pending`: what waits for a restart (`check` shows the same line at most every 30 min).
- `settings restart-plan`: the steps: pause, save, `pause.hold`, restart DF, `dfpilot reboot`, `settings verify`.
- `settings verify`: after the restart. Passes when the file has the new value and DF was started after the change
  (DF uptime). Population caps: shows population vs. cap.
- `settings revert KEY`: original line back; "file byte-identical to the backup" when it was the only change.

## Safety
Writes only the configured file and the backup folder (anything else raises an error). Invalid values (letters,
out of range, brackets) are refused before anything is written. Every set/revert/verify is in the `state.db`
action log with the reason.
