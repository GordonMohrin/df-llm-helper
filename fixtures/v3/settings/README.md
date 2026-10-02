# Fixtures spec v3-09 (settings manager) - SYNTHETIC

- `d_init.txt`: hand-written in the shape of `prefs/d_init.txt` (CRLF line endings, one Latin-1 byte in the last
  line to prove byte-identical handling). Lines 25-26 carry the Run 5 values `[POPULATION_CAP:75]` and
  `[STRICT_POPULATION_CAP:100]`. The other lines are typical keys, NOT a copy of the real Run 5 file.
- `d_init.txt.bak-run5`: the same file with DF defaults 200/220 (the backup the orchestrator made in Run 5).

Gap: the real Run 5 `d_init.txt` and its backup are not in the repository; DF defaults (200/220/1000:1000/100)
are from memory and must be checked against DF 53.
