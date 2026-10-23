# BUG-080 The status drops the lockdown's cause under a long supply or pop line; a dying patient wakes after the year review
Status: fixed (integration audit I1; offline, live-untested)
Severity: medium (BUG-065's point was that the status names what holds a lockdown; BUG-054/063 added alerts for dying people)
Found: 2026-10-23, integration audit I1 (C3's `fit_ranked` read together with the lines A4/B1/B3/C1/C2 added)
Module: `dfpilot/brief.py` (`status_text`, `fit_ranked`, `line_pop`, `line_supply`, `line_alarm`), `dfpilot/wake.py` (`PRIO`)

## Actual
1. A reclaimed fort (FR-76: adopt line with the missing workshops, 3000 forbidden drinks) that lost a fifth of its peak (FR-74:
   pop trend) with a dry hospital (BUG-034), stress sources and coffins (BUG-062), idle breakdown (FR-77) and a lockdown held by a
   gremlin (BUG-065): `dfllm status` prints the clock line, pop and ONE stock line cut in the middle of the coffin clause. The
   lockdown line with its cause is gone (only `DEFCON 3` and `ALERT` say there is one).
2. A burst of YEAR_REVIEW + PROJECT_BLOCKED + PATIENT_DYING + MOOD_CRITICAL wakes as `YEAR_REVIEW ... next: dfllm plan propose`:
   the two new class-A types are not in `wake.PRIO`, so they sort behind every ranked type and the line's `next:` is the least
   urgent one's.

## Cause
1. `status_text` ranked `line_pop` and `line_supply` as rank 1 each. Both are bundles: line_supply joins the stock sentence
   (what must stay) with the adopted-fort line, the orders manager note, stress, deaths, coffins, idle and the stuck orders;
   line_pop joins pop with the pop trend (FR-74) and the readiness summary. `fit_ranked` drops rank 2 (UNREADY, alarm) whole
   before it touches a rank-1 line, so a long bundle pushed the alarm line out although nothing in the bundle is as urgent.
   Also, after one clip to 90 tokens it dropped a rank-2 line whole; a harder cut (60) would have kept it. `line_alarm` put the
   clock first and the doors, recall, far invaders and the lever latency behind the cause in one rank-2 line.
2. `PRIO` (wake.py) was not extended with BUG-054's PATIENT_DYING and BUG-063's MOOD_CRITICAL (both class A, `next: tell Gordon
   at once`).

## Fix
`brief.pop_items`, `supply_items` and `alarm_items` give the parts their own ranks (the status uses them, the brief joins them as
before): the stock sentence with its causes (why the stills do not brew, the forbidden stock) and the pop line stay rank 1; the
rest of the supply bundle is three rank-4 lines (adopted fort and manager note; stress, deaths, coffins; idle and orders); the pop trend and the readiness summary rank 3; of the alarm line the lockdown with its
cause, the unacked interrupts and the ETA are rank 2, the clock, doors, recall, far invaders and the lever latency rank 3.
`fit_ranked` cuts the rank-2 lines to 90 and then to 60 tokens before one goes whole. `PRIO` ranks PATIENT_DYING and MOOD_CRITICAL
behind NO_DEPOT and before DEATHS_PREVENTABLE.

## Test
`tests/test_i1_state.py` (all five fail on the base): the busy fort above keeps the cause and its `harmless`; a maximal state
(80 citizens, every optional field) stays within STATUS_TOKENS and BRIEF_TOKENS and keeps `cause ... dangerous`; the rank-2 cut;
the wake order and its hint.
