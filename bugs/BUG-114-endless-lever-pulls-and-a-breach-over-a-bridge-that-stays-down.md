# BUG-114 The kernel pulls the lever of a bridge that never rises every few seconds for weeks, BREACH waits for it, and nothing says why
Status: fixed in the M3 commit (offline, live-untested): pulls without effect are bounded (`gate.pull_cap`, a give-up with a
GATE_FAIL that names the reason, one test pull per wait), a BREACH over bridges that stay down falls back to SIEGE
(`breach.stuck_ticks`) when nobody is inside or near, and the status says what a BREACH waits for. Why the real BREACH did not
end with "0 visible" is not decided offline.
Severity: high (the fort stayed in BREACH for 40 days: clock at 29 t/s, civil alert, Gordon wanted the clock back)
Found: 2026-10-28, Run 14 (Trussroads) y707 Sommer d83 - Herbst d1, game session note 97 (bridge X25718, lever 25729, soldier 39052
of squad 111 on the footprint, GATE_FAIL "not up after 1712 ticks", LEVER pulls #29353..29356 with new jobs)
Module: `lua/dfllm/gate.lua` (`noeffect`, new `giveup`, `not_up`), `lua/dfllm/siege.lua` (`breach_stuck`, `failed_bridge`, `state`),
`dfpilot/brief.py`

## Actual
Goblin gone ("0 visible", `threat 0 vis`), Kern+ alert again, but BREACH (40 d) / DEFCON 1 stays. Bridge X25718 `down`; GATE
"waits: soldier 39052 on the footprint (squad 111)", GATE_FAIL, and the kernel pulls lever 25729 every few seconds with new jobs
without success. RULES section 7: "BREACH falls back to SIEGE as soon as all gates are up", which never happens.

## Cause (proved from the code at 32994bb)
1. **The pull is parked, never given up.** BUG-068's `M.noeffect` (gate.lua:977-1000) parks a lever after `NE_MAX` (3) pulls
   without effect for `wait * min(2^(k-1), NE_TIMES)` (:987, 8x at most; a quarter of the wait in SIEGE/BREACH, :986), and the
   record is cleared by a mode change (:802). A bridge that never moves is therefore pulled again every 2,400 ticks at the
   slowest (at 30 t/s: every 80 s) for ever, each time with a new job, and the only report is one LEVER_NOEFFECT per lever.
   `check_fail` (:1632) gives one GATE_FAIL at the deadline (`br.failed`), which names `no_effect`/`blocked` but not who stands on
   the footprint or what the pulls did.
2. **BREACH has two exits and both need something the situation does not give.** `siege.decide` BREACH (siege.lua:734-736):
   `quiet_for` (no invader at all, a.inv == 0, threat.lua:195) or `breach_sealed` (:654: every manifest outer/inner bridge up,
   seal's route check says sealed, no hostile on a citizens' walk group). A bridge that stays down (a manifest one, or an
   unmanaged `X<id>` bridge that seal counts as a route) blocks the second for ever; an enemy that stays in sight blocks the first.
3. **The status does not say what BREACH waits for.** `siege.state` returned `wave` only in SIEGE or with a running wave
   (siege.lua:2110-2113); the BREACH line of the brief/status is the bare mode.
4. **Not proved:** with 0 visible hostiles the BREACH should end by `quiet_for` after 2,400 ticks, in the offline fixture it does
   (test 5 of test_m3_breach.lua, the bridge stays down), so what held the real BREACH (a unit counted but invisible to the
   session, a census older than 200 ticks, a RECOVERY that fell back into BREACH, a hostile inside) is not decided offline.

## Fix
- `gate.giveup` (config `gate.pull_cap` 15, `gate.giveup_wait` 7200): the no-effect pulls of a bridge are summed over its levers;
  at the cap every linked lever is parked for the wait (doubled per give-up, 8x at most), `br.failed` is set and a GATE_FAIL (A,
  `why` no_effect, `pulls`, `wait`, `lever`, `units`) says `X25718 not up: 15 pulls without effect, no pull for 7200 ticks; soldier
  39052 on the footprint (squad 111); lever 25729: 15 pulls, no worker took one (DF dropped every job: no path to the lever?)`.
  After the wait one test pull is made (the counter is still at the cap); a failed one gives up again; a pull that moves the bridge
  clears the record; a mode change is a new try (BUG-068). DRILL gives up silently as before.
- `gate.not_up()` lists the bridges wanted up that are not, with the reason (who blocks, no effect + the wait left, every lever
  parked, a pull under way or queued), their want's age, whether GATE_FAIL came and the nearest hostile's distance.
- `siege.breach_stuck` (config `breach.stuck_ticks` 2400, 0 = off): BREACH for that long, a fresh census, nobody inside Kern+, the
  quiet clock not running (nobody in sight would end it by itself), every bridge not up has failed and was wanted for that long,
  no hostile within 30 tiles of one, soldiers (if any) at their stations: SIEGE with SIEGE_START why `bridge_stuck`; the manifest
  bridges are marked (`m.siege.stuck`) so `failed_bridge` does not make a BREACH of them again until a hostile comes within 30
  tiles; the marks end with the episode.
- Status: state `wave.ba` (ticks since the BREACH began) and `wave.bw`; brief/status print `BREACH since 40.0 d: waiting for X25718
  up: soldier 39052 on the footprint (squad 111); quiet clock: 1 invader in sight` (or `quiet 1300 of 2400 ticks`, `1 hostile
  inside Kern+`, `no fresh census`).
- Wish (d) "clock free again two days after the last enemy": a BREACH with no enemy in sight is RECOVERY after 2,400 quiet ticks
  (MODE_FPS RECOVERY 250, no cap), pinned by a test; the BREACH line now says how far the quiet clock is, so the next
  live case shows why it did not run.

## Not decided offline
- The cause of the real BREACH with "0 visible" (above, 4): read-only `dfllm status` (`BREACH since ...: ... quiet clock: ...`),
  kern.log MODE lines with `why`, `events --type SIEGE_START`, the census age (`census.h.tick` against the game tick).
- Why bridge X25718 did not rise with the soldier gone: GATE_FAIL `no_effect` now carries `worker`/dropped per lever; whether DF
  refuses to raise a bridge with a unit or item on it is a live question (`units.isUnitInBox` on the footprint, items on it).

## Tests
`tests/lua/test_m3_gate.lua` (4; 3 fail on 32994bb) and `tests/lua/test_m3_breach.lua` (5; 4 fail on 32994bb; the fifth pins the
existing quiet-clock exit). `tests/test_m3_files.py` (config ranges, the contract of GATE_FAIL / state `wave`, the brief line).

Related: BUG-027, BUG-028, BUG-068, BUG-082, BUG-112
