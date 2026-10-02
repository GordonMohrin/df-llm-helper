# Fixtures spec v3-10 (camera director profiles) - SYNTHETIC

- `schau_status_default.json`, `schau_status_menu.json`: shape of `claude/schau status` (keys as in
  lua/claude/schau.lua status(), plus the new `profile` and `cats`); values invented.
- `jobs_j109.json`: invented job distribution of a 141-dwarf fort (soldiers sparring without a job, haulers, diggers,
  builders, burial, harvest, water) for the Monte-Carlo test; the job type names are real DF job types.
- `schau_mock.lua`: loads lua/claude/schau.lua as a module with a minimal DFHack stub (profile hook test).

Gaps: no live `schau status` recording with `profile`/`cats` (hook is live-untested); no real Run 5 job
distribution or report type mix was recorded.
