# BUG-435: Caravan events are emitted but the orchestrator never reacts (one-shot event, 30 s poll, expired monitor, no repeat)

- **Status:** fixed in `claude/aufsicht` + `tools/aufsicht/runde.py` (orchestrator must use a persistent monitor)
- **Severity:** S1
- **Area:** `lua/claude/aufsicht.lua` (`check_karawane`), `tools/aufsicht/runde.py` (`--follow`), orchestrator monitor
- **Reported:** 2026-10-05 ("Merchant. You missed him again.")
- **Related:** BUG-431, BUG-433

## Evidence
1. `ereignisse.jsonl` contains KARAWANE_DA for every arrival (22:04, 22:12, 22:58, 23:17, 03:07, 03:20, 04:40, 04:54, 06:39, 06:53, 09:48, 10:09): detection works, but each is ONE line and the dedupe key `karawane_<entity>` blocked repeats for 3600 s.
2. `runde.py` at 10:14: "Monitor-Praesenz 17138 s", "letzte Quittung 434 Min": no `--follow` monitor ran for ~4.7 h (monitor with timeout expired), so nobody read the stream; the cron round fires only when the REPL is idle.
3. A caravan stays only ~3000 game ticks. With timestream (~208 ticks/s) that is ~15 s of real time, while the aufsicht polled every 30 s (PERIOD_S): a caravan could arrive and leave between two runs (several ABZUG lines are missing).
4. `supervisor.py` releases `pause.hold` after 90 s (BUG-433), so a pause for the trade does not last.

## Fix
- `check_karawane` runs every 5 s (own timer in the scheduled callback), re-reports every 60 s as `KARAWANE_NOCH_DA` (KRITISCH, remaining ticks) while `trade_state` 1/2 and `time_remaining > 0`; first report dedupe only 30 s.
- `tools/karawane_da.flag` (both flag folders): timestamp + text, refreshed every 20 s, deleted when the caravan is gone. `runde.py` prints a `!!! KARAWANE DA` banner at the top of the round report and `--follow` re-prints it every 45 s.
- Not changed (orchestrator-owned): tempo/advance, automatic slow motion.

## Orchestrator must
Start the monitor with `persistent: true` (`python tools/aufsicht/runde.py --follow`), and on KARAWANE_DA/KARAWANE_NOCH_DA/KARAWANE_FLAG immediately slow down or pause (`claude/advance`, keep `pause.hold` refreshed) and start the trade.
