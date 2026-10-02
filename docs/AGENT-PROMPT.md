# Short start prompt for scope agents (with df-llm-helper)

Detailed usage: `MANUAL.md`.

Until now every agent read 5–9 files at startup (RUN5-START, POSTMORTEMs, LAYOUT, README …). An agent run cost between 100k and 400k tokens in Run 5. With df-llm-helper it gets a briefing package of at most 1,500 tokens instead and queries knowledge only on demand.

## Mandatory since v2-10: generate the prompt instead of writing it

`python -m df_llm_helper agents prompt <scope> --task "<one sentence>"` generates the complete prompt (briefing, mission, report format, fair play, commands; ≤ 1,500 tokens). Pass this text unchanged, add nothing. The same task within 10 min is refused (`--force`). Check the report: `agents lint-report <file>`; costs: `agents cost --compare`.

## Template (fallback without df-llm-helper; the orchestrator fills in `<scope>`; the agent chooses its own thinking effort)

```
You are the scope agent <scope> (Run 5, fortress Windrings). Working folder: df-llm-helper/ (python, not python3).
1. Read ONLY: python -m df_llm_helper brief <scope>   (mission, KPIs, open items, known pitfalls, commands, fair play, report format)
2. Knowledge on demand: python -m df_llm_helper kb search "<symptom>" or kb get <id>; recipes: python -m df_llm_helper runbook diagnose / show <id>
3. ONE pass: measure -> decide -> act -> verify (<= 40 tool calls). Run writing runbooks with --dry-run first.
4. Messages to other scopes: python -m df_llm_helper bus post "<text>" --from <scope> --to <scope|orchestrator> [--prio crit|warn] [--key <dedupe>]
   Own inbox: python -m df_llm_helper bus read --to <scope>; mark done: bus ack --to <scope> <ids>
5. Memory tools/scopes/<scope>.md: sections "Status", "Offen" (open), "Erkenntnisse" (findings), "Durchlauf N" (run N). Afterwards: python -m df_llm_helper memory compact <scope>
6. Report <= 10 lines in the format from the briefing; NO long summaries (the orchestrator reads the digest).
```

## Orchestrator loop (instead of `claude/status` + `claude/report` + reading the inbox)

- Every 5 min `python -m df_llm_helper check`: sets the heartbeat, runs guard and autopilot and delivers the digest. When the situation is unchanged only a line of about 26 tokens comes back.
- Watcher (replaces unpause-guard.ps1, permanent process): `python -m df_llm_helper waechter --loop`.
- Monitor: `python -m df_llm_helper wake --loop --interval 10`. It wakes only on alarm, siege, caravan, mood, supplies, emergency and KRITISCH (critical) lines and does not report legacy items.
- Caravan: repeat `python -m df_llm_helper trade step`. After the dry run, `trade approve` if the selection fits.
- Inform the player: `python -m df_llm_helper overlay --send` (at most 3 lines, without repetition within 10 min).
