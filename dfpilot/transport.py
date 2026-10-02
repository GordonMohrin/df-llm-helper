"""F10 batching and response compression.

BatchingClient.run_many(): all commands in ONE dfhack-run call (claude/pilot_batch <request.json>), result list
with ok per entry; partial failures do not stop the others. If the batch fails completely, commands are queried one by one.
project()/shrink_json()/compress_text(): only requested fields, maximum size, '… +N more'.
"""
from __future__ import annotations

import copy
import json
import shlex
from pathlib import Path
from typing import Any

from .client import DFClient, MockClient, Result
from .fairplay import check_command

__all__ = ["BatchingClient", "project", "shrink_json", "compress_text", "attach_mock_batch", "BATCH_PREFIX"]

BATCH_PREFIX = "claude/pilot_batch "


def _parts(cmd: str) -> list[str]:
    try:
        return shlex.split(cmd, posix=True)
    except ValueError:
        return cmd.split()


class BatchingClient(DFClient):
    def __init__(self, inner: DFClient, batch_dir: str | Path, *, max_bytes: int = 20000):
        super().__init__(inner.registry, inner.clock)
        self.inner = inner
        self.batch_dir = Path(batch_dir)
        self.max_bytes = max_bytes
        self.batches = 0
        self.fallbacks = 0

    def _run(self, cmd: str, timeout: float) -> Result:
        return self.inner.run(cmd, timeout=timeout)

    def run_many(self, cmds: list[str], *, timeout: float = 60.0) -> list[Result]:
        if len(cmds) <= 1:
            return super().run_many(cmds, timeout=timeout)
        for c in cmds:                       # fair play BEFORE writing the request
            check_command(c, self.registry)
        self.batch_dir.mkdir(parents=True, exist_ok=True)
        req = self.batch_dir / "pilot_batch_request.json"
        req.write_text(json.dumps({"cmds": [_parts(c) for c in cmds], "max_bytes": self.max_bytes},
                                  ensure_ascii=False), encoding="utf-8")
        self.batches += 1
        batch_cmd = BATCH_PREFIX + req.as_posix()
        self.calls.append(batch_cmd)
        res = self.inner.run(batch_cmd, timeout=timeout)
        data = res.json if res.ok else None
        if not isinstance(data, list) or len(data) != len(cmds):
            self.fallbacks += 1              # batch script missing/broken -> one by one (slower but safe)
            return super().run_many(cmds, timeout=timeout)
        out = []
        per = res.elapsed_s / max(1, len(cmds))
        for c, d in zip(cmds, data):
            if not isinstance(d, dict):
                out.append(Result(ok=False, stdout="", stderr="Batch: entry not readable", cmd=c))
                continue
            r = Result.make(c, bool(d.get("ok")), str(d.get("out") or ""), str(d.get("err") or ""), per)
            out.append(r)
            for ob in self.observers:
                ob(r)
        return out


def attach_mock_batch(mock: MockClient) -> MockClient:
    """MockClient answers claude/pilot_batch like the Lua script (for tests without DF)."""
    def handle(cmd: str) -> str:
        path = Path(cmd[len(BATCH_PREFIX):].strip())
        req = json.loads(path.read_text(encoding="utf-8"))
        out = []
        for parts in req["cmds"]:
            sub = " ".join(shlex.quote(p) if (" " in p or '"' in p) else p for p in parts)
            r = mock.responses.get(sub)
            if r is None and parts and parts[0] == "lua" and len(parts) == 2:
                r = mock.responses.get(f'lua "{parts[1]}"')
            if callable(r):
                r = r(sub)
            if isinstance(r, Result):
                out.append({"ok": r.ok, "out": r.stdout, "err": r.stderr})
            elif r is None:
                out.append({"ok": False, "out": "", "err": f"unknown command {sub}"})
            else:
                text = str(r)
                mb = int(req.get("max_bytes", 20000))
                if len(text) > mb:
                    text = text[:mb] + f"\n... truncated ({len(text)} Bytes)"
                out.append({"ok": True, "out": text})
        return json.dumps(out, ensure_ascii=False)
    mock.prefix_handlers.append((BATCH_PREFIX, handle))
    return mock


