# BUG-783 a cause lock only time lifts took the brief's NAECHST line without a command
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-23, NEU1 verifier (offline, test fixtures): an R0 fort with one goblin death in a siege 55 days ago printed 'NAECHST Volk gesperrt (Belagerung ...): R1 (Belagerungstote auf R0)' with no command; a mood death at Wohl II printed 'NAECHST Wohl gesperrt (Stimmung ...)' the same way. Second pass: after the first fix a locked track stayed a candidate and NAECHST read 'NAECHST Wohl II: Stress 40 % < 10 % ...' beside 'GESPERRT Wohl (Stimmung ...)'.
Module: `dfpilot/leiter.py` (`LOCK_FIX`, `lock_cmd`, `lines`, `compute` cands)

## Actual
`lines()` gave any active lock the NAECHST line; the locked track's own command is time-only for Volk ('waechst mit Migranten') and for Wohl while the stress clock runs, so the line named no command for up to a game year and the actionable Wehr / Ruestung step went to OFFEN. After the first fix the locked track still sat in `cands` with its eff capped below raw, so a skipped lock let NAECHST fall back to the locked track itself under a wrong level.

## Fix
`LOCK_FIX` maps a lock class to the track whose command lifts it (thirst -> Versorgung, patient -> Wohl, siege on R0 -> Wehr); `lock_cmd` returns it only with an actionable command. Only such a lock takes NAECHST (`NAECHST Versorgung gesperrt ... -> cmd`, `NAECHST Wehr II: ... -> cmd (hebt Sperre Volk)`); every other lock is a `GESPERRT <Spur> (<Ursache>: <fix>)` entry in line 3. `compute` leaves every locked track out of `cands`, so it is never the NAECHST fallback nor an OFFEN entry.

## Tests
`tests/test_neu1_wertung_leiter.py`: `test_siege_lock_on_r0_names_the_wehr_command`, `test_mood_lock_with_stress_clock_keeps_a_command`, `test_time_only_lock_never_names_naechst_or_offen` (mood with stressed_pct 40 at Wohl II, drowning at P3), the durst-lock test stays green.
