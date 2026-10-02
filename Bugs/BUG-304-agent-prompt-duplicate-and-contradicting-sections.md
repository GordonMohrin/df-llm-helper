# BUG-304: `agents prompt` repeats Fair Play / Report / Commands twice and gives two contradicting report formats (<= 10 lines vs <= 12 lines with different fields); long tasks are cut silently

- **Status:** verified fixed (retest 2026-10-02, 8e67f05)
- **Severity:** S2
- **Area:** `agents prompt` (`df_llm_helper/agents.py:build_prompt`, `df_llm_helper/brief.py`)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-304/cfg.yaml tmp_bug/cfg.yaml
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents prompt trinken --task "Check the barrels"
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 agents prompt bau --task "<a 750-character task>" --force
```

## Expected
One consistent report format and each block once (docs/MANUAL.md 9.10 and docs/AGENT-PROMPT.md call this prompt "pass it unchanged"). A task longer than the limit is rejected or shortened with a visible marker.

## Actual
Section headings of the generated prompt:
```
$ (section headings of the output above)
## Task
## Briefing
## Mission
## Situation Y102 Hematite 12
## Known traps (python -m df_llm_helper kb get <id>)
## Commands
## Fair Play
## Report
## Report format (mandatory, <= 12 lines, otherwise truncated)
## Fair Play
## Commands
```

The embedded briefing ends with its own `## Fair Play`, `## Commands` and `## Report` blocks ("Report <= 10 lines: 1) KPIs before->after 2) done (command -> effect) 3) blocked/needs 4) messages ... 5) next pass"); the prompt then appends a second
`## Report format (mandatory, <= 12 lines, otherwise truncated)` with the fields `Result / Measurements / Changed / Open / Risk`, a second `## Fair Play` and a second `## Commands`.
An agent cannot satisfy both report formats; `agents lint-report` only accepts the second one, so an agent following the first one is reported as broken.
Full output: `Bugs/evidence/BUG-304/prompt_trinken.txt`.

Silent truncation of the task: ```
task given: 749 chars; task found in prompt: 400 chars; ends with ...'word word word word word word '
```

## Evidence
`Bugs/evidence/BUG-304/*.txt`.

## Analysis (reporter's hypothesis)
`agents.py:49-62` `build_prompt` appends FORMAT/FAIRPLAY/COMMANDS after the whole `brief_text`, which already contains `## Fair Play`, `## Commands`, `## Report` (`brief.py`). `task = " ".join(task.split())[:400]` (line 52) cuts without notice.

## Suggested fix (optional)
Strip `## Fair Play`, `## Commands` and `## Report` from the briefing before embedding (or drop the prompt's own copies) and keep exactly one report format. Refuse or mark (`[task shortened]`) tasks > 400 chars.

## Info needed
Question for the cloud session: which of the two report formats is the authoritative one (`lint-report` and MANUAL 9.10 say Result/Measurements/Changed/Open/Risk)?

## Fix
The prompt drops the briefing's own Fair Play / Report / Commands blocks (scope commands are merged into the prompt's Commands block). Answer: the authoritative format is the lint-report one (Result/Measurements/Changed/Open/Risk, <= 12 lines); `brief` uses the same wording now. Tasks > 400 characters are marked `[task shortened: 400 of N characters]`.
