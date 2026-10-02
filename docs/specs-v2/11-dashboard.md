# Spec 11: Dashboard for the Player (`dfpilot dashboard`)

Priority: P2 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-11), not yet live-tested | Framework: see README.md

## Goal and Benefit
The player wants to see at a glance how the fort is doing, without me writing text ("how is the utilization?", "show me the construction", "where is the hospital?" (translated)). A dashboard saves follow-up questions and status reports.
**Expected gain:** approx. 20–30 % of my answers were pure status reports.

## Content (static HTML page, no external libraries, light/dark)
- Header: fort name, date (year/month/day), pop, fps/tempo, pause, guard (count, armor x/9, wounds).
- Key figures with history (sparklines from `state.db`): population, idle %, food/drinks (days and forecast from Spec 05), meals per head, open jobs, dig jobs, pick carriers.
- Warnings from the digest (red/yellow/ok) with next step.
- Build plan: progress of community buildings (temple, hospital, guilds, cells) as a checklist from `LAYOUT-run5.md` and building counters.
- Bottlenecks (Spec 07), stocks (wood, coke, iron, coal), trade (last caravan, wishes).
- Event list (last 20 important events: deaths, attacks, moods).
- Map excerpt as ASCII for chosen coordinates (`dashboard map x y z w h`), e.g. tunnel end.

## Behavior
1. `dfpilot dashboard --out tools/out/dashboard.html` generates the file from `state.db`; no live server.
2. Publication as an artifact is done by the orchestrator (not part of dfpilot, no network).
3. Update at every `check`, only when values change (hash comparison).

## Configuration
`dashboard: {out: tools/out/dashboard.html, history_h: 6, events: 20}`

## Fair Play
Read only.

## Acceptance Criteria
1. HTML valid (self-test via own parser), < 200 KB, readable offline.
2. All key figures come from `state.db`, no placeholders.
3. Dark mode and smartphone width (CSS tokens).
4. Warnings appear only when the digest reports them (consistency test).
5. Map excerpt for the tunnel end reproduces the tile matrix of the fixture.

## Fixtures/Tests
`state.db` sample with 6 hours of history, digest outputs, tile dumps.
