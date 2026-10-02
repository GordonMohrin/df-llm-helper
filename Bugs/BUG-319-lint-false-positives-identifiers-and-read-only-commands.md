# BUG-319: Fair-play linter reports harmless code: identifiers (`teleporting_label`, `tiletypes`, `liquids`, `cleaners`), the read-only command `deathcause`, and message text that mentions `createitem`

- **Status:** fixed in af96561 (identifier part: 6e0db06)
- **Severity:** S3
- **Area:** `df_llm_helper/lint.py` (rules L01, L08, L17, L18, L25)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-319/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
mkdir tmp_bug/lint && cp Bugs/evidence/BUG-319/inputs/L*.lua tmp_bug/lint/
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/lint
```

## Expected
No findings: the six files are local variable names, a read-only DFHack query command and a printed sentence.

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 lint tmp_bug/lint
L01_message_text.lua:1: L01 createitem creates items out of nothing
L08_identifier_teleporting_label.lua:1: L08 setting position directly (teleport)
L17_identifier_tiletypes.lua:1: L17 changing terrain
L18_identifier_liquids.lua:1: L18 setting liquids
L25_deathcause_read_only.lua:1: L25 cheat tool
L25_identifier_cleaners.lua:1: L25 cheat tool
6 findings (6 errors)
[exit 1]
```

## Evidence
`Bugs/evidence/BUG-319/`.

## Analysis (reporter's hypothesis)
`lint.py:48-77`: L08 `teleport` has no word boundary; L17 `tiletypes\b`, L18 `\bliquids\b`, L25 `\bcleaners?\b` match local identifiers (the DFHack commands only matter as quoted command strings); `deathcause` (and `gaydar`) only *display* information; L01 matches inside any string literal because `strip_code(keep_strings=True)` is needed for commands. A false positive on a bundled script would block `RealClient` (every `lua ...` command goes through `gate_command`, only `error` level), i.e. a harmless script text can stop the agent's work.

## Suggested fix (optional)
Anchor the command rules to `run_command(` / `lua "..."` string starts or to the first word of a quoted command; drop `deathcause`/`gaydar` from L25 (or make them `warn`); keep identifiers out.

## Info needed
Question for the cloud session: are `deathcause` and `gaydar` really cheats in the player's fair-play definition? They only read data.

Decided (player delegated the decision): `deathcause` and `gaydar` are no cheats (read only, the game UI shows the same); `createitem` inside pure message text is not reported, as a command it stays an error.

## Fix
Command words (teleport, tiletypes, liquids, cleaners, ...) count only as DFHack commands (string literal, `run_command/run_script` argument or a bare command line), so `local tiletypes = {}` etc. are no longer reported. Message text and `deathcause`/`gaydar`: decided, see below.

Decision implemented (af96561): `deathcause`/`gaydar` removed from L25 and from the runtime rule FP07. L01 skips a line that only passes text to a message function (`print`, `qerror`, `error`, `dfhack.printerr`, `util.emit`, `say`, `log`, `warn`, `notify` ...) and executes nothing (no `run_*`, `os.execute`, `io.popen`, `load`, `dfhack.script*`); comments were already stripped. `run_command/run_script('createitem' ...)`, a bare `createitem ...` line and any other string literal (may be executed) stay L01 errors. The runtime gate FP01 for commands is unchanged. `docs/LINT-FINDINGS.md` documents it. `lint Bugs/evidence/BUG-319/inputs` now reports 0 findings. Test: `tests/test_bugs_decided.py::test_bug319_*`.
