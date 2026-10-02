# data/

- `rules/`, `runbooks/`, `kb/curated.yaml`, `graphs/`, `scopes.yaml`, `services.yaml`, `trade/wants.yaml`: shipped.
- `exceptions.jsonl`: fair-play exception register. Ships with one ignored example line; add real entries only with
  the player's quoted consent (`python -m dfpilot exception add ...`).
- `state.db`: created at runtime (git-ignored).
- More knowledge: `python -m dfpilot kb import <your notes>.md` writes `kb/imported_*.jsonl`.
