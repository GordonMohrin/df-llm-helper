# BUG-214: missing input files end in a Python traceback; malformed numeric arguments produce raw Python messages (`not enough values to unpack`, `invalid literal for int()`); `water lint-cmd` without a command says `ok`

- **Status:** open
- **Severity:** S3
- **Area:** `df_llm_helper/features/perimeter.py:364` (`Grid.from_file`), `digcheck.py:372/376` (`--csv`, `--stages`), `defense.py:158/210` (`--terrain`, `--file`), `cli.py` `cmd_water` (`x, y, z = ...`), `perimeter.py` `allow`, `digcheck.py` (`-c`), `reach.py` (`--wall a b c`), `forecast` (see BUG-213)
- **Reported:** 2026-10-02, commit `6dedd96`
- **Environment:** Windows 11 Pro, Python 3.14.3, game paused (fort date 27. Granite, Jahr 118); no game needed

## Command / steps
```
cd "<project folder>"
python -m df_llm_helper --mock fixtures/run5 perimeter --grid nonexistent.grid
python -m df_llm_helper digcheck --csv nofile.csv -c 1,2,3
python -m df_llm_helper digcheck --stages nofile.lua --stage N1
python -m df_llm_helper --mock fixtures/run5 defense design --terrain nofile.txt
python -m df_llm_helper --mock fixtures/run5 defense status --file nofile.json
python -m df_llm_helper water check 1 2          # also: water check / water check a b c / 1.5 2 3 / 100 100 130 5 6
python -m df_llm_helper perimeter allow 1 2      # also: perimeter allow a b c
python -m df_llm_helper digcheck --csv f.csv -c 1,2   # also -c x,y,z
python -m df_llm_helper reach what-if --wall a b c
python -m df_llm_helper water lint-cmd           # no command given
```

## Expected
One-line messages with the usage (`water check X Y Z`; `file not found: nofile.csv`), exit 2, no traceback. `water lint-cmd` without a command: usage error, not `ok`.

## Actual
```
Traceback (most recent call last): ... FileNotFoundError: [Errno 2] No such file or directory: 'nofile.csv'     (rc 1, 4 commands)
Error: not enough values to unpack (expected 3, got 2)
Error: invalid literal for int() with base 10: 'a'
Error: too many values to unpack (expected 3)
water lint-cmd   ->  ok   (rc 0)
```
(Good examples to copy: `digcheck` with a missing `-c` -> `Error: --csv needs -c x,y,z`; `reach what-if --wall 1 2` -> argparse usage; `settings ...` -> `Refused: usage: ...`.)

## Evidence
`Bugs/evidence/BUG-214/` (the `.err`/`.out` files of each call).

## Analysis (reporter's hypothesis)
`cli.main` only converts `ValueError`/`KeyError`-like errors to `Error: <msg>`; `OSError` is not caught, and the argument parsing uses bare tuple unpacking / `int()`.

## Suggested fix (optional)
Catch `OSError` in `cli.main` and print `Error: cannot read <path>: <reason>` (rc 2); use `argparse` `nargs=3, type=int, metavar=(X,Y,Z)` for coordinates; make `lint-cmd` require at least one word.

## Info needed
None.
