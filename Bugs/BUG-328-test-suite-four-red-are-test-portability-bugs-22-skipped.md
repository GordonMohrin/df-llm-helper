# BUG-328: Test suite on Windows without pytest: 4 tests fail, all 4 are test/fixture portability problems (epoch ts < 1 day, `\n` -> `\r\n` on write, `\\` in a path prefix check); 22 Lua tests are skipped (no lua5.4)

- **Status:** open
- **Severity:** S3
- **Area:** `tests/test_journal.py:96`, `tests/test_m3.py:72`, `tests/test_scenarios_cli.py:28` + `tests/make_fixtures.py:290`, `tests/test_settings.py:139`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
python Bugs/evidence/BUG-328/mini_pytest/run_tests.py .        # stand-in for `pytest` (pytest is not installed); optionally add test file name filters
```
(`mini_pytest/pytest/__init__.py` implements `fixture`, `mark.parametrize/skipif`, `raises`, `approx`, `skip`; `run_tests.py` provides `tmp_path`, `monkeypatch`, `capsys` and the conftest fixtures. Run on a clean copy of the repository without `config.yaml` so no test can touch a real game folder: tests such as `hygiene mark` load `config.yaml`.)

## Expected
2014 pass, 0 fail (4 of them depend on the platform), Lua tests run where `lua5.4` is installed.

## Actual
```
$ python Bugs/evidence/BUG-328/mini_pytest/run_tests.py <clean checkout>      # pytest is not installed; this is a 250-line stand-in
test_settings.py: pass=18 fail=1 skip=0
test_siege.py: pass=10 fail=0 skip=0
test_tools_v3.py: pass=22 fail=0 skip=0
test_transport.py: pass=148 fail=0 skip=1
test_waechter.py: pass=13 fail=0 skip=0
test_water.py: pass=6 fail=0 skip=1
test_workload.py: pass=9 fail=0 skip=0
TOTAL pass=2014 fail=4 skip=22 in 27.2s
[... per-file lines for the other files: see mini_pytest_full_output.txt ...]

FAIL test_journal.py test_metrics_export_same_header_as_metrics_csv
  File "<project folder>\tests\test_journal.py", line 96, in test_metrics_export_same_header_as_metrics_csv
  File "<project folder>\df_llm_helper\journal.py", line 271, in monthly_metrics
  File "<project folder>\df_llm_helper\metrics.py", line 93, in export_csv
OSError: [Errno 22] Invalid argument

FAIL test_m3.py test_stats_helpers_and_reader
  File "<project folder>\tests\test_m3.py", line 72, in test_stats_helpers_and_reader
    assert len(GamelogReader(big, Store()).new_lines(max_bytes=100)) == 50
AssertionError

FAIL test_scenarios_cli.py test_at_least_8_scenarios_and_generator_reproducible
  File "<project folder>\tests\test_scenarios_cli.py", line 28, in test_at_least_8_scenarios_and_generator_reproducible
    assert (tmp_path / p.name).read_bytes() == p.read_bytes(), f"{p.name} outdated: python tests/make_fixtures.py"
AssertionError: s01_getraenke_fallen.jsonl outdated: python tests/make_fixtures.py

FAIL test_settings.py test_write_boundary
  File "<project folder>\tests\test_settings.py", line 139, in test_write_boundary
    assert all(k.startswith("prefs/backups/") for k in changed) and changed
AssertionError

$ python -c "datetime.fromtimestamp(1000.0).astimezone()"   # the test stores snapshots at ts=1000.0+i
1000.0 ERR [Errno 22] Invalid argument
86400.0 1970-01-02 01:00:00+01:00
[exit 0]

$ python -c "regenerate scenarios/s03_deadman.jsonl with tests/make_fixtures.write_scenarios and compare bytes"
checked-in file: CRLF count 0 | regenerated on Windows: CRLF count 40 | equal after newline normalisation: True
[exit 0]

