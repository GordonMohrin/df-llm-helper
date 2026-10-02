# Example: fortress "Windrings" (Run 5)

Real, filled-in map configuration from the run the project was developed with (DF 53.16, desert embark, world tile
(26,10), year 100–110). Use it as a reference for what the values look like – **do not install it on another map**:
coordinates, burrows, interior boxes and dig stages only make sense on that map.

| File | Shipped version | This example |
|---|---|---|
| `config.lua` | `lua/claude/config.lua` – neutral (nil/empty), defaults derived from the loaded map | all values set after embark (surface z133, fort 96/96, refuge burrow, interior boxes, slabs, mood slots, smoothing area) |
| `stages.lua` | `lua/claude/stages.lua` – empty | 35 exploration/residence dig stages N1..N35 (z104..z124) |

To start from it on a similar map: copy the file to `<Dwarf Fortress>/hack/scripts/claude/`, then go through the
checklist at the top of `config.lua` and replace every value.
