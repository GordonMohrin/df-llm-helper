# BUG-428: `claude/mil refuge check` bricht mit "attempt to index a number value (local 'pos')" ab

Live-Lauf 04.10.2026 00:20 nach `install-lua --apply` (Stand 3ed6844), Razordrums (Burrow 0 "Zuflucht", 44 Kacheln, config.ZUFLUCHT gesetzt).

- Aufruf: `dfhack-run claude/mil refuge check`
- Ausgabe: `{"error": "...lua/claude/gefahr.lua:229: attempt to index a number value (local 'pos')"}` (Funktion `in_burrow(b, pos)`).
- Folgewirkung: Der Digest meldet `NOTFALL ZUFLUCHT OHNE ESSEN: keine Nahrung im Burrow`, obwohl das Burrow 285 Nahrung enthaelt (per Lua gezaehlt). Verdacht: `in_burrow` wird irgendwo mit einer Zahl (Index/Blockkoordinate) statt einer Position aufgerufen, Folgefehler = falsche MISSING-Kategorie.
- Zusatz: `python -m df_llm_helper refuge check` meldet "claude/pilot_refuge info not readable"; `loops list` meldet "no registered loops" (die Schleifen laufen, wurden aber nicht per `loops wrap` gestartet).
- Erwartung: Pruefung laeuft durch und zaehlt Nahrung/Getraenke in Barrels/Bins im Burrow.
