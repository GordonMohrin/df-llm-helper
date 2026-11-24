# BUG-792: wait wakes only on interrupts

Part of Neuausrichtung 1 / P3; full design, interactions and Live-Erwartung: [docs/v2/NEU1-wecken.md](../docs/v2/NEU1-wecken.md).

- **Symptom:** `dfllm wait --until-interrupt` woke only on the 7 FR-53 interrupts the kernel already handles; PATIENT_DYING, MOOD_CRITICAL, thirst/food decisions, STRANDED, CUTOFF, SIEGE_START, BREACH came after the 300 s play-loop timeout (~125 game days).
- **Change:** `dfpilot/alarm.py` `wait_wake` / `acts` / `sys_reasons`, cursor `<save>/.wait.json`, `config/wake.json` `wait`.
- **Test:** tests/test_neu1_wecken.py (wake list tests)
- **Status:** fixed (offline, live-untested)

## Live-Erwartung
1. A MOOD_CRITICAL / PATIENT_DYING / DECISION_NEEDED thirst_unit event is followed by a `wait` return naming it within seconds (cli.log `wait` line with the event n), not after the 300 s timeout.
2. `wait` does not return more than once per 5 minutes for the same key (no wait storms in cli.log).
3. Quiet types (`wait.quiet_types`) never end a `wait`; they still show in brief / `events --cls A`.
