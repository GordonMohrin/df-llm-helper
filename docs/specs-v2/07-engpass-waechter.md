# Spec 07: Shortage Watchdog for Material and Fuel (`dfpilot bottleneck`)

Priority: P1 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-07), not yet live-tested; backtest only reconstructed (see CHANGELOG) | Framework: see README.md

## Goal and Benefit
See chain deadlocks before they produce 60 % idle. Run 5: wood 0 → no charcoal starter → coke 0 → no smithy (picks, chains, buckets, well chain) → no diggers → idle 60 %. In addition, the starter burned the purchased wood (45 logs) and made carpenter moods fail.
**Expected gain:** diagnosis in 1 turn instead of 8–15, early shopping list for trade, less waste of resources.

## Model
Dependency graph `data/graphs/produktion.yaml` (nodes: resource or order; edges: requires), e.g. `pick ← iron bar + fuel`, `fuel(coke) ← coal boulder + starter fuel`, `starter fuel ← charcoal ← wood`, `chain ← iron bar + fuel`, `well ← chain + bucket + mechanism + block`, `bed ← wood`, `mood(carpenter) ← wood`. Stocks and order status come from the snapshot (`material status`, `orders status`, `essen status`, item lists).

## Behavior
1. For each target (pick target, well, beds, mood reserve) compute the path to the sources; the **first empty node** is the bottleneck.
2. Output e.g.: `Engpass: Holz (0). Blockiert: Koks-Anlasser → Schmiede → 15 Spitzhacken, Kette für Brunnen 2074. Lösung: Karawane (Holz ≥ 20), kein Holz unter Reserve 12 verbrennen` (German; bottleneck: wood (0). Blocked: coke starter → smithy → 15 picks, chain for well 2074. Solution: caravan (wood ≥ 20), do not burn wood below reserve 12).
3. Maintenance rules: wood reserve for moods (starter only at wood > 12), fuel reserve 2 bars; hint when a rule violates this reserve.
4. Feeding trade: bottleneck list → `wants.yaml` (Spec 02) dynamically prioritized.
5. Bottleneck duration in game days; escalation after `escalate_days`.

## Configuration
`bottleneck: {graph: data/graphs/produktion.yaml, wood_reserve: 12, fuel_reserve: 2, escalate_days: 20}`

## Fair Play
Read only and proposals; reserves run via existing `material.lua` parameters.

## Acceptance Criteria
1. Scenario "wood 0, coke 0, coal 26": bottleneck `Holz`, chain starter → coke → smithy explained.
2. Scenario "wood 40, coke 0": starter uses only wood above the reserve.
3. Graph validation: no cycles, no unknown nodes (self-test).
4. Digest line ≤ 160 characters; escalation after 20 days.
5. Backtest on Run 5 time series: bottleneck would have been reported approx. 30 game minutes earlier.

## Fixtures/Tests
`material status` (coke/wood/iron), `orders status`, gamelog "Needs refined coal", `mood.flag` texts.
