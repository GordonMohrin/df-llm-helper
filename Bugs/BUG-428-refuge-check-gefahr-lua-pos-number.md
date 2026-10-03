# BUG-428: `claude/mil refuge check` bricht mit "attempt to index a number value (local 'pos')" ab

Live-Lauf 04.10.2026 00:20 nach `install-lua --apply` (Stand 3ed6844), Razordrums (Burrow 0 "Zuflucht", 44 Kacheln, config.ZUFLUCHT gesetzt).

- Aufruf: `dfhack-run claude/mil refuge check`
- Ausgabe: `{"error": "...lua/claude/gefahr.lua:229: attempt to index a number value (local 'pos')"}` (Funktion `in_burrow(b, pos)`).
- Folgewirkung: Der Digest meldet `NOTFALL ZUFLUCHT OHNE ESSEN: keine Nahrung im Burrow`, obwohl das Burrow 285 Nahrung enthaelt (per Lua gezaehlt). Verdacht: `in_burrow` wird irgendwo mit einer Zahl (Index/Blockkoordinate) statt einer Position aufgerufen, Folgefehler = falsche MISSING-Kategorie.
- Zusatz: `python -m df_llm_helper refuge check` meldet "claude/pilot_refuge info not readable"; `loops list` meldet "no registered loops" (die Schleifen laufen, wurden aber nicht per `loops wrap` gestartet).
- Erwartung: Pruefung laeuft durch und zaehlt Nahrung/Getraenke in Barrels/Bins im Burrow.

## Nachtrag (04.10. 00:45): Ursache gefunden, lokal behoben
Ursache: `dfhack.items.getPosition` liefert in DFHack 53.16 drei Zahlen (x,y,z), kein pos. `pcall(dfhack.items.getPosition, it)` ergibt dann `ok, x, y, z`; der Code nahm `p = x` (Zahl). Betroffen: `lua/claude/gefahr.lua:260`, `lua/pilot_refuge.lua:95` (gleiches Muster in handel.lua:306). Fix: `if type(p)=='number' then p = xyz2pos(p, py, pz) end`. Danach laeuft `mil refuge check`.

Offen (neu, BUG-429?): Getraenke in Barrels zaehlt der Check nicht (Items im Fass haben `in_inventory`, `usable()` verwirft sie): Status `drink MISSING` trotz ~390 Getraenken im Burrow (z101, Elev. 1). `hospital MISSING` obwohl das Neufort-Hospital (Ort 24, z104) im Burrow liegt, weil Ortsposten/Zone anders zugeordnet sind.