# ---------------------------------------------------------------- projection / compression

def _get_path(obj: Any, parts: list[str]) -> Any:
    cur = obj
    for i, p in enumerate(parts):
        if p.endswith("[]"):
            key = p[:-2]
            lst = cur.get(key) if isinstance(cur, dict) else None
            if not isinstance(lst, list):
                return None
            rest = parts[i + 1:]
            return [_get_path(x, rest) if rest else x for x in lst]
        if not isinstance(cur, dict) or p not in cur:
            return None
        cur = cur[p]
    return cur


def _set_path(out: dict, parts: list[str], value: Any) -> None:
    cur = out
    for p in parts[:-1]:
        cur = cur.setdefault(p.rstrip("[]"), {})
    cur[parts[-1].rstrip("[]")] = value


def project(obj: Any, fields: list[str]) -> dict:
    """Only the requested fields (dotted paths, 'units[].id' for lists). Missing fields are absent from the result."""
    out: dict = {}
    for f in fields:
        parts = f.split(".")
        val = _get_path(obj, parts)
        if val is None:
            continue
        if any(p.endswith("[]") for p in parts):
            idx = next(i for i, p in enumerate(parts) if p.endswith("[]"))
            _set_path(out, parts[:idx + 1], val)
        else:
            _set_path(out, parts, val)
    return out


def _size(obj: Any) -> int:
    return len(json.dumps(obj, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def shrink_json(obj: Any, max_bytes: int, *, max_str: int = 300) -> Any:
    """Truncates lists (rest -> '… +N more') and long strings until the JSON size is <= max_bytes."""
    o = copy.deepcopy(obj)

    def cut_strings(x):
        if isinstance(x, str) and len(x) > max_str:
            return x[:max_str] + "…"
        if isinstance(x, list):
            return [cut_strings(v) for v in x]
        if isinstance(x, dict):
            return {k: cut_strings(v) for k, v in x.items()}
        return x
    o = cut_strings(o)

    def lists(x, acc):
        if isinstance(x, list):
            acc.append(x)
            for v in x:
                lists(v, acc)
        elif isinstance(x, dict):
            for v in x.values():
                lists(v, acc)
        return acc
    guard = 0
    while _size(o) > max_bytes and guard < 200:
        guard += 1
        cands = [lst for lst in lists(o, []) if len([v for v in lst if not _is_marker(v)]) > 1]
        if not cands:
            break
        lst = max(cands, key=_size)
        real = [v for v in lst if not _is_marker(v)]
        dropped = sum(_marker_n(v) for v in lst if _is_marker(v))
        keep = max(1, len(real) // 2)
        dropped += len(real) - keep
        lst[:] = real[:keep] + [f"… +{dropped} more"]
    if _size(o) > max_bytes:
        txt = json.dumps(o, ensure_ascii=False)
        return {"truncated": txt[: max(0, max_bytes - 40)] + "…"}
    return o


def _is_marker(v: Any) -> bool:
    return isinstance(v, str) and v.startswith("… +") and v.endswith(" more")


def _marker_n(v: str) -> int:
    try:
        return int(v[3:].split(" ")[0])
    except ValueError:
        return 0


def compress_text(text: str, max_lines: int = 40, max_bytes: int | None = None) -> str:
    """Collapse repeated lines ('<line> (x37)'), then truncate to max_lines/max_bytes."""
    out: list[str] = []
    prev, n = None, 0
    for ln in text.splitlines():
        if ln == prev:
            n += 1
            continue
        if prev is not None:
            out.append(prev + (f" (x{n})" if n > 1 else ""))
        prev, n = ln, 1
    if prev is not None:
        out.append(prev + (f" (x{n})" if n > 1 else ""))
    if len(out) > max_lines:
        out = out[:max_lines] + [f"… +{len(out) - max_lines} more"]
    res = "\n".join(out)
    if max_bytes is not None and len(res.encode("utf-8")) > max_bytes:
        cut = res.encode("utf-8")[: max(0, max_bytes - 30)].decode("utf-8", errors="ignore")
        rest = res.count("\n") - cut.count("\n")
        res = cut.rsplit("\n", 1)[0] + f"\n… +{max(1, rest)} more"
    return res
