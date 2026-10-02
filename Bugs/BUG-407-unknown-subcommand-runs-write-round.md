# BUG-407: unknown/typo arguments run a full write round (essen, arbeit, trinken, material, orders, ueberwacher); `claude/erzdig` without `--dry` designates; `mil update`/`mil refuge` ignore the documented `--apply` gate

- **Status:** verified fixed (retest 2026-10-02, 8e67f05) [static code review; lua5.4 not available, mock not run]
- **Severity:** S2 (wrong action on the game from a typo, `--help`, `status` of the wrong script)
- **Area:** `lua/claude/essen.lua:259-278`, `arbeit.lua:534-544`, `trinken.lua:255-269`, `material.lua:455-474`, `orders.lua:417-432`, `ueberwacher.lua:104-113`, `erzdig.lua:109-121`, `mil.lua:555-558,589-613`
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, game running (DF 53.16 + DFHack, **paused**), static analysis

## Command / steps (all NOT run)
```
claude/essen help          # or any word except start|stop|gather|status
claude/arbeit status       # known trap (client.py:28), but also: arbeit --help
claude/trinken foo
claude/material foo        # material: once|start|stop|status, else -> run()
claude/orders foo          # orders: start|stop|status|list|reset, else -> sync()
claude/ueberwacher status  # known trap; any word except start|stop -> check() writes notfall.flag/dig.flag
claude/erzdig              # no argument -> ore='HEMATITE', dry=false -> designates up to 60 wall tiles
claude/mil update          # header: "no change without --apply" -> sets plotinfo.equipment.update.* = true
claude/mil refuge          # header: same -> clearTiles + rebuild burrow 'Zuflucht', may create alert objects
```

## Expected
Unknown subcommands answer with usage and change nothing. Header of `mil.lua`: "Protection: pcall everywhere, log, no change without --apply". `erzdig`'s documented dry run is `--dry`; a missing argument should print usage.

## Actual (from the source)
- essen.lua:276 `local m = (cmd == 'status') and measure() or run()` - every other word (including a typo of `stauts`) runs `run()` (sets kitchen bans, marks plants for gathering, creates fishery/kitchen jobs, writes state/essen.json). `arbeit.lua:541`, `trinken.lua:266`, `material.lua:469-473`, `orders.lua:429-432`, `ueberwacher.lua:110-111` have the same `else -> do the work`. The Python side knows only two of them (client.py:28 comment and `_NO_STATUS`).
- `erzdig.lua:114`: `a[1] or 'HEMATITE'`, `dry = false` unless `--dry` is given -> `claude/erzdig` alone (or `claude/erzdig HEMATITE`) designates dig tiles and runs the map scan (see BUG-415 for runtime).
- `mil.lua:555` (`update`) and `:589` (`refuge`) have no `dry` branch although `dry = not opt.apply` exists for the other subcommands. `gefahr.lua` calls `claude/mil refuge` itself when the refuge check fails (`refuge_check(S, true)`), `watchdog.lua:378` too, so this is partly intended - but then the header must say so, and `mil refuge` must not call `clearTiles` when `cfg.ZUFLUCHT.rects` is empty (it would wipe the refuge burrow of the civilian alert).

## Evidence
none needed (code reading; the `else` branches are quoted above).

## Analysis (reporter's hypothesis)
Historic pattern "no argument = do the periodic round once" extended to "anything else = round".

## Suggested fix (optional)
`else` branch -> `util.emit({ error = 'unbekannt: '..tostring(cmd), usage = ... })` for essen/arbeit/trinken/material/orders/ueberwacher; keep the empty argument as `once` only if the empty string is intended. erzdig: require an ore argument. mil update/refuge: add `if dry then out({ would = ... }) return end`.

## Info needed
- Player: do you want the no-argument default (`claude/essen`, `claude/trinken`, `claude/material`, ...) to stay "run one round"? (README of the helper says `status` is the read command.)
- Decided (player delegated the decision): keep "no argument = run one round" for essen/trinken/material/arbeit/orders/ueberwacher, because the orchestrator, the watchdog and the scopes rely on it; document it.

## Fix
essen/arbeit/trinken/material/orders/ueberwacher: unknown words -> JSON usage error, no round (no argument and `once` still run one round; ueberwacher got a read-only `status`); erzdig without ore -> usage; `mil update`/`mil refuge` need `--apply` (gefahr/watchdog/rb04/scopes.yaml pass it), refuge keeps the tiles when `ZUFLUCHT.rects` is empty. Info needed (player): keep 'no argument = one round'?

Decision applied (ae17aef): behaviour confirmed and unchanged. Every script header now says "No argument (or `once`) = run ONE round now", why the default stays, and which command is read-only (`status`; `orders` also `list`; `arbeit` none, use `claude/auslastung`); COMPANION.md has the same paragraph. Test `test_round_scripts_document_the_no_argument_default`.
