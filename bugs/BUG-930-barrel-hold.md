# BUG-930 Lowered pile barrel limits are HELD and given back in steps (i4 Girderroots y501-y504: the 14-day bound and the 'DF kept the registration' verdict gave every limit back, the cancels were back in 6 days, the release never ran again)
Status: fixed (offline, live-untested)
Severity: high (i4 drink 387 d -> 0 d, 51 Stills idle, 135-167 brew cancels a week)
Found: Run 17 i4 Girderroots, kernel main 0f4f08a4 (round 17b of BUG-918), DF E:/DF-test4, read from DIAGNOSE-i4-fass-17c (kern.log, events.jsonl, why brew / pile --raw, inspect census).
Module: `lua/dfllm/economy.lua` (`M.pile_release`, `M.release_measure`, `M.release_giveback` new, `M.cx_end`, `M.cx_reason`, `M.cx_log`), `config/baseline.json` + `dfpilot/fairplay.py` (economy.cancel.give_*), `dfpilot/schema.py` (phase `giveback`)

## Symptom (proven in the live logs)
- y501 day 73: PILE_BARREL_RELEASE lowered 106 piles; registered empties 108 -> 14 in 7 d, cancels 22 -> 0, 5 brews finished.
- The limits went back after 8 days (14 piles: verdict 'DF kept the registration') and after 14 days (94 piles: `REL_MAX_D` time bound). Cancels were 1, 6, 9, 12, 14, 15 per week from then on, 135-167 from y503 d157. Drink 387 d -> 0 d.
- `p.relstop = true` (set by the verdict of 14 of 108 piles) was never cleared: no release event after 202108984 although the gate was ON.
- `cx_end` (brew_watch 'containers came back', cx_expire) also handed the lowered limits back through `p.pilecap`; the hysteresis latch `st.cxh` was session-only.

## Cause (file:line before the change)
- economy.lua:2309 `p.relstop = true` read at 2335 (3 hits, never cleared): one 'kept' verdict switches the release off for good.
- economy.lua:2312 `release_restore(... 'DF kept the registration')` and 2329-2331 `REL_MAX_D = 14` time bound: limits go back although the shortage stays.
- economy.lua:2351-2352 (limits copied into `p.pilecap`) + `cx_end` 2470-2487: any cure end restored them.
- economy.lua:4675 `st.cxh` session table: a reload forgot the hysteresis latch.

## Change
- No `relstop`, no time bound, no restore on the d7 verdict: the verdict only keeps NEW piles from being lowered for 30 days (`p.relnext`). A `p.relstop` persisted by the old code is dropped at the first call (economy.lua `M.pile_release`).
- A lowered limit lives in `p.relpiles[id] = {old, cur, t}` (old = the limit before the FIRST lowering), `p.hold = {ok, step, stepping}`; it is no longer written into `p.pilecap`, and `M.cx_end` skips every id in `p.relpiles`. `cancel.release = false` is the only way back at once.
- `M.release_giveback` (new, called from `M.pile_release` every day): gives back only when the usable empties (census `cont_free`, one counter for gate, status, events and give-back) stayed >= `cancel.give_target` (20) for `cancel.give_days` (28) game days with the DF container gate OFF; then +`cancel.give_step` (3) per pile every `cancel.give_every_d` (7) days, never above the old limit; each step is a PILE_BARREL_RELEASE `phase giveback` event (before, after, free0 = cont_free, cx0). cont_free under the target restarts the 28 days. DF's container reason (gate ON) during the steps: the timer resets and the same call lowers the piles again at once (new d0 / d1 / d7 measurement, `old` kept).
- E3 persistence: `p.relpiles`, `p.hold` and the hysteresis latch `p.cxh` (was `st.cxh`) are in the persisted `m.economy` state; a reload neither restores nor forgets.
- E2: the counter in the release events and the none-line is named `usable empties (cont_free, registered ones not counted)`. The snapshot's 'free empties N' (brewsnap, registration not subtracted) is a different set; its own line 'pile-reg free R/N' says how many of them are registered.
- Unchanged: only kernel food piles except dfllm-drink / dfllm-mood, never below the barrels with contents, player piles untouched, act only with DF's reason (gate), d0 / d1 / d7 events.

## Tests
`tests/lua/test_bug930_barrel_hold.lua` (8): i4 timeline (lowering, d7 verdict, 15 days, cure OFF, 120 days of cont_free 0, registration back: held, no event); give-back (not before 28 days with gate off, +3 per pile, one step a week, 4 -> ... -> old limits, drink / player pile untouched, events); interrupted plenty restarts; DF cancels during the steps re-lower at once; reload (latch, hold, plenty timer); nothing without DF's reason; switch off restores; counter name. Adapted: test_bug918b_fass_release.lua, test_bug918_pile_release.lua (limits now stay), tests/test_neu3_diag.py (new config keys).

## Live-Erwartung (every line is what the code writes; none is read from a live run yet)
- kern.log: `pile barrel release: stockpile ID (dfllm-stock) barrel limit 9 -> 0 ...` once per pile; after that NO `pile barrel release over (DF kept the registration)` and NO `(time bound of 14 days)` line.
- PILE_BARREL_RELEASE `lowered`, `d1`, `d7` as before; the d7 verdict reads `DF kept the registration of this pile (BUG-930: the limit stays lowered, ...)` or `the registration fell`, and `usable empties (cont_free, registered ones not counted) a -> b`.
- The limits stay (`why pile:<id> --raw` max_barrels 0 / 1) for weeks, also with the cure OFF and cancels 0.
- Only after `cont_free >= 20` for 28 days with no DF container reason: kern.log `pile barrel release: stepwise give-back: N piles raised by 3 (usable empties X >= 20 for 28 d), M still held`, weekly, PILE_BARREL_RELEASE `phase giveback` per pile (before -> after); final `pile barrel release over: every held limit is back at its old value`.
- If DF's cancels return during that: `pile barrel release: DF cancels brews for want of a container again while the limits were given back in steps: the piles are lowered again at once`, new `lowered` events.

## Not proven (stays open)
- That DF excludes pile-registered empties from a brew job at all: the 5 brews of y501 finished only in the lowering window, but 'taken-accumulator 232 of 234' were pile-registered. Which counter (cont_free minus registered, or the snapshot's free) matches DF is UNPROVEN; cont_free is used as the single decision counter because brews ran only while registrations were low.
- Why cont_free read 0 -> 0 at d7 although registered empties fell 108 -> 14 (free 79 minus 14 should be positive): not explained by the logs.
- The standing cap (`pile_standing`, written on no pile because every pile accepts drink) is unchanged; the 145-cancel wave since y503 d157 (civ-alert / burrow block, MakeBarrel order 1775 'Forbidden area') is an ASSUMED second cause and is not fixed here (no BUG-931).
- That holding the limits at the full-barrel count does not starve food storage of barrels on a pile that accepts food.
