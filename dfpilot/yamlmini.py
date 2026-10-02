"""Minimal YAML subset (stdlib only).

Supported: comments, nested mappings/lists by indentation, lists of mappings,
scalars (int/float/bool/null/strings, '...' and "..."), flow lists/mappings ([a, b], {a: 1}),
block scalars (| and >). No anchors/aliases, no multiple documents, no tags.
Errors -> YamlError with a line number (actionable).
"""
from __future__ import annotations

import re
from typing import Any

__all__ = ["YamlError", "loads", "load_file", "dumps"]


class YamlError(ValueError):
    pass


_INT = re.compile(r"^[-+]?\d+$")
_FLOAT = re.compile(r"^[-+]?(\d+\.\d*|\.\d+|\d+)([eE][-+]?\d+)?$")


def _strip_comment(line: str) -> str:
    """Removes '#' comments outside of quotes."""
    out = []
    quote = None
    i = 0
    while i < len(line):
        c = line[i]
        if quote:
            out.append(c)
            if c == "\\" and quote == '"' and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
        else:
            if c in ("'", '"') and (not out or out[-1] in " \t[{,:-"):
                quote = c
            elif c == "#" and (not out or out[-1] in " \t"):
                break
            out.append(c)
        i += 1
    return "".join(out).rstrip()


def _scalar(tok: str, lineno: int) -> Any:
    t = tok.strip()
    if t == "":
        return None
    if t[0] in "[{":
        val, rest = _flow(t, 0, lineno)
        if t[rest:].strip():
            raise YamlError(f"line {lineno}: unexpected text after flow value: {t[rest:]!r}")
        return val
    if t[0] == '"':
        if len(t) < 2 or t[-1] != '"':
            raise YamlError(f"line {lineno}: string without closing \"")
        return _unescape(t[1:-1])
    if t[0] == "'":
        if len(t) < 2 or t[-1] != "'":
            raise YamlError(f"line {lineno}: string without closing '")
        return t[1:-1].replace("''", "'")
    low = t.lower()
    if low in ("true", "yes", "on"):
        return True
    if low in ("false", "no", "off"):
        return False
    if low in ("null", "~", "none"):
        return None
    if _INT.match(t):
        return int(t)
    if _FLOAT.match(t):
        return float(t)
    return t


def _unescape(s: str) -> str:
    return (s.replace("\\\\", "\x00").replace('\\"', '"').replace("\\n", "\n")
            .replace("\\t", "\t").replace("\x00", "\\"))


def _flow(s: str, i: int, lineno: int) -> tuple[Any, int]:
    """Parses a flow value from position i; returns (value, new position)."""
    def skip(j: int) -> int:
        while j < len(s) and s[j] in " \t":
            j += 1
        return j

    i = skip(i)
    if i >= len(s):
        raise YamlError(f"line {lineno}: incomplete flow value")
    c = s[i]
    if c == "[":
        out: list = []
        i = skip(i + 1)
        if i < len(s) and s[i] == "]":
            return out, i + 1
        while True:
            v, i = _flow(s, i, lineno)
            out.append(v)
            i = skip(i)
            if i < len(s) and s[i] == ",":
                i += 1
                continue
            if i < len(s) and s[i] == "]":
                return out, i + 1
            raise YamlError(f"line {lineno}: ']' missing in flow list")
    if c == "{":
        d: dict = {}
        i = skip(i + 1)
        if i < len(s) and s[i] == "}":
            return d, i + 1
        while True:
            k, i = _flow_token(s, i, ":", lineno)
            i = skip(i)
            if i >= len(s) or s[i] != ":":
                raise YamlError(f"line {lineno}: ':' missing in flow mapping")
            v, i = _flow(s, i + 1, lineno)
            d[str(k)] = v
            i = skip(i)
            if i < len(s) and s[i] == ",":
                i += 1
                continue
            if i < len(s) and s[i] == "}":
                return d, i + 1
            raise YamlError(f"line {lineno}: '}}' missing in flow mapping")
    return _flow_token(s, i, ",]}", lineno)


