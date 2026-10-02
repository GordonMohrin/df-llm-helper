# BUG-120: `--help` of the core commands is nearly empty (31 options without text), `--once` does nothing, no `--version`/`help`, `--mock <missing folder>` is accepted

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S3
- **Area:** `df_llm_helper/cli.py:991-1187` (`build_parser`), `cli.py:164-207` (`autopilot`/`guard`: `--once` never read), `cli.py:17-22` (`_client`: mock folder not checked)
- **Reported:** 2026-10-02, commit `50cee52` (code identical to `6dedd96`)
- **Environment:** Windows 11 Pro, Python 3.14.3, no game needed

## Command / steps
```
cd "<project folder>"
python Bugs/evidence/BUG-120/repro.py        # introspects the parser, then runs the cases
python -m df_llm_helper autopilot --help
```

## Expected
The help system is the only documentation an agent reliably has at hand: each option says what it does (units, defaults, allowed values), each command has a one-line description and one example.

## Actual (`output.txt`)
- **A. 31 options/positionals of the 15 core commands have no help text**, none of the sub-commands has a description or an example: `--dry-run` (what is "dry"? see BUG-117 B), `--loop`, `--interval` (seconds? default 60 for autopilot/guard, 10 for wake, config 2 for waechter - not shown), `--scope` (valid values?), `tempo` action, `guard ack-gate <gate>`, `autopilot enable <rule>`, `overlay text`, `--send`, `record commands`, `metrics --out`, `plan <kind>`/`files`/`--picks`/`--max-open`. Example: `python -m df_llm_helper autopilot --help` shows `--dry-run --loop --once --interval INTERVAL [{run,rules,conflicts,enable}] [rule]` and nothing else. `plan --help` has the only real help texts (some options).
- **B. `--once` is accepted by `autopilot` and `guard` but never read** (only `siege` uses `args.once`); `autopilot --once` behaves exactly like `autopilot`.
- **C.** `--version` and `help` do not exist (`error: the following arguments are required: cmd` / `invalid choice: 'help'`); a global option placed after the sub-command (`record --record x`) gives the generic `unrecognized arguments` without the hint that `--mock/--config/--replay-file/--record` must come first (see BUG-119).
- **D. `--mock <folder that does not exist>` and `--mock <a file>` are accepted**; the result is `Status ?` / `!! Query failed: claude/status: no fixture for 'claude/status'` (looks like a game problem) or `No change ... (1 open: Query)`. Expected `Error: fixture folder not found: ...`.
- **E.** `digest --scope <unknown>` -> `No change since last check.` (BUG-117 F); `plan blueprint` / `plan dig` without input -> silent success (BUG-114).

## Evidence
`Bugs/evidence/BUG-120/repro.py`, `output.txt` (the first section lists every option without help per command).

## Analysis (reporter's hypothesis)
Help strings were written for the top-level list (`sub.add_parser(name, help=...)`) only. Add `description=`/`epilog=` with 1-2 examples (the MANUAL tables already contain them) and `help=` for every argument; drop or implement `--once`.

## Suggested fix (optional)
Fill the help texts from MANUAL sections 2-4; add `--version`; validate `--mock` (`Path.is_dir()`); mention the global-option position in the usage epilog.

## Info needed
None.

## Fix
The 15 core commands have a description, examples (epilog) and help for every option; `--once` is honoured (one pass, overrides `--loop`); `--version`; `help [command]`; an `unrecognized arguments` error for a global option explains that global options come before the command; `--mock <missing folder>` is an error (626d04f). Tests: `test_bug120_*`.
