# Spec 05: Famine Forecast (`dfpilot forecast`)

Priority: P1 | As of: 01.10.2026 (Run 5, Windrings) | Status: implemented (PR v2-05), not yet live-tested; acceptance 5 food 33 % instead of ≤ 30 % (see CHANGELOG) | Framework: see README.md

## Goal and Benefit
Warn early enough before food or drinks run out. The situation report showed "Essen 28 Tage" (food 28 days), but in reality it lasted only approx. 10 game days (raw plump helmets are eaten, the display does not scale with the population of 155 dwarves).
**Expected gain:** reaction days before the crisis (trade, farms, pop cap) instead of only at hunger > 40 000, fewer emergency turns.

## As-Is State
`claude/status` delivers `food_days`/`drink_days` roughly; `essen status` delivers meals, plants, PH, meat, fish. Consumption and production are not modeled.

## Model
- **Consumption/day** = population × eating rate; the eating rate is measured: change of the total stock (meals + raw food + meat/fish) per game day without production (time series in `state.db`, median over 5 measurements).
- **Production/day** from time series (harvest jumps, cooking), upper limit plots × tiles.
- **Stock in days** = stock / (consumption − production), with uncertainty band (min/max of the measurement series). Drinks analogous.
- Game day = `year_tick / 1200`; conversion to real minutes at the current fps (`frames_pro_s`).

## Behavior
1. Every `check` updates the time series (≤ 2 KB).
2. Digest line `Essen 11±3 Tage (−0,6/Tag), Getränke 70 Tage` (German; food 11±3 days, drinks 70 days); warning at `< warn_days` (30) or `< crit_days` (10).
3. Action proposals: trade `wants` (raise food/seeds), farms (plots/harvest cycle), population stop (`STRICT_POPULATION_CAP`, only takes effect after restart), playing slower (`tempo`) as an emergency brake.
4. Self-calibration: forecast against reality in the error log, confidence drops with large deviation.

## Configuration
`forecast: {warn_days: 30, crit_days: 10, window: 5, include_raw_plants: true}`

## Fair Play
Read only.

## Acceptance Criteria
1. Replay with synthetic series (stock 100, consumption 10/day, production 2/day): forecast 12.5 days ± 10 %.
2. A harvest jump is not counted as negative consumption.
3. Test "population grows": consumption rises, forecast shortens.
4. Digest line ≤ 120 characters, warning only when exceeded.
5. Backtest on `metrics.csv` Run 5: mean error ≤ 30 %.

## Fixtures/Tests
`metrics.csv` time series Run 5, `essen status` responses, `food.flag` texts.
