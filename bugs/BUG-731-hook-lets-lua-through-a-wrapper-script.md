# BUG-731 The fair-play hook does not see `lua` passed through a wrapper script
Status: fixed (offline, live-untested)
Severity: high
Found: 2026-11-11, Run 16d i4 (the player ran the wrapper `dh.sh` with `lua` and no further argument, answered with the help text only; `dh.sh` wraps the DFHack client, so the command text held no client word and the hook judged nothing: 'no DF command')
Module: `dfpilot/lint.py` (`_wrapper_lua`, `_judge`), `dfpilot/hook.py` (unchanged: it calls `lint.cmd`)

## Root cause
`lint.shell_invocations` judges a command only when the client's name (or a variable / alias holding it) appears. A script named `*.sh` that calls the client itself leaves no such word in the text the hook gets, so `./dh.sh lua -f x.lua` or `bash dh.sh lua` passed as 'no DF command'.

## Fix
`lint._wrapper_lua`: a command whose head is a `*.sh` / `*.bash` / `*.zsh` script, or a shell (`bash`, `sh`, `zsh`, `dash`, `ksh`, `source`, `.`) running one, whose first non-option argument is `lua` (or `:lua`), is judged as the client's `lua` call and blocked ('inline lua is not allowed'). Quoted code strings that mention a `.sh` script (`bash -c "./dh.sh lua"`) are judged as well; `$( )`, loops, `timeout` and the other wrappers already reached `_judge`. Mention-only commands (`echo`, `grep`, `git commit -m ...`) stay allowed, as does any other first argument (`./dh.sh dfllm status`, `bash build.sh test`).

## Tests
`tests/test_bug731_wrapper_lua.py`: 12 blocked forms (`dh.sh lua`, `./dh.sh lua -f probe.lua`, `bash dh.sh lua`, `sh -x dh.sh lua`, a quoted path with a space, `bash -c "..."`, `timeout 30 ./dh.sh lua`, `$(...)`, a loop, `:lua`), 8 allowed (`dfllm status` through the wrapper, `build.sh test`, mentions), and `hook.decide` for both.

## Live check
A hook payload with the command `./dh.sh lua` on stdin of `python -m dfpilot.hook` exits 2. Open: only `lua` as the first argument is judged for a wrapper (the wrapper's other uses cannot be known without reading it; a wrapper without the `.sh` extension, a `.py` or `.cmd` one, is not seen); the real fix against a wrapper is not to keep one in the player's folder.
