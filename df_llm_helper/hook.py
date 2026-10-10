"""Claude Code PreToolUse hook (v2, WP4, DESIGN §11.5): fair play at the shell boundary.

Reads the hook JSON from stdin as UTF-8 ({tool_name, tool_input: {command}, cwd, ...}) and judges every
dfhack-run call in tool_input.command with lint.cmd(shell=True), including the CONTRACTS §13 trust rules
(--by only llm/cli, no `dfllm cmd audit`, no hand-written inbox JSON with "by"). Shell tools: Bash,
PowerShell, Monitor and the desktop terminal (TOOLS, matched in .claude/settings.json); any other tool
whose input carries a command string is judged the same way. File tools (FILE_TOOLS: Write, Edit,
MultiEdit, NotebookEdit) may not write under dfllm-runtime/ or to config/decisions.yaml.
  allowed  dfhack-run dfllm boot|adopt|stop|status|selftest|restore|inspect, load-save <folder>,
           read-only allowlist entries (help, ls, tags); with DFLLM_DEV=1 also allowlisted write
           commands and `dfllm selftest --exec <file>` after the file passes the Lua lint
  blocked  claude/*, inline lua, everything on the allowlist's blocked list, commands owned by an act
           function, unknown commands, dfhack-run uses the parser cannot follow
Exit 0 = allow, exit 2 + stderr = block (Claude Code feeds stderr back to the model). The hook fails
closed: any error while judging (bad input, a broken lint/fairplay/schema import, an encoding problem)
blocks the call when the input mentions dfhack, and allows it otherwise.
Every decision about a dfhack-run call is appended to the hook log (JSON lines): $DFLLM_HOOK_LOG,
else <DF>/dfllm-runtime/hook.log when the DF folder exists.
"""
from __future__ import annotations

import importlib
import json
import os
import sys
import time
from pathlib import Path

TOOLS = ("Bash", "PowerShell", "Monitor", "mcp__terminal__run_in_terminal")
FILE_TOOLS = ("Write", "Edit", "MultiEdit", "NotebookEdit")   # CONTRACTS §13: no writes under dfllm-runtime/
LOG_MAX = 1_000_000


def _lint():
    """df_llm_helper.lint, imported late so that an import error fails closed instead of crashing."""
    if __package__ in (None, ""):                         # also runnable as a plain script path
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    return importlib.import_module("df_llm_helper.lint")


def _log_path() -> Path | None:
    p = os.environ.get("DFLLM_HOOK_LOG")
    if p:
        return Path(p)
    from df_llm_helper import paths
    root = paths.runtime_root()
    return root / "hook.log" if root.parent.is_dir() else None


def log(entry: dict) -> None:
    """Append one JSON line; never raises (logging must not decide anything)."""
    try:
        p = _log_path()
        if p is None:
            return
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.is_file() and p.stat().st_size > LOG_MAX:
            os.replace(p, p.with_name(p.name + ".1"))
        with p.open("a", encoding="utf-8", errors="replace") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
    except Exception:                                     # noqa: BLE001
        pass


def _file_rule(path: str) -> str | None:
    """CONTRACTS §13 trust rule for file tools; a broken lint import still blocks the two protected places."""
    try:
        return _lint().file_write_violation(path)
    except Exception:                                     # noqa: BLE001 - fail closed for the protected paths
        p = path.replace("\\", "/").lower()
        if "dfllm-runtime/" in p or p.endswith("config/decisions.yaml"):
            return "protected path (fair-play hook error while judging)"
        return None


def decide(payload: dict, env: dict | None = None) -> tuple[int, str]:
    """(exit code, stderr message) for one hook payload."""
    env = os.environ if env is None else env
    tool = payload.get("tool_name")
    ti = payload.get("tool_input") if isinstance(payload.get("tool_input"), dict) else {}
    text = ti.get("command")
    path = ti.get("file_path") or ti.get("notebook_path")
    if not isinstance(text, str) and isinstance(path, str):   # Write, Edit, MultiEdit, NotebookEdit
        why = _file_rule(path)
        if not why:
            return 0, ""
        log({"wall": int(time.time()), "tool": tool, "ok": False, "why": why[:300], "path": path[:300]})
        return 2, f"dfllm fair-play hook blocked this edit: {why}"
    if not isinstance(text, str):                         # Read, Glob, ...: nothing to run
        return 0, ""
    dev = env.get("DFLLM_DEV") == "1"
    try:
        ok, why = _lint().cmd(text, dev=dev, cwd=payload.get("cwd"), shell=True)
    except Exception as e:                                # noqa: BLE001 - a lint bug must not open the door
        if "dfhack" not in text.lower():
            return 0, ""
        ok, why = False, f"fair-play hook error ({type(e).__name__}: {e}); refusing the dfhack-run call"
    if why != "no DF command":
        log({"wall": int(time.time()), "tool": tool, "ok": ok, "why": why[:300], "dev": dev,
             "cmd": text[:300]})
    if ok:
        return 0, ""
    return 2, f"dfllm fair-play hook blocked this command: {why}"


def _read(stdin) -> str:
    """The hook input as text. Claude Code sends UTF-8; Windows would decode a pipe as cp1252."""
    src = sys.stdin if stdin is None else stdin
    buf = getattr(src, "buffer", None)
    data = buf.read() if buf is not None else src.read()
    return data.decode("utf-8", "replace") if isinstance(data, (bytes, bytearray)) else data


def _err(msg: str) -> None:
    try:
        b = getattr(sys.stderr, "buffer", None)
        if b is not None:
            b.write((msg + "\n").encode("utf-8", "replace"))
            b.flush()
        else:
            sys.stderr.write(msg + "\n")
    except Exception:                                     # noqa: BLE001
        pass


def main(stdin=None) -> int:
    raw = ""
    try:
        raw = _read(stdin) or ""
        try:
            payload = json.loads(raw or "{}")
        except ValueError:
            payload = None
        if not isinstance(payload, dict):
            if "dfhack" in raw.lower():
                _err("dfllm fair-play hook: unreadable hook input with a dfhack call; blocked")
                return 2
            return 0
        code, msg = decide(payload)
        if msg:
            _err(msg)
        return code
    except BaseException as e:                            # noqa: BLE001 - fail closed for DF calls
        if "dfhack" in str(raw).lower():
            _err(f"dfllm fair-play hook error ({type(e).__name__}); dfhack-run call blocked")
            return 2
        return 0


if __name__ == "__main__":
    sys.exit(main())
