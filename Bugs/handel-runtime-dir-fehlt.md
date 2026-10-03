# Handel: df-llm-helper-runtime fehlt -> Regeln und Stabilitaetsmarke wirkungslos (03.10.2026)
- `claude/util.home()` liefert ohne Umgebungsvariable DF_LLM_HELPER_HOME `<DF>/df-llm-helper-runtime`; dieser Ordner existierte nicht.
- Folgen: (1) `handel status` schrieb die Stabilitaetsmarke nie (write_state schluckt den Fehler per pcall) -> `select` immer "keine Stabilitaetsmarke", Trade-Automat REVIEW leer/ABORT; (2) `handel-regeln.md` wurde nicht gefunden -> Default-Regeln (leere Kaufliste: "nichts Sinnvolles auszuwaehlen").
- Workaround: Ordner `df-llm-helper-runtime/tools/out` und `tools/scopes/handel-regeln.md` (Kopie) angelegt.
- Fix-Vorschlag: home() muss Ordner anlegen oder Fehler melden; write_state darf nicht still scheitern; Regeldatei-Fehlen laut melden.
- Zweitbefund: `sell_candidates` ueberspringt Items mit flags.in_inventory (alles in Kisten/BINs, hier 396 von 429 Figurinen) -> `mark` findet nichts; Kisten muessen per markForTrade markiert werden. Und der automatische Verkauf waehlt 1 Item mit Wert 26300 (Ueberschuss verfaellt) statt vieler kleiner.
- Drittbefund: Kaufregeln kennen keinen generischen CLOTH-Eintrag (nur silk); Stoff wurde manuell gewaehlt.
