# BUG-219: `siege` with an unreadable `pilot_siege status` ends as "Siege ABORTED" + crit warning + `notify.flag` (push to the player) although no siege exists; exit code differs between real (1) and `--dry-run` (0)

- **Status:** open
- **Severity:** S3 (S2 if `siege` is ever called from automation while DF is not reachable)
- **Area:** `df_llm_helper/siege.py` `SiegeRunner.run` (`if not o.ok: ... flow.state = "ABORT"`, `finally:` -> `store.warn(... "crit")`, `tools.write_flag("notify", ...)`), `df_llm_helper/cli.py` `cmd_siege` return code
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3; mock (no `pilot_siege` fixture) and live (script installed: `claude/pilot_siege status` answers in 0.1 s); game paused, fort date 27. Granite, Jahr 118

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper --mock fixtures/run5 siege                  ; echo rc=$?
python -m df_llm_helper --mock fixtures/run5 siege --once           ; echo rc=$?
python -m df_llm_helper --mock fixtures/run5 siege --dry-run        ; echo rc=$?
python -m df_llm_helper siege --dry-run -v                          # live
cat runtime/mock/tools/notify.flag
```

## Expected
A status that cannot be read is an error of the *tool* ("claude/pilot_siege status not readable: is DF running / is the script installed?"), not a siege abort: no `notify.flag` ("the orchestrator sends the push to the player"), no crit warning "run the siege by hand", the same exit code with and without `--dry-run`.

## Actual
```
Siege ABORTED: 0 attackers, 0 steps
pilot_siege status not readable - run the siege by hand
rc=1 (siege) / rc=1 (--once) / rc=0 (--dry-run) / rc=0 (--once --dry-run)
notify.flag: "pilot_siege status not readable - run the siege by hand"
```
(The warning row is written even with `--dry-run`, see BUG-203.) Live behaviour is fine: `siege --dry-run -v` -> `no attackers on the map` in 0.5 s. The live answer shows 5 squads (`Bergleute` 32, `Wache` 33 with 7 members, `Elite2` 34, `Schuetzen-alt-leer` 35, `Schuetzen` 36), `invaders: []`, `civ_alert: 1` while `claude/status` lists two Goblin Thieves ("Feinde auf der Karte") and `alert.flag` says `[AMBUSH_SNATCHER] Snatcher! Protect the children!`: the siege autopilot (correctly, per spec) ignores non-invader ambushers/thieves, but the output does not say so ("2 enemies on the map, none is an invader").

## Evidence
`Bugs/evidence/BUG-219/` (`siege_mock_rc.txt`, `notify.flag.mock`, live raw answer `l_siege_dry.jsonl`).

## Analysis (reporter's hypothesis)
`ABORT` is used for "cannot proceed" in general; the cleanup `finally` treats it like a lost battle.

## Suggested fix (optional)
Separate `ERROR` from `ABORT`; only ABORT paths after a siege started write the flag; return the same code for dry and real runs; in `no attackers on the map` mention non-invader enemies (`claude/mil enemies`).

## Info needed
Live behaviour with real attackers cannot be tested while the game is paused (see report: needs a running siege). Please run `python -m df_llm_helper siege --once -v` at the next real attack (as INTEGRATION v2-01 asks) and attach the output.
