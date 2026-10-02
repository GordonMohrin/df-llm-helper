# Live results (local orchestrator, real game: DF 53.16 + DFHack)

## 2026-10-02 (fort date 8.-15. Malachite, year 121), commit ae17fff + 4ac3f16

| Bug | Check | Result |
|---|---|---|
| 211 | `defense stats --tail 200000` on the 146 MB gamelog | 10 announcements (= 7 ambush, 2 snatcher, 1 vile force), 0.9 s: fixed |
| 210 | `hygiene` after deploying the new `pilot_hygiene.lua` | `areas: fort=12114` (> 0, was 0): fixed |
| 221 | caravan at depot, 2 haul jobs stuck, game paused | MARK waited, after 600 s `MARK -> OPEN (2 haul jobs still open after 600 s - opening with the goods in the depot)`, then SELECT_DRY, REVIEW: fixed |
| 222 | REVIEW -> approve -> CONFIRM -> FINISH -> RELEASE -> RESUME -> DONE | approve path works; the `REVIEW -> WAIT` branch (no immediate approval) not exercised yet |
| 223 (new) | PAUSE step | fails with `pause has no effect` also with timestream OFF; cause: the step never writes `tools/pause.hold`, a pause guard releases the pause within 2 s |
| 224 (new) | stale `pause.hold` | game frozen for long, no warning; see report |

Trade with the human caravan from Muboomon: 64 items bought (wood), 45 sold (cloth, jewelry), ratio 2.46 vs. required 2.43, state DONE.
