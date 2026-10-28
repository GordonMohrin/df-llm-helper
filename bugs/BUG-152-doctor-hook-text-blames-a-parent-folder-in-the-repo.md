# BUG-152 `dfllm doctor`: the inactive-hook text blamed a parent start folder when the session had started in the repo
Status: fixed (offline, live-untested)
Severity: low (a self-contradictory hint: "the repo's is <repo>/.claude/settings.json ... a session started in a parent folder never reads it")
Found: 2026-10-28, live test i1 (FR-91-hook, NEW5); confirmed by the verifier
Module: `dfpilot/doctor.py` (`hook_check`, `_inactive_text`)

## Actual
The session started in the repo, and the repo's own `.claude/settings.json` was `{}` (the hook block removed). `hook_check` used one text for
every inactive case.

## Fix
Three texts: the start folder is the repo ("the repo's own .claude/settings.json ... has no dfllm PreToolUse hook (removed?) ... Restore it:
`git checkout .claude/settings.json` or the hook block of QUICKSTART"), a parent folder of the repo (the old text), any other folder (start
inside the repo folder <repo> or copy its hook block). `hook_check` takes `repo` for tests.

## Tests (`tests/test_bug152_doctor_hook.py`)
All three cases (fail on main: no `repo` parameter, one text).
