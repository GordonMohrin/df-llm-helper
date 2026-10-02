# data/

- `rules/`, `runbooks/`, `kb/curated.yaml`, `graphs/`, `scopes.yaml`, `services.yaml`, `trade/wants.yaml`: shipped.
- `exceptions.jsonl`: fair-play exception register. Ships with one ignored example line; add real entries only with
  the player's quoted consent (`python -m df_llm_helper exception add ...`).
- `exceptions.local.jsonl` (optional, git-ignored): consents that apply only to your own installation (e.g. FP08
  for the automatic pick fix); merged with `exceptions.jsonl` on load.
- `state.db`: created at runtime (git-ignored).
- More knowledge: `python -m df_llm_helper kb import <your notes>.md` writes `kb/imported_*.jsonl`.
