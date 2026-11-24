# BUG-848 `sp.max_barrels` is unreadable on DFHack 53: `act.pile_barrels` failed silently, the item sample printed `max_barrels=?`
Status: fixed (offline, live-untested)
Severity: high
Found: Run 17d i4 Girderroots (main 4081ef70, DFHack 53.16/53.17), 24.11.2026 23:00: `why items:barrels --raw` printed `stockpile=#18286(dfllm-stock max_barrels=?)` for every pile; the BUG-834/844 pile freeze (the plant piles take no new barrel while a Still finds none) could not act and said nothing.
Module: `lua/dfllm/pilelib.lua` (new), `lua/dfllm/act.lua` (`I.pile_barrels`), `lua/dfllm/economy.lua` (`M.cx_freeze`), `lua/dfllm/dfraw.lua` (`R.sample_item`, `R.pile`, `R.find`, `R.stall_line`), `lua/dfllm/jobwhy.lua` (`J.find0`), `dfpilot/cli.py` (help)

## Root cause
The field is not on the stockpile building itself. DFHack's own code (E:/DF-test4/hack/scripts/internal/quickfort/place.lua: `db_entry.props.storage.max_barrels = ...` at lines 196/218, `init_containers` 272-276, applied with `utils.assign(bld, props)`) keeps the container limits in the building's `storage` struct: `bld.storage.max_barrels`, `max_bins`, `max_wheelbarrows`; -1 = no limit. `sp.max_barrels` raises on a real struct and the code's `pcall` hid it (BUG-834 marked the field [live-untested]).

## Fix
`pilelib.lua`: candidates `storage.max_barrels` (DFHack 53), then `max_barrels` (older structures, the fake world); `P.get`, `P.set` (writes through the candidate that reads and verifies the read-back), `P.probe`. `act.pile_barrels` freezes and restores through it; when food piles exist and NONE answers it returns false 'no barrel limit field on N food stockpiles (tried storage.max_barrels, max_barrels)'. `economy.cx_freeze` then logs ONE error line per load ('brew stall: the stockpile barrel limit cannot be read or set, the container cure for the plant piles cannot act ...'); the weekly brew `raw stall` line carries 'pile limit field=storage.max_barrels (n of m piles read)' or 'pile limit field UNREADABLE on N piles (tried ...)'. The item sample prints `max_barrels=<value>@<field>` or names the candidates. New raw dump `pile:<id>` (`inspect what=raw key=pile:<id>`, `dfpilot why pile:<id> --raw`): the building's generic fields, `storage`, `stockpile_flag`, `settings.flags`, `links` (give/take pile and workshop ids), the barrels lying in it (with / without contents). `ws:<id>` of the raw dump accepts a stockpile id (prints the pile dump); `why ws:<id>` (jobwhy) says 'building <id> is a stockpile, not a workshop: why <id> --raw (key pile:<id>) dumps it'.

## Tests
`tests/lua/test_bug847_848_reader_pile.lua`: pilelib candidates / set read-back / a struct that raises / probe; `act.pile_barrels` freeze + restore on `storage.max_barrels` and on the flat field, and the explicit failure with no field; one loud log line and the stall line text; `pile:<id>`, `ws:<id>` on a stockpile, `pile:99` refused, `why ws:<id>`.

## Live-Erwartung
1. `python -m dfpilot why pile:18286 --raw` on i4 prints 'pile 18286 dfllm-stock ... barrel limit <n> (field storage.max_barrels ...)' and the storage struct; the item sample of `why items:barrels --raw` shows `max_barrels=<n>@storage.max_barrels`. PROMISED if DFHack 53.x matches the quickfort code that ships with it.
2. With a DF reason of >= 5 'Needs empty food storage item' cancels the plant piles that hold a barrel are frozen at the barrels they hold: kern.log 'brew stall: stockpile <id> (<name>) takes no new barrel: limit -1 -> <n>' (EXPECTED; needs a food pile that holds at least one barrel). If the field is still wrong: the one error line and the 'pile limit field UNREADABLE' stall part name it (PROMISED, never silent).
3. NOT promised: that a frozen pile frees an empty barrel for the Still (the haulers' other uses of barrels are unproven).
