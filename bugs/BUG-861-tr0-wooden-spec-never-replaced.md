# BUG-861 A squad taken off the training policy kept its wooden weapon specs for good
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17 i3 Orangering 25.11. (kern.log trace `pos 2 hand wood:SPEAR_TRAINING spec SPEAR_TRAINING (not armed)` after the player's `squad.uniform kind=melee squad A`); suspected for i4 'Trupp A 0 von 3' for 20 game years ('DF assigned piece ..., not worn: nothing wrong with it, the soldier has not picked it up yet').
Module: `lua/dfllm/military.lua` (`ensure_weapons`)

## Root cause
`squad.uniform kind=melee` sets `e.tr = 0` ('a metal kind ends the training policy for good') and keeps worn specs ('squad.uniform never takes off what a soldier wears'): a position whose soldier held a wooden weapon kept its `SPEAR_TRAINING` spec. `ensure_weapons` took a wooden spec out only for squads with `tr == 1` (or `un == 1`) outside PEACE/DRILL, so with `tr = 0` nothing ever replaced it, in PEACE or in an alert: the soldier drilled and met the alert with wood.

## Fix
`ensure_weapons`: a squad with `tr == 0` treats a wooden weapon spec like one of a squad on the policy outside PEACE (it is re-planned to a real weapon) while the census owns real melee weapons (`g_weapon > 0`; with none the wooden spec stays as the fallback).

## What is NOT a kernel defect (named)
- The alert path itself works: with the policy on, ALERT / SIEGE / BREACH re-spec every wooden position to a real weapon (`ensure_weapons`; tests `test_m6_training`, `test_fr100_kit`, new `test_bug860_squad_ready`).
- DF runs the equipment pickup only for a squad that is ON DUTY (BUG-694: an off-duty squad does not fetch its kit). A soldier who holds wood while his real weapon is assigned keeps the wood until his squad has orders; the kernel's equip hold exists only for a squad that stands down in a SIEGE/BREACH. That is DF's behaviour and cannot be proven or fixed offline; the long 'not picked it up yet' on i4 points there (open, to be measured live: squad routine / orders of A in PEACE).
- Items marked for melting: the kernel marks nothing of a squad position for melting; a weapon lying in the `dfllm-melt` / `goblinite` pile is melted by that pile's own rule (`baseline.melt`, which keeps picks, battle axes and crossbows). `M.assigned_real` refuses such a piece, so it never counts toward the ready rule.

## Tests
`tests/lua/test_bug860_squad_ready.lua` ('BUG-861: a squad the player took off the training policy ...'): after `squad.uniform melee` a position with a kept wooden spec gets a real spec within 6 game days (fails without the fix).

## Live-Erwartung
On a fort where the player ran `squad.uniform kind=melee` on a squad that held wooden specs (i3 A): the weapon spec of such a position changes from SPEAR_TRAINING to a real subtype within a few game days (commands.log `act.squad_uniform ... weapon`) (PROMISED when the census holds real weapons). NOT promised: that the soldier picks the weapon up (needs the squad on duty).
