# BUG-456 Small operations findings: brief wording, bone, orders.import, phase.waive reason, planned slots
Status: fixed (offline, live-untested)
Severity: low
Found: 2026-11-05, Run 16c i3 (brief), Run 16a i1 (bone), Run 16d i4 y407 (orders.import, phase.waive), Run 16b i2 y372 (planned slot)
Module: `dfpilot/brief.py`, `lua/dfllm/trade.lua`, `dfpilot/plan.py`, `dfpilot/schema.py`, `lua/dfllm/runner.lua`, `dfpilot/cmd.py`

## Actual and fix
1. brief "starving 53" vs status "HUNGRY 1": the brief's number is `labor.starving` (labormanager postings nobody takes), not citizens. The clause now reads `unfilled labor postings N`; only status HUNGRY / hungry name citizens.
2. `trade.want bone` was ignored (BUG-440 only named it): `bone` / `bones` are tokens (CORPSEPIECE items whose description says bone, cap 6).
3. `orders.import` empty after `phase.waive` hospital: `propose` kept only the libraries of the phases up to the new target (P5 has none of P0..P3's); it now keeps the applied plan's libraries and adds the phase's own.
4. `phase.waive` `why` > 80 bytes was rejected: the verb takes 200, the waiver keeps 80 and the reply says "reason cut from N to 80 bytes".
5. `bp.place workshops only=Kitchen` "0 free sites ... taken by y372s3b2" with that project not begun: `no_site_hint` names a holder of the same template with no kernel row as a planned slot that is the player's: `bp.cancel proj=<id>` frees it at once.

## Tests
`tests/lua/test_bug440_trade_add.lua` (bone), `tests/test_bug450_456_ops.py` (brief, orders.import, planned-slot hint, why 200), `tests/test_status_keep.py`.

## Live check
`trade.want '{"add":["bone"]}'` answers without `ignored`; `phase.waive` with a 150-byte reason is accepted; after it `plan propose` shows the same `orders` imports.
