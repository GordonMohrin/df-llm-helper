# v1 legacy: what left branch `v2` and where it is

Date 2026-10-11. Branch `v2` holds only what v2 uses (DESIGN §9). The complete v1 tree stays in the tag
**`v1-final`** (commit `07caf81`, BUG-435). Read v1 files from there; do not copy v1 scripts back into `lua/`,
because repo A's `lua/` is on DF's script path (DESIGN §9, STATUS §6.11).

```
git show v1-final:docs/MANUAL.md                    # read one v1 file
git ls-tree -r --name-only v1-final -- Bugs/        # list a v1 folder
git worktree add ../df-llm-helper-v1 v1-final       # the whole v1 tree beside this one
```

## Removed from `v2`
| Path (as in `v1-final`) | What it was |
|---|---|
| `df_llm_helper/*.py` except the v2 modules, `df_llm_helper/_v1/`, `features/`, `planners/` | v1 Python helper: dfhack-run client, digest, autopilot, guard, waechter, runbooks, kb, bus, journal, dashboard, siege/caravan/care pilots, store, clock, stalllog, toolsfs. `planners/blueprint.py` lives on as `bp/validate.py`; `lint` and `fairplay` keep only their v2 code (the v1 forwarding is gone) |
| `lua/claude/`, `lua/pilot_*.lua` | v1 DFHack scripts (`claude/*`) and the pilot companions |
| `tests/test_*.py` of v1, `tests/conftest.py`, `helpers.py`, `make_fixtures.py`, `kb_queries.yaml`, `lint_cases/`, `blueprints_bad/`, `lua_mock/` | v1 tests and their fixtures |
| `fixtures/{bugs,run5,run5_live,subagents,v3,wake}` | recorded v1 (Run 5) responses; `fixtures/v2` stays |
| `data/` | v1 runbooks, kb, camera, rules, scopes, services, settings, trade wants, exception register |
| `scenarios/`, `examples/windrings/`, `blueprints/r5_notwand.csv` | v1 replay scenarios, the Run 5 `config.lua`, a Run 5 blueprint |
| `Bugs/`, `Features/` | the v1 bug and feature database (BUG-100 to BUG-435, FEATURE-001 to 006) |
| `docs/MANUAL.md`, `INTEGRATION.md`, `OVERVIEW.md`, `SPEC.md`, `AGENT-PROMPT.md`, `PLANNERS.md`, `LINT-FINDINGS.md`, `docs/manual-v3`, `docs/specs-v2`, `docs/specs-v3`, `COMPANION.md` | v1 documentation |
| `config.yaml.example`, `tools/luacheck_min.py` | v1 config template and the v1 Lua structure check |

`BUG-nnn` and `FEATURE-nnn` cited in v2 docs and code comments refer to `Bugs/` and `Features/` in `v1-final`,
for example `git show v1-final:Bugs/BUG-427-lever-list-bridge-state-always-raised.md`.

**Local files** that git never tracked (Gordon's v1 `config.yaml`, `runtime/`, the `dfpilot/` caches,
`data/state.db`, `data/exceptions.local.jsonl`) were moved, not deleted, to
`C:\Users\admin\claude gordons projects\_archive-v1\dfpilot-public-local-2026-10-11\`.

The v1 player decisions (MANUAL §8, 2026-10-01: exception register, consents, `flags1.left`, token budget) are
superseded by [DECISIONS.md](DECISIONS.md) and `RULES.md`.

## v1 lessons that still hold
Observations from the v1 runbooks (SPEC appendix A, Runs 2-5) that DOCTRINE, RULES and CONTRACTS do not
already carry. They were seen on DF 50.x-53.x with v1 tooling and have not been re-measured under v2.
- **Dig priorities:** v1 scripts that wrote raw priority values (≠ 4000) on single dig tiles stalled the dig jobs.
  Set dig priority only through quickfort's `priority` (the vanilla 1-7 designation priority, as runner does).
- **Ghost items:** an item with `pos.x < 0` that is not in a container is not really in the fort; do not count it
  as stock.
- **Work details:** `Stonecutters` or `Engravers` in "everybody does this" mode pulled every dwarf onto smoothing
  and engraving while the dig queue starved. Such details should name 2-3 dwarves.
- **Quickfort twice:** running the same zone blueprint twice creates a second, overlapping zone (v2's one-zone-per-
  coffin rule, DESIGN §5.10, is the same lesson).
- **Git Bash:** pass `MSYS_NO_PATHCONV=1` when a DFHack argument looks like a path (`/x`), or MSYS rewrites it.
- **Embark UI:** fast click sequences and double clicks on the embark screens crashed DF; keep `tools/embark`'s
  clicks spread over frames (`input.lua`).