$ python -c "str(Path('prefs')/'backups'/'x').startswith('prefs/backups/')"
prefs\backups\x | startswith("prefs/backups/") -> False
[exit 0]

$ MINI_PYTEST_TMP='<folder with a space>' python Bugs/evidence/BUG-328/mini_pytest/run_tests.py . test_lint_bus test_report_fixes
test_lint_bus.py: pass=39 fail=1 skip=0
test_report_fixes.py: pass=18 fail=1 skip=0
TOTAL pass=57 fail=2 skip=0 in 1.9s
FAIL test_lint_bus.py test_lint_command_variants
FAIL test_report_fixes.py test_lint_command_reads_windows_paths
```

## Evidence
`Bugs/evidence/BUG-328/` (`mini_pytest/`, `mini_pytest_full_output.txt`, cause snippets).

## Analysis (reporter's hypothesis)
Assessment: **all four failures are test errors, not product errors**.
1. `test_journal.py::test_metrics_export_same_header_as_metrics_csv` (`OSError: [Errno 22]` in `metrics.py:93`): `record_kpis(st, 1000.0 + i, snap)` uses epoch 1970-01-01 00:16:40; `datetime.fromtimestamp(ts).astimezone()` fails on Windows for local times before 1970-01-02 (UTC+1 time zone). Use a realistic `ts` (e.g. `1_790_840_000.0 + i`). Product code is fine because real timestamps are used; a defensive `try/except OSError` in `export_csv` would not hurt.
2. `test_m3.py::test_stats_helpers_and_reader` (`big.write_text("x\n" * 1000)` then `max_bytes=100` -> expects 50 lines): on Windows `write_text` writes `\r\n`, so 100 bytes = 33 lines. Use `write_bytes(b"x\n" * 1000)`.
3. `test_scenarios_cli.py::test_at_least_8_scenarios_and_generator_reproducible`: `tests/make_fixtures.py:290` uses `p.write_text(...)` -> CRLF on Windows; the checked-in `scenarios/*.jsonl` are LF (verified: equal after newline normalisation). Use `open(p, "w", newline="\n")`. (This is a tooling bug too: a Windows developer who runs `python tests/make_fixtures.py` as the message says rewrites all scenario files with CRLF.)
4. `test_settings.py::test_write_boundary`: `tree()` uses `str(p.relative_to(root))` -> `prefs\backups\...` on Windows; compare with `.as_posix()`.
5./6. (only when the temporary directory contains a space, as the player's project path does) `test_lint_bus.py::test_lint_command_variants` (`:60`) and `test_report_fixes.py::test_lint_command_reads_windows_paths` (`:249`) call `lint_command(f"lua -f {f}")` with an **unquoted** path; `lint.py:lint_command` takes the first token only and returns `[]`. The quoted form passes. Product note: an unquoted `lua -f <path with spaces>` is also split by `shlex` in `RealClient`, so the real client cannot run it either; the tests should use the quoted form (`f'lua -f "{f}"'`) or `tmp_path` must not contain spaces.
Skipped (22): 21 `@pytest.mark.skipif(not LUA ...)` tests (camera 2, caravan 1, defense 1, digcheck 1, hygiene 3, lua 2, perimeter 3, reach 4, remote 2, transport 1, water 1) because `lua5.4` is not installed on this machine, plus 1 in `test_planners.py` (`pytest.skip("no project blueprints in the repo")`).

## Suggested fix (optional)
Fix the four tests as described; add `.gitattributes` (`*.jsonl text eol=lf`, `*.csv text eol=lf`) and make `make_fixtures.write_scenarios` newline-explicit.

## Info needed
Info for the player (local test): please install `lua5.4` (e.g. `choco install lua` or the lua-for-windows binary on PATH as `lua5.4`) and run `python Bugs/evidence/BUG-328/mini_pytest/run_tests.py .` (or pytest) again - the 22 skipped Lua-mock tests have never run on this machine. The cloud session can run them on Linux.
