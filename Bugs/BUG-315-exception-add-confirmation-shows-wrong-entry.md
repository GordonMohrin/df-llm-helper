# BUG-315: `exception add FP08 ...` answers `Exception registered: FP10 [...]` - it prints the last entry of the merged register (the local file), not the entry that was just written

- **Status:** fixed in 4bfefa4
- **Severity:** S2
- **Area:** `exception add` (`df_llm_helper/cli.py:cmd_exception`, `df_llm_helper/fairplay.py:ExceptionRegistry.add`)
- **Reported:** 2026-10-02, commit `50cee52`
- **Environment:** Windows 11, Python 3.14, game: running (DF 53.16 + DFHack) but PAUSED and untouched - this test uses the mock only

## Command / steps
```
cd <project folder>
mkdir tmp_bug && cp -r data tmp_bug/data && cp Bugs/evidence/BUG-315/cfg.yaml tmp_bug/cfg.yaml && mkdir tmp_bug/scopes tmp_bug/tools
cp Bugs/evidence/BUG-315/inputs/exceptions.local.jsonl tmp_bug/data/exceptions.local.jsonl     # a local register exists (as on the player's machine)
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP08 --objects 187405,187429 --reason "E18 picks" --ja "yes, do it"
python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add L31 --reason "dig near water" --ja "yes, do it"
```

## Expected
The confirmation names the rule and objects that were just registered (`FP08 ['187405', '187429']`).

## Actual
```
$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add FP08 --objects 187405,187429 --reason 'E18 picks' --ja 'yes, do it'
Exception registered: FP10 ['189175', '3738']
[exit 0]

$ python -m df_llm_helper --config tmp_bug/cfg.yaml --mock fixtures/run5 exception add L31 --reason 'dig near water' --ja 'yes, do it'
Exception registered: FP10 ['189175', '3738']
[exit 0]

$ cat tmp_bug/data/exceptions.jsonl   # what was really written
{"example": true, "ts": "2026-01-01T00:00:00Z", "action": "FP09", "objects": [], "reason": "example (ignored): send stuck traders 
{"ts": "2026-10-02T10:38:19Z", "action": "FP08", "objects": ["187405", "187429"], "reason": "E18 picks", "player_consent": "yes, d
{"ts": "2026-10-02T10:38:19Z", "action": "L31", "objects": [], "reason": "dig near water", "player_consent": "yes, do it"}
[exit 0]
```

## Evidence
`Bugs/evidence/BUG-315/`.

## Analysis (reporter's hypothesis)
`fairplay.py:165-166`: after writing to the shared file `self.load()` rebuilds `entries` = shared lines + local lines, then `return self.entries[-1]` returns the **last** entry of the merged list, i.e. the local register's last line. With `exceptions.local.jsonl` present (the normal case on the player's machine: FP08/FP10) every `exception add` prints the wrong rule and wrong object ids. The orchestrator reading this output can conclude that FP10 (a different permission, with other objects) was just granted, or that its FP08 entry went into the wrong file.

## Suggested fix (optional)
Build the `Exception_` from the dict `d` that was written (or return the last entry of the *shared* file's section), and print the register file the entry went to.

## Info needed
None.

## Fix
`ExceptionRegistry.add` returns the entry it wrote; the CLI prints it with the register file name.
