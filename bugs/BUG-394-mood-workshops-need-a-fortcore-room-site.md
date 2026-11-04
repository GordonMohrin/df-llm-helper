# BUG-394 the workshops a strange mood needs were placed only in a fortcore room: with no site the Possessed dwarf waited for 'no Craftsdwarfs'
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-04, Run 16 round 2 (i1 Bachwald `r16a-bachwald-site97`: `[unit 26401 workshop,timer] ... Possessed ... no Craftsdw...` until placed by hand; i2, i3 the same)
Module: `dfpilot/wake.py` (`workshop_tries`, `_place_workshops`, `_place`)

## Actual
i1 cli.log: 24 x `AUTO_FAIL workshops: site S1: only 0 free site(s) for workshops ... (0 ranked)`; the mood request of the kernel (`PROJECT_REQUEST workshops why=mood
types [Craftsdwarfs]`) never became a project. MOOD_CRITICAL `workshop` woke four times (spring d25, d45, d55, d64 of y377); the dwarf claimed a shop only after a shop was
placed by hand. i3 needed a Jewelers/Leatherworks/Tanners the same way (kern.log `workshops requested at prio 1 (only these)` and then nothing).

## Root cause
`dfpilot/wake.py` `_on_event` (the `why == mood` branch) -> `_request_place` -> `_place`: one `bp.place workshops S1 {skip, add}` call. Without a fortcore (or with its
levels excluded as wet, i2) `bp.sites.rank` has no room site, `cmd.place` raises `only 0 free site(s)` and the job is dropped; the surface placement of BUG-356
(`workshops surface=1`, the startup style) was used by the starter only. farms had the fallback since BUG-340 (`farm_tries`), shops did not.

## Fix
- `wake.py` `workshop_tries(params, mode)` (:1245): the request's params, then in PEACE the same named selection (`skip`/`add`) as `surface = 1` (open surface floor, no dig, no door). A
  plain request without a selection keeps one try (surface=1 alone would be the four startup shops).
- `Follower._place_workshops` (:1171), used by `_place` for every workshops request except the PLAN_EXHAUSTED starter (:1157): tries in order, the first that places is sent (cli.log
  `BUG-394: no room site for ...: placed on the surface`); none: the room error plus `BUG-394: surface=1 too: <surface error>`.
- BUG-395's `mood_deadline` decision carries `bp.place workshops only=<shops> surface=1` for the same case; the MOOD_WS hint says it.

## Tests
tests/test_bug393_395_mood_stone.py (5 for this bug).

## Open
- A surface shop stands outside Kern+ (like the startup shops): a siege can reach it; the mood dwarf walks there in PEACE. A later fortcore room set can replace it.
- No flat 3x3-per-shop block of open ground: `AUTO_FAIL ... surface=1 too` names it (fewer shops: only=...).

## Live check
A reclaimed fort without a fortcore and a mood without a workshop: cli.log `auto:workshops` `BUG-394: ... placed on the surface`, a `workshops` project with
`surface:1` params, the shop built, `MOOD_CRITICAL workshop` ends.
