# BUG-802: the quiet PEACE raise of B1 sealed the gate when its levers lay outside Kern+ (fail closed one way only)

Status: fixed (offline, live-untested). Round: Neuausrichtung 1 (P5 Tore, verifier retry). Full design: `docs/v2/NEU1-tore.md`.

- **Symptom (review of the first P5 implementation):** with D-14 `inner` and every linked lever of B1 outside Kern+ (the layout
  of run-16a Basementflew y544 and run-16c, FR-BUGS "levers lie outside the alert burrow"), the PEACE pass raised B1 (a puller
  walked out to the lever), then `gate.fail_closed` refused every later lowering (caravan, migrant, return window): a permanent seal.
- **Cause:** `lua/dfllm/gate.lua` `peace_want` returned `up` / `peace_gates` without checking `M.missing`; `fail_closed` (via
  `down_guard`) then refused the lowering for the reason the raise ignored.
- **Change:** `peace_want` keeps a bridge that is not up DOWN in quiet PEACE while `M.missing` names something (why
  `cannot_close_again`, GATE C `fail_closed`, rate-limited); `observe` marks a kernel PEACE raise in the persisted `m.gate.pup`,
  and `fail_closed` exempts such a bridge in PEACE without a lockdown so the windows keep working when a gap opens later.
- **Tests:** `tests/lua/test_neu1_tore.lua` (two BUG-802 cases), `tests/lua/test_neu1_tore_stranded.lua`.
