# Spec 02: Caravan Autopilot (`python -m df_llm_helper caravan`)

Priority: P0 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-02), not yet live-tested | Framework: see README.md

## Goal and Benefit
Arrival, wish list, trade, departure and stuck traders without a subagent. A trade agent cost approx. 450 k tokens per caravan in Run 5 (11 caravans). Stuck caravans (Leaving, time_remaining 0) also blocked new deliveries (wood, coke, chains) for hours.
**Expected gain:** 70–80 % of the trade costs, no more trade blockage.

## As-Is State (Run 5)
- F15 `trade step/approve` (state machine) exists against mock, not yet live-tested. The trade agent used `claude/handel prep/plan/mark/open/select/confirm/finish --live` (broker `Adil 4161`, window 150x66, trade button at (58,15) or row 60).
- The watchdog pauses on arrival (`caravan.flag`, `pause.hold`) even without trade (one caravan held the game for 23 min).
- The player's standing permission (01.10.2026): send stuck traders home via `unit.flags1.left = true` (only traders and their animals).

## Behavior
1. **Arrival** (`caravans[].state == AtDepot`): decision `trade` or `skip` based on wish list and offer (`handel prep`): trade only if the offer contains at least one must-have good (wood, charcoal/coke, chains/iron/picks/buckets, food, seeds).
2. **Pause** only for `trade`; for `skip` no pausing, delete flag immediately.
3. **Plan** (`planners.py`): sell from surplus (crafts, mugs, statues, stone furniture, blocks; rough gems only above reserve 24), buy according to `data/trade/wants.yaml` (dynamic by shortage, see Spec 07; wood 0 → wood first), ratio ≥ `min_ratio` (Run 5: approx. 2.3–2.5).
4. **Execute** via the F15 automaton up to `finish`, every step with rollback (quicksave beforehand).
5. **Completion:** delete flags, `advance run`, report ≤ 8 lines.
6. **Check departure:** caravan `Leaving` with `time_remaining == 0` for longer than `stuck_ticks` → trader units (merchant flag, caravan animals, never citizens) set to `left = true`; log `tools/out/caravan-release.log`.
7. **Orphaned flags:** delete `caravan.flag`/`pause.hold` without an active caravan > 5 min (rule `stale_caravan_flag` exists).

## Configuration
`caravan: {min_ratio: 2.0, skip_if_offer_empty: true, stuck_ticks: 2000, release_stuck: true, wants_file: data/trade/wants.yaml}`

## Fair Play
`flags1.left` only for traders (standing permission from the player, 01.10.2026). No `createitem`. Trade only via UI-close commands (broker job, goodflags, trade button).

## Acceptance Criteria
1. Replay "Catten small (5 wood, food)": plan buys wood and food, ratio ≥ 2.0, without warning.
2. Replay "without must-have good": `skip`, no pausing, flag deleted.
3. Test "Leaving for > stuck_ticks": only traders and caravan animals receive `left=true`, no citizens (property test).
4. Rollback: aborting in the middle of a trade restores the quicksave.
5. A trade causes ≤ 10 lines of LLM output.
6. Live acceptance: trade window coordinates are found by text search, not hard-wired.

## Fixtures/Tests
`handel status` (Leaving/AtDepot/Approaching), depot sheet and trade window as text buffer (150x66), gamelog "[CARAVAN_ARRIVAL]".
