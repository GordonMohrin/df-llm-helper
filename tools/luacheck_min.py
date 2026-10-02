"""Structure check for Lua (SPEC 8.3) without a Lua interpreter: strings/comments, brackets, block balance
(function/if/for/while/do/repeat ... end/until), forbidden patterns (fair play). Usage:
    python tools/luacheck_min.py file.lua [...]   -> exit 0 ok, 1 findings
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

OPENERS = {"function", "if", "for", "while", "repeat"}
FORBIDDEN = [
    (re.compile(r"\bcreateitem\b"), "createitem"), (re.compile(r"\bdig-?now\b"), "dig-now"),
    (re.compile(r"\bbuild-?now\b"), "build-now"), (re.compile(r"run_command\([^)]*['\"]reveal"), "reveal"),
    (re.compile(r"flags\d?\.foreign\s*=(?!=)"), "setting the foreign flag"),
]


def strip_code(src: str, keep_strings: bool = False) -> tuple[str, list[str]]:
    """Replaces strings/comments with spaces (lines are preserved). Returns (code, errors)."""
    out, errs, i, line = [], [], 0, 1
    n = len(src)
    while i < n:
        c = src[i]
        if src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + len(m.group(0)))
                if j < 0:
                    errs.append(f"line {line}: block comment without end")
                    j = n
                seg = src[i:j + len(close)]
            else:
                j = src.find("\n", i)
                seg = src[i:(j if j >= 0 else n)]
            out.append(re.sub(r"[^\n]", " ", seg))
            line += seg.count("\n")
            i += len(seg)
            continue
        m = re.match(r"\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i + len(m.group(0)))
            if j < 0:
                errs.append(f"line {line}: long string without end")
                j = n
            seg = src[i:j + len(close)]
            out.append(seg if keep_strings else '"' + re.sub(r"[^\n]", " ", seg[1:-1]) + '"')
            line += seg.count("\n")
            i += len(seg)
            continue
        if c in "\"'":
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == "\\":
                    j += 1
                elif src[j] == "\n":
                    errs.append(f"line {line}: string without end")
                    break
                j += 1
            seg = src[i:j + 1]
            out.append(seg if keep_strings or len(seg) < 2 else c + " " * (len(seg) - 2) + c)
            i = j + 1
            continue
        if c == "\n":
            line += 1
        out.append(c)
        i += 1
    return "".join(out), errs


def check_source(src: str, name: str = "<lua>") -> list[str]:
    code, errs = strip_code(src)
    findings = [f"{name}: {e}" for e in errs]
    stack: list[tuple[str, int]] = []
    pairs = {")": "(", "]": "[", "}": "{"}
    for lineno, ln in enumerate(code.split("\n"), 1):
        for tok in re.finditer(r"[A-Za-z_][A-Za-z0-9_]*|[()\[\]{}]", ln):
            t = tok.group(0)
            if t in "([{":
                stack.append((t, lineno))
            elif t in ")]}":
                if not stack or stack[-1][0] != pairs[t]:
                    findings.append(f"{name}:{lineno}: unexpected '{t}'")
                else:
                    stack.pop()
            elif t in OPENERS:
                stack.append((t, lineno))
            elif t == "do":
                # 'for/while ... do' belongs to the opener; a standalone 'do' opens a block
                if stack and stack[-1][0] in ("for", "while") and stack[-1][1] <= lineno and not stack[-1][0].endswith("!"):
                    stack[-1] = (stack[-1][0] + "!", stack[-1][1])
                else:
                    stack.append(("do", lineno))
            elif t == "end":
                if not stack or stack[-1][0] in ("(", "[", "{", "repeat"):
                    findings.append(f"{name}:{lineno}: 'end' without an open block")
                else:
                    stack.pop()
            elif t == "until":
                if not stack or stack[-1][0] != "repeat":
                    findings.append(f"{name}:{lineno}: 'until' without 'repeat'")
                else:
                    stack.pop()
    for t, ln in stack:
        findings.append(f"{name}:{ln}: '{t.rstrip('!')}' not closed")
    with_strings, _ = strip_code(src, keep_strings=True)
    for pat, why in FORBIDDEN:
        for m in pat.finditer(with_strings):
            findings.append(f"{name}:{with_strings[:m.start()].count(chr(10)) + 1}: forbidden ({why})")
    return findings


def check_file(path: Path) -> list[str]:
    return check_source(Path(path).read_text(encoding="utf-8", errors="replace"), str(path))


def main(argv: list[str]) -> int:
    bad = 0
    for f in argv:
        res = check_file(Path(f))
        for r in res:
            print(r)
        bad += bool(res)
    print(f"{len(argv)} files, {bad} with findings")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
