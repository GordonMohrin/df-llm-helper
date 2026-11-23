# BUG-792: wait wakes only on interrupts

Part of Neuausrichtung 1 / P3; full design, interactions and Live-Erwartung: [docs/v2/NEU1-wecken.md](../docs/v2/NEU1-wecken.md).

- **Symptom:** `dfllm wait --until-interrupt` woke only on the 7 FR-53 interrupts the kernel already handles; PATIENT_DYING, MOOD_CRITICAL, thirst/food decisions, STRANDED, CUTOFF, SIEGE_START, BREACH came after the 300 s play-loop timeout (~125 game days).
- **Change:** `dfpilot/alarm.py` `wait_wake` / `acts` / `sys_reasons`, cursor `<save>/.wait.json`, `config/wake.json` `wait`.
- **Test:** tests/test_neu1_wecken.py (wake list tests)
- **Status:** fixed (offline, live-untested)
