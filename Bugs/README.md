# Bugs

Bug reports for the df-llm-helper cloud session. The cloud session has **no access to the local Dwarf Fortress
instance** and cannot run scripts against a live game, so every report must carry everything needed to reproduce and
fix the bug from the repo alone: exact command, exact output, expected output, and a **recorded fixture** (raw game
answers) where the live game was involved.

## File naming

`Bugs/BUG-<NNN>-<short-slug>.md` (NNN counts up, three digits). One bug per file. Status lives in the header
(`open` / `fixed in <commit>` / `wontfix`); the cloud session sets `fixed`, the reporter re-tests and closes.

## Template

Copy `Bugs/TEMPLATE.md`. Required: title, severity, command, steps, expected, actual (verbatim, in a code block),
environment (commit, OS, Python, whether a live game was running, game date), suspected location (file:line),
fixture/recording (path under `Bugs/evidence/BUG-<NNN>/` for raw outputs), and "Info needed" if the cloud session
should supply something (a decision, a spec detail) or the player should test something.

## Severity

- `S1` crash / wrong action on the game / fair-play violation
- `S2` wrong or misleading output, false alarm, loop, data loss
- `S3` cosmetic, doc mismatch, noisy output

## Live-only checks

Things that can only be verified with a running game are listed in `Bugs/TESTPLAN-live.md` with the exact commands
and the expected result. The player (or the local orchestrator) runs them and attaches the output as evidence.