def _flow_token(s: str, i: int, stops: str, lineno: int) -> tuple[Any, int]:
    if s[i] in "\"'":
        q = s[i]
        j = i + 1
        while j < len(s):
            if s[j] == "\\" and q == '"':
                j += 2
                continue
            if s[j] == q:
                break
            j += 1
        if j >= len(s):
            raise YamlError(f"line {lineno}: unterminated string")
        return _scalar(s[i:j + 1], lineno), j + 1
    if s[i] in "[{":
        return _flow(s, i, lineno)
    j = i
    while j < len(s) and s[j] not in stops:
        j += 1
    return _scalar(s[i:j], lineno), j


class _Line:
    __slots__ = ("indent", "text", "no", "raw")

    def __init__(self, indent: int, text: str, no: int, raw: str):
        self.indent, self.text, self.no, self.raw = indent, text, no, raw


def _split_key(text: str) -> tuple[str, str] | None:
    """'key: rest' -> (key, rest); None if not a mapping line."""
    if text.startswith(("'", '"')):
        q = text[0]
        end = text.find(q, 1)
        if end < 0:
            return None
        rest = text[end + 1:]
        if rest.startswith(":") and (len(rest) == 1 or rest[1] in " \t"):
            return text[1:end], rest[1:].strip()
        return None
    m = re.match(r"^([^\s:\[\]{},#][^:]*?)\s*:(\s+|$)(.*)$", text)
    if not m:
        return None
    return m.group(1), m.group(3)


def loads(src: str) -> Any:
    raw_lines = src.replace("\r\n", "\n").replace("\t", "    ").split("\n")
    lines: list[_Line] = []
    for no, raw in enumerate(raw_lines, 1):
        stripped = _strip_comment(raw)
        if not stripped.strip():
            lines.append(_Line(-1, "", no, raw))  # blank line (for block scalars)
            continue
        if stripped.strip() in ("---", "..."):
            continue
        indent = len(stripped) - len(stripped.lstrip(" "))
        lines.append(_Line(indent, stripped.strip(), no, raw))
    pos = [0]

    def peek() -> _Line | None:
        while pos[0] < len(lines) and lines[pos[0]].indent < 0:
            pos[0] += 1
        return lines[pos[0]] if pos[0] < len(lines) else None

    def block_scalar(style: str, parent_indent: int) -> str:
        collected: list[str] = []
        ind = None
        while pos[0] < len(lines):
            ln = lines[pos[0]]
            raw = ln.raw.replace("\t", "    ")
            if raw.strip() == "":
                collected.append("")
                pos[0] += 1
                continue
            cur = len(raw) - len(raw.lstrip(" "))
            if cur <= parent_indent:
                break
            if ind is None:
                ind = cur
            collected.append(raw[ind:] if cur >= ind else raw.strip())
            pos[0] += 1
        while collected and collected[-1] == "":
            collected.pop()
        if style.startswith("|"):
            text = "\n".join(collected)
        else:
            paras, cur_p = [], []
            for c in collected:
                if c == "":
                    paras.append(" ".join(cur_p))
                    cur_p = []
                else:
                    cur_p.append(c.strip())
            paras.append(" ".join(cur_p))
            text = "\n".join(paras)
        if not style.endswith("-"):
            text += "\n"
        return text

    def value_after(rest: str, ln: _Line, own_indent: int) -> Any:
        if rest in ("|", ">", "|-", ">-", "|+", ">+"):
            return block_scalar(rest, own_indent)
        if rest == "":
            nxt = peek()
            if nxt is not None and nxt.indent > own_indent:
                return parse_block(nxt.indent)
            if nxt is not None and nxt.indent == own_indent and (nxt.text == "-" or nxt.text.startswith("- ")):
                # list at the same indentation as the key (YAML allows this)
                return parse_list(own_indent)
            return None
        return _scalar(rest, ln.no)

    def parse_list(indent: int) -> list:
        out = []
        while True:
            ln = peek()
            if ln is None or ln.indent != indent or not (ln.text == "-" or ln.text.startswith("- ")):
                if ln is not None and ln.indent > indent:
                    raise YamlError(f"line {ln.no}: unexpected indentation in list")
                return out
            pos[0] += 1
            rest = ln.text[1:].strip()
            if rest == "":
                nxt = peek()
                out.append(parse_block(nxt.indent) if nxt is not None and nxt.indent > indent else None)
                continue
            kv = _split_key(rest) if rest[0] not in "[{" else None
            if kv is not None:
                # mapping as a list item: further keys at indentation indent+2 (position after '- ')
                item_indent = indent + 2 + (len(ln.text[1:]) - len(ln.text[1:].lstrip(" ")) - 1)
                d: dict = {}
                k, r = kv
                d[k] = value_after(r, ln, item_indent)
                while True:
                    nxt = peek()
                    if nxt is None or nxt.indent != item_indent or nxt.text == "-" or nxt.text.startswith("- "):
                        break
                    kv2 = _split_key(nxt.text)
                    if kv2 is None:
                        raise YamlError(f"line {nxt.no}: 'key: value' expected")
                    pos[0] += 1
                    if kv2[0] in d:
                        raise YamlError(f"line {nxt.no}: duplicate key: {kv2[0]}")
                    d[kv2[0]] = value_after(kv2[1], nxt, item_indent)
                out.append(d)
            else:
                out.append(_scalar(rest, ln.no))

    def parse_map(indent: int) -> dict:
        d: dict = {}
        while True:
            ln = peek()
            if ln is None or ln.indent < indent:
                return d
            if ln.indent > indent:
                raise YamlError(f"line {ln.no}: unexpected indentation")
            kv = _split_key(ln.text)
            if kv is None:
                raise YamlError(f"line {ln.no}: 'key: value' expected, found: {ln.text[:40]!r}")
            pos[0] += 1
            if kv[0] in d:
                raise YamlError(f"line {ln.no}: duplicate key: {kv[0]}")
            d[kv[0]] = value_after(kv[1], ln, indent)

    def parse_block(indent: int) -> Any:
        ln = peek()
        if ln is None:
            return None
        if ln.text == "-" or ln.text.startswith("- "):
            return parse_list(indent)
        if _split_key(ln.text) is not None:
            return parse_map(indent)
        pos[0] += 1
        val = _scalar(ln.text, ln.no)
        nxt = peek()
        if nxt is not None and nxt.indent >= indent:
            raise YamlError(f"line {nxt.no}: unexpected content after scalar")
        return val

    first = peek()
    if first is None:
        return None
    result = parse_block(first.indent)
    rest = peek()
    if rest is not None:
        raise YamlError(f"line {rest.no}: unexpected content (check indentation)")
    return result


