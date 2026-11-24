# BUG-838 a second Still is never used: the brew order stays bound to the first
Status: fixed (offline, live-untested)
Severity: medium
Found: 2026-11-24, Run 17 i1 Diedplank y380 (order 414 bound to shop 17697, the new second Still unused, Still 17697 'has no job')
Module: `lua/dfllm/economy.lua` (`M.brew_diag` `orders.pin_still`, `M.brew_cause` cause `pinned`)

## Root cause
`brew_cause` named `pinned` only when the order's workshop was no standing Still; an order pinned to a live Still beside an idle second one fell to `nojob`.

## Fix
`brew_diag` counts orders bound to a standing Still (`pin_still`); with two or more Stills and another Still holding no job the cause is `pinned` ('N brew orders bound to Still A while Still B holds no job'), fix `relax` (the kernel's brew orders are made again with no pin and no item condition, as for the other `nojob` cures). A player order the kernel does not own stays (`orders.cancel` refuses supply orders; reported only).

## Tests
`tests/lua/test_bug834_838_brew_chain.lua` (two Stills, the order bound to the first: cause named, relax set).

## Live-Erwartung
1. The brew stall line names `bound to Still A while Still B holds no job` and kern.log shows the brew orders taken down and made again; the second Still gets a job within 3 days (`why ws:ID`).
2. If the order is not the kernel's it stays: the line is still printed and the player removes it by hand.

## NEU3 (diagnostics first)
This cure acts on a cause that was never confirmed live (two verifiers rejected it). It is now behind `economy.diag.still_pin` (default **false**, config/baseline.json): with the switch off the fort behaves as before this bug (no `pinned to one Still` verdict and no re-make of the orders; the orders bound to a Still show in the raw dumps). The reporting part (texts, `dfpilot why`) stays on. Turn it on only after `inspect what=raw` / the kern.log stall line named this cause (docs/v2/NEU3-diagnose.md, BUG-839, BUG-840).
