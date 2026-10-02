# BUG-317: A hand-edited exception register crashes every command (`[1,2]` line), drops a BOM-prefixed first entry, splits a string `objects` into characters, and a text `max_uses` raises `TypeError` at use time

- **Status:** fixed in 4bfefa4
- **Severity:** S2
- **Area:** `df_llm_helper/fairplay.py:ExceptionRegistry.load/find`
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-317/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
cp Bugs/evidence/BUG-317/inputs/exceptions_nonobject_lines.jsonl tmp_bug/data/exceptions.jsonl
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception list
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 digest
cp Bugs/evidence/BUG-317/inputs/exceptions_bom_and_string_objects.jsonl tmp_bug/data/exceptions.jsonl
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception list
cp Bugs/evidence/BUG-317/inputs/exceptions_max_uses_text.jsonl tmp_bug/data/exceptions.jsonl
python -c "from df_llm_helper.fairplay import ExceptionRegistry as R; print(R('tmp_bug/data/exceptions.jsonl').find('L31'))"
```

## Expected
Invalid lines are reported as `Register error: line N: ...` (the loader already does that for non-JSON lines) and never take the fair-play client down; a BOM is ignored; `"objects": "123"` is one id or a clear error; a bad `max_uses` is a register error.

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception list
Traceback (most recent call last):
  File "<frozen runpy>", line 198, in _run_module_as_main
  File "<frozen runpy>", line 88, in _run_code
  File "<tmp>\repo_copy\df_llm_helper\__main__.py", line 6, in <module>
    sys.exit(main())
             ~~~~^^
  File "<tmp>\repo_copy\df_llm_helper\cli.py", line 1208, in main
    return int(args.fn(args) or 0)
               ~~~~~~~^^^^^^
  File "<tmp>\repo_copy\df_llm_helper\cli.py", line 418, in cmd_exception
    reg = ExceptionRegistry(cfg.path("exceptions"))
  File "<tmp>\repo_copy\df_llm_helper\fairplay.py", line 79, in __init__
    self.load()
[... 6 more lines, see evidence]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 digest
Traceback (most recent call last):
  File "<frozen runpy>", line 198, in _run_module_as_main
  File "<frozen runpy>", line 88, in _run_code
  File "<tmp>\repo_copy\df_llm_helper\__main__.py", line 6, in <module>
    sys.exit(main())
             ~~~~^^
  File "<tmp>\repo_copy\df_llm_helper\cli.py", line 1208, in main
    return int(args.fn(args) or 0)
               ~~~~~~~^^^^^^
  File "<tmp>\repo_copy\df_llm_helper\cli.py", line 59, in cmd_digest
    p = _pilot(args)
  File "<tmp>\repo_copy\df_llm_helper\cli.py", line 45, in _pilot
    client = _client(args, cfg, clock)
[... 10 more lines, see evidence]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception list
 L31 ['1', '2', '3']: objects as a string (player consent: yes)
Register error: line 1: not JSON (Unexpected UTF-8 BOM (decode using utf-8-sig))
[exit 0]

$ python -c "ExceptionRegistry('tmp_bug/data/exceptions.jsonl').find('L31')"
Traceback (most recent call last):
  File "<string>", line 1, in <module>
    import sys;sys.path.insert(0,'.');from df_llm_helper.fairplay import ExceptionRegistry;r=ExceptionRegistry('tmp_bug/data/exceptions.jsonl');print(r.find('L31'))
                                                                                                                                                      ~~~~~~^^^^^^^
  File "<tmp>\repo_copy\df_llm_helper\fairplay.py", line 127, in find
    if e.max_uses is not None and self.uses.get(action, 0) >= e.max_uses:
                                  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
TypeError: '>=' not supported between instances of 'int' and 'str'
[exit 1]
```

## Evidence
`Bugs/evidence/BUG-317/` (the input registers + outputs).

## Analysis (reporter's hypothesis)
`fairplay.py:105` `d.get("example")` is called on whatever `json.loads` returned: a JSON list/string/number raises AttributeError (the `JSONDecodeError` handler does not cover it). Every client (`_client()` in `cli.py`) builds the registry, so **one bad line disables all commands including `digest`**.
`fairplay.py:95` `read_text(encoding="utf-8")` (no `utf-8-sig`): the first line of a register saved with a BOM is rejected ("not JSON (Unexpected UTF-8 BOM)").
`fairplay.py:114` `objects=list(d.get("objects") or [])`: a string becomes a list of characters.
`fairplay.py:127`: `max_uses` is stored as given; `self.uses.get(action, 0) >= e.max_uses` raises `TypeError` for `"2"`.

## Suggested fix (optional)
In `load()`: `if not isinstance(d, dict): error`, open with `utf-8-sig`, coerce/validate `objects` (list of str) and `max_uses` (int >= 1) and report problems in `reg.errors`.

## Info needed
None.

## Fix
`load()` reads with BOM tolerance; non-object lines, string `objects`, non-integer `max_uses` and invalid `expires` become `Register error: ...` and the entry is skipped (fail closed) - no crash of any command.