def load_file(path) -> Any:
    with open(path, encoding="utf-8") as f:
        try:
            return loads(f.read())
        except YamlError as e:
            raise YamlError(f"{path}: {e}") from None


def _dump_scalar(v: Any) -> str:
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, (int, float)):
        return repr(v)
    s = str(v)
    if (s == "" or s.strip() != s or any(c in s for c in ":#[]{},\"'\n") or s[0] in "-?&*!|>%@`"
            or _scalar(s, 0) != s):
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n") + '"'
    return s


def dumps(obj: Any, indent: int = 0) -> str:
    pad = " " * indent
    if isinstance(obj, dict):
        if not obj:
            return pad + "{}\n"
        out = []
        for k, v in obj.items():
            if isinstance(v, (dict, list)) and v:
                out.append(f"{pad}{_dump_scalar(k)}:\n{dumps(v, indent + 2)}")
            else:
                out.append(f"{pad}{_dump_scalar(k)}: {_dump_scalar(v) if not isinstance(v, (dict, list)) else ('{}' if isinstance(v, dict) else '[]')}\n")
        return "".join(out)
    if isinstance(obj, list):
        if not obj:
            return pad + "[]\n"
        out = []
        for v in obj:
            if isinstance(v, (dict, list)) and v:
                inner = dumps(v, indent + 2)
                out.append(f"{pad}- {inner.lstrip(' ')}")
            else:
                out.append(f"{pad}- {_dump_scalar(v) if not isinstance(v, (dict, list)) else ('{}' if isinstance(v, dict) else '[]')}\n")
        return "".join(out)
    return pad + _dump_scalar(obj) + "\n"
