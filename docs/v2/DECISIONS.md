# df-llm-helper v2: decisions for Gordon

Gordon answers each decision once. The answer goes into `config/decisions.yaml` and stays there. Until he answers, the default applies, and the default is always "off" or "unchanged" (DESIGN §11.6, §15). The old exception register is retired: there are no cheat consents, and nothing in this file can allow an armok tool.

## How it works
- **File:** `config/decisions.yaml`, one line per decision: `D-NN: value  # comment` (CONTRACTS §9.16). Only bare words or integers, no nesting, no quotes. The Python reader (`schema.parse_decisions`, `fairplay.get_decision`) and the kernel's Lua reader use the same line regex.
- **Answered or not:** a comment that starts with `default` marks an open decision. `fairplay.pending()` lists the open ones. A module that needs an open answer emits `DECISION_NEEDED` (class A) with the id; the LLM passes the question to Gordon in chat.
- **Only Gordon writes the file.** The LLM never edits it, not even to record an answer Gordon gave in chat; Gordon edits it himself or tells the orchestrator to write his exact words. An invalid value falls back to the default, and `python -m df_llm_helper.lint --config` reports it.
- **Allowlist coupling:** some answers only take effect when `config/allowlist.json` also gains a command. The allowlist ships at the defaults, so a forgotten allowlist change fails safe (act.run refuses the command).

## Decisions

| Id | Question | Values | Default | Read by | If not default |
|---|---|---|---|---|---|
| D-01 | Option A (cap ≤75) or B (≥80) | `A`, `B` | `A` | readiness (cap), `plan check` | B: R3 (≥20 % of soldiers in iron or steel) may raise the cap to 80+; plans with `policy.option: B` pass `plan check` |
| D-02 | Difficulty changes (invasion cap, siege frequency) | `unchanged`, or a short word naming Gordon's choice | `unchanged` | nobody (S10 only reads the triggers) | Gordon changes Settings → Difficulty himself; the kernel never writes difficulty settings |
| D-03 | Idle rule | `rule`, `immediate`, `off` | `rule` | economy | `immediate`: act as soon as idle >40 % (Gordon's old memory rule), still only from the useful backlog and never filler digging; `off`: no idle reaction |
| D-04 | `work-now` | `off`, `on` | `off` | baseline | on: add `enable work-now` to `control-panel` (and `enable`) in the allowlist |
| D-05 | `agitation-rebalance` | `off`, `on` | `off` | baseline | on: add `enable agitation-rebalance` to `control-panel` in the allowlist |
| D-06 | tailor confiscate, cleanowned | `off`, `on` | `off` | baseline | off: baseline runs `tailor confiscate false`; on: add `confiscate true` to `tailor` and a `cleanowned` entry to the allowlist |
| D-07 | `visitor_cap` 30, WEATHER off, baby caps (per save) | `unchanged`, `visitor30`, `visitor30_noweather` | `unchanged` | arbiter (`act.setting`) | visitor30: visitor cap 30 at boot; `_noweather`: also weather off. Both are restored on unload; prefs files stay untouched |
| D-08 | caravan `flags1.left` edit | `dropped` | `dropped` | trade | none: stuck caravans use `fix/stuck-merchants` (allowlisted); the unit-flag edit is never offered again |
| D-09 | Cook plump helmets in a famine | `no`, `yes` | `no` | economy | yes: economy may lift the PLUMP_HELMET cook exclusion while food days are below the famine threshold |
| D-10 | emigration, deteriorate | `off`, `on` | `off` | baseline | on: add `enable emigration` and `enable deteriorate` to `control-panel` in the allowlist |
| D-11 | timestream | `accepted`, `rejected` | `accepted` | arbiter, baseline | rejected: arbiter never calls `act.timestream` (game runs at FPS_CAP), baseline does not enable timestream |
| D-12 | Army share | `<low>/<high>` in % | `15/20` | military, readiness | low share applies at pop ≤55, high share from 60 |
| D-13 | Automatic beauty pause at high wealth | `no`, `yes` | `no` | runner | yes: beauty projects pause above a wealth threshold (to be defined); without it, wealth is only logged with every threat event |

## What is never a decision
These stay blocked whatever the file says (allowlist `blocked`, lint, hook): `digv`/`digvx`/`digl`, `digtype --hidden`, `fastdwarf`, `caravan extend|happy`, `autodump`, `locate-ore`, `prospect`, `showmood`, `reveal`, `createitem`, `dig-now`, `build-now`, `fix/retrieve-units`, `teleport`, `lever --instant` (the lever script is used only through `act.pull`, which queues a pull job), every other armok-tagged tool, inline `lua` and the v1 `claude/*` scripts. Reads of hidden tiles, `water_table` or aquifer flags are lint errors.

Actuators with a dedicated act function stay out of the allowlist too (DESIGN §3, one writer each; `fairplay.OWNED`, lint rule `owned-actuator`, hook): `timestream` (arbiter), `pop-control set max-pop` other than the R0 cap 55 (readiness), `overlay enable|disable` (arbiter), `quickfort` (runner, in-memory chunks only), `orders` and `workorder` (economy, `dfllm:` tag), `zone` (care), `burrow` (runner/siege), and disabling `timestream`, `pop-control`, `overlay` or `suspendmanager`.
