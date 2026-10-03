# Trade rules (template for `claude/handel`)

`claude/handel` reads this file from `<runtime>/tools/scopes/handel-regeln.md` (runtime = `DF_LLM_HELPER_HOME` of the
game process, else `<Dwarf Fortress>/df-llm-helper-runtime`). `python -m df_llm_helper install-lua --apply` copies this
template there when no rules file exists; an existing file is never overwritten. Without a rules file `plan`, `mark`
and `select` refuse (BUG-226).

Only the `rules` block below is read. Syntax (one entry per line, `#` starts a comment):

- `key = number`: ratio, ratio_margin, overshoot_tol, min_ratio_confirm, sell_min_value, mark_max, min_ticks_left,
  max_buy_value, broker_unit (unit ID of the designated broker, 0 = best negotiator).
- `sell_types = TYPE TYPE ...` / `sell_exclude = TYPE ...`: item types (df.item_type names) the fort sells.
- `buy <prio> <ITEMTYPE|*> <substring|*> <max_pieces>`: purchase wishes, lower prio first. The first matching line of
  a good counts, so a specific line (e.g. silk) must come before the generic line of the same type. Containers with
  contents (bags, barrels) are only bought with an explicit substring.
- `keep <ITEMTYPE> <n>`: the n cheapest pieces of a type are never sold (mood reserve).
- `weight <ITEMTYPE> <n>`: reserved.

```rules
ratio = 2.3
ratio_margin = 0.06
overshoot_tol = 0.20
min_ratio_confirm = 2.25
sell_min_value = 8
mark_max = 50
min_ticks_left = 900
broker_unit = 0

sell_types = FIGURINE AMULET BRACELET EARRING RING CROWN SCEPTER GOBLET TOY INSTRUMENT TOTEM
sell_exclude = WEAPON ARMOR SHIELD HELM GLOVES SHOES PANTS

buy 1 WOOD * 60              # logs: beds, barrels, charcoal
buy 2 BAR coal 30
buy 2 BAR coke 30
buy 2 BAR iron 20
buy 2 BAR steel 10
buy 3 SEEDS * 20
buy 3 MEAT * 30
buy 3 FISH * 30
buy 3 CHEESE * 20
buy 4 CLOTH silk 10           # silk first (strongest cloth) ...
buy 4 CLOTH * 30              # ... then any cloth (generic CLOTH entry, BUG-226: rope reed, pig tail, cotton)
buy 5 THREAD * 20
buy 5 SKIN_TANNED * 20
buy 6 BUCKET * 4
buy 6 CHAIN * 4

keep FIGURINE 5
```
