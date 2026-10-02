# Spec 10: Enforce Subagent Briefing and Measure Costs (`python -m df_llm_helper agents`)

Priority: P0 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-10), acceptance 4 open (needs live runs) | Framework: see README.md

## Goal and Benefit
Subagents are the largest cost block: around 6980 calls, approx. 1.2 bn cache-read tokens, 36.8 M new context, 0.26 M output (measurement 01.10.). Every agent reads 10–20 Markdown files at start and writes long reports.
**Expected gain:** 20–40 % of the total costs (estimate), short and comparable reports.

## As-Is State
F5 `python -m df_llm_helper brief <scope>` (≤ 1500 tokens), F7 `bus`, F6 memory compactor and F13 `budget` exist. My agent prompts were nevertheless 500–1500 words long and referred to files.

## Behavior
1. **Prompt generator:** `python -m df_llm_helper agents prompt <scope> --task "<short>"` produces the complete prompt: briefing + assignment + report format (≤ 10 lines) + fair-play block + commands. The orchestrator passes only this text (`AGENT-PROMPT.md` becomes mandatory).
2. **Report format:** fields `Ergebnis`, `Messwerte (vorher/nachher)`, `Geändert`, `Offen`, `Risiko` (result, measurements (before/after), changed, open, risk). `python -m df_llm_helper agents lint-report` checks length and mandatory fields; reports that are too long are shortened, the original archived.
3. **Bus instead of Markdown:** agents post via `bus post` (deduplicated), the orchestrator reads `bus read`; inbox files are imported (exists).
4. **Cost measurement:** `python -m df_llm_helper agents cost` reads `subagents/*.jsonl` (path configurable) and sums calls, cache read/write, output, duration per agent and assignment; comparison briefing vs. old prompt.
5. **Budget hints** (warning only): agent with > `warn_calls` or > `warn_output_k` without result → "stuck? Shrink the assignment" (German in the original: "festgefahren? Auftrag verkleinern").
6. **Deduplication:** the same task within 10 min is not assigned twice.

## Configuration
`agents: {transcript_dir: ~/.claude/projects/.../subagents, max_report_lines: 12, warn_calls: 60, warn_output_k: 40}`

## Fair Play
No interventions in the game; only prompt, report and cost management.

## Acceptance Criteria
1. `agents prompt <scope>` produces ≤ 1500 tokens (all 12 scopes) and contains the mandatory blocks.
2. `lint-report` detects reports > 12 lines and missing mandatory fields (positive/negative).
3. `agents cost` reads a sample transcript and reproduces the sums (± 1 %) of the hand measurement script.
4. Comparison on 3 agent runs: mean output smaller by ≥ 30 %.

## Fixtures/Tests
Small, anonymized transcript excerpts (`subagents/*.jsonl`), sample reports from Run 5.
