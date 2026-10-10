"""Runtime files (CONTRACTS §8, §9): read what kern writes, write the inbox. 0 DF calls.

Readers tolerate torn writes: a failed parse is retried once after 50 ms; events are only
consumed as complete ('\\n'-terminated) lines. Python writes via '.<name>.tmp' + os.replace.
"""
from __future__ import annotations

import json
import os
import secrets
import time
from pathlib import Path
from typing import Any, Callable, Iterator

from . import schema

RETRY_S = 0.05
_BLOCK = 1 << 16


# ---------------------------------------------------------------- json helpers
def dumps(doc: Any) -> str:
    """Compact, sorted keys, UTF-8 (the same shape Lua's json.encode writes)."""
    return json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def read_json(path: Path, retry: bool = True, sleep: Callable[[float], None] = time.sleep) -> Any:
    """Parsed JSON or None (missing/unparsable). One retry after 50 ms on a parse error."""
    for attempt in (0, 1):
        try:
            return json.loads(Path(path).read_text(encoding="utf-8-sig"))
        except FileNotFoundError:
            return None
        except (OSError, ValueError):
            if attempt or not retry:
                return None
            sleep(RETRY_S)
    return None


def write_json_atomic(path: Path, doc: Any) -> Path:
    """Write to '.<name>.tmp' in the same folder, then os.replace (retried: readers may hold the file)."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name("." + path.name + ".tmp")
    tmp.write_text(dumps(doc) + "\n", encoding="utf-8", newline="\n")
    for i in range(5):
        try:
            os.replace(tmp, path)
            return path
        except PermissionError:
            if i == 4:
                raise
            time.sleep(RETRY_S)
    return path


# ---------------------------------------------------------------- state, heartbeat
def read_state_ex(save_dir: Path, sleep: Callable[[float], None] = time.sleep) -> tuple[dict | None, dict]:
    """(best valid state or None, info). CONTRACTS §9.3 reader rule (schema.prune_state): a slot is
    discarded only when it does not parse or a required key is invalid; invalid optional keys are
    dropped (info.dropped {slot: [keys]}). info: slot, seq, errors {slot: first error}, retried,
    fallback (highest-seq parsable but unusable doc, for diagnostics only)."""
    save_dir = Path(save_dir)
    info: dict = {"slot": None, "seq": None, "errors": {}, "retried": False, "fallback": None, "dropped": {}}
    for attempt in (0, 1):
        valid, bad, torn, errors = [], [], False, {}
        for slot in ("a", "b"):
            p = save_dir / f"state.{slot}.json"
            try:
                text = p.read_text(encoding="utf-8-sig")
            except FileNotFoundError:
                continue
            except OSError as e:
                errors[slot], torn = f"read: {e}", True
                continue
            try:
                doc = json.loads(text)
            except ValueError as e:
                errors[slot], torn = f"parse: {e}", True
                continue
            pruned, errs = schema.prune_state(doc)
            if errs:
                errors[slot] = errs[0]
            if pruned is None:
                if isinstance(doc, dict) and isinstance(doc.get("seq"), int) and not isinstance(doc.get("seq"), bool):
                    bad.append((doc["seq"], slot, doc))
                continue
            if errs:
                info["dropped"][slot] = sorted(set(doc) - set(pruned))
            valid.append((pruned["seq"], slot, pruned))
        info["errors"], info["retried"] = errors, attempt == 1
        if valid:
            seq, slot, doc = max(valid, key=lambda x: x[0])
            info.update(slot=slot, seq=seq)
            return doc, info
        if bad:
            info["fallback"] = max(bad, key=lambda x: x[0])[2]
        if not torn or attempt:
            return None, info
        sleep(RETRY_S)
    return None, info


def read_state(save_dir: Path) -> dict | None:
    """Both slots, drop invalid ones, take the higher seq; one retry after a torn read."""
    return read_state_ex(save_dir)[0]


def read_heartbeat(save_dir: Path, now: float | None = None) -> tuple[dict | None, float | None]:
    """(doc or None if torn/missing, age in s from the file mtime or None if missing)."""
    p = Path(save_dir) / "heartbeat"
    try:
        mt = p.stat().st_mtime
    except OSError:
        return None, None
    doc = read_json(p, retry=False)
    if not isinstance(doc, dict) or schema.validate("heartbeat", doc):
        doc = None
    return doc, max(0.0, (time.time() if now is None else now) - mt)


# ---------------------------------------------------------------- events
def _rev_lines(path: Path) -> Iterator[bytes]:
    """Complete lines of a file, last first; an unterminated last line is skipped."""
    try:
        f = open(path, "rb")
    except OSError:
        return
    with f:
        f.seek(0, 2)
        pos = f.tell()
        while pos > 0:                      # cut off the unterminated tail
            k = min(_BLOCK, pos)
            f.seek(pos - k)
            i = f.read(k).rfind(b"\n")
            if i >= 0:
                pos = pos - k + i + 1
                break
            pos -= k
        rest = b""
        while pos > 0:
            k = min(_BLOCK, pos)
            pos -= k
            f.seek(pos)
            parts = (f.read(k) + rest).split(b"\n")
            rest = parts.pop(0) if pos > 0 else b""
            for ln in reversed(parts):
                if ln.strip():
                    yield ln


def _parse_event(line: bytes) -> dict | None:
    try:
        e = json.loads(line.decode("utf-8", "replace"))
    except ValueError:
        return None
    if isinstance(e, dict) and isinstance(e.get("n"), int) and not isinstance(e.get("n"), bool):
        return e
    return None


def iter_events_rev(save_dir: Path, since_n: int = 0, min_tick: int | None = None) -> Iterator[dict]:
    """Events newest first from events.jsonl, then the rotated events.1.jsonl (deduplicated by n).
    Stops at the first event with n <= since_n or tick < min_tick (older than the window)."""
    save_dir, seen = Path(save_dir), set()
    for name in ("events.jsonl", "events.1.jsonl"):
        for ln in _rev_lines(save_dir / name):
            e = _parse_event(ln)
            if e is None or e["n"] in seen:
                continue
            tick = e.get("tick")
            if e["n"] <= since_n or (min_tick is not None and isinstance(tick, int) and tick < min_tick):
                return
            seen.add(e["n"])
            yield e


def tail_events(save_dir: Path, since_n: int = 0, limit: int | None = None, cls: str | None = None,
                types: set[str] | None = None, min_tick: int | None = None) -> list[dict]:
    """Events with n > since_n (and tick >= min_tick), ascending, from events.jsonl and events.1.jsonl.
    limit keeps the newest `limit` matches (0/None = all); cls ('A', 'AB', ...) and types filter."""
    out = []
    for e in iter_events_rev(save_dir, since_n, min_tick):
        if (cls and e.get("cls") not in cls) or (types and e.get("type") not in types):
            continue
        out.append(e)
        if limit and len(out) >= limit:
            break
    out.sort(key=lambda e: e["n"])
    return out


def last_event_n(save_dir: Path) -> int:
    for name in ("events.jsonl", "events.1.jsonl"):
        for ln in _rev_lines(Path(save_dir) / name):
            e = _parse_event(ln)
            if e is not None:
                return e["n"]
    return 0


class EventTail:
    """Incremental tail of events.jsonl for `follow`: byte offset + n filter, survives rotation
    (kern renames the current file to events.1.jsonl and starts a new one)."""

    def __init__(self, save_dir: Path, since_n: int | None = None):
        self.dir = Path(save_dir)
        self.path = self.dir / "events.jsonl"
        self.last_n = last_event_n(self.dir) if since_n is None else since_n
        self.pos, self.ident = 0, None
        self.bad_lines = 0
        if since_n is None:                 # start at the end: no replay of history
            st = self._stat()
            if st:
                self.pos, self.ident = self._complete_end(st.st_size), self._id(st)
        else:
            self._backlog = True

    _backlog = False

    def _stat(self):
        try:
            return os.stat(self.path)
        except OSError:
            return None

    @staticmethod
    def _id(st) -> int:
        return st.st_ino            # Windows: NTFS file index; a rename keeps it, a new file gets a new one

    def _complete_end(self, size: int) -> int:
        try:
            with open(self.path, "rb") as f:
                f.seek(max(0, size - _BLOCK))
                data = f.read(min(size, _BLOCK))
        except OSError:
            return 0
        i = data.rfind(b"\n")
        return size - len(data) + i + 1 if i >= 0 else max(0, size - len(data))

    def _read_from(self, path: Path, pos: int) -> tuple[list[dict], int]:
        try:
            with open(path, "rb") as f:
                f.seek(pos)
                data = f.read()
        except OSError:
            return [], pos
        i = data.rfind(b"\n")
        if i < 0:
            return [], pos
        out = []
        for ln in data[:i].split(b"\n"):
            if not ln.strip():
                continue
            e = _parse_event(ln)
            if e is None:
                self.bad_lines += 1
            elif e["n"] > self.last_n:
                out.append(e)
        return out, pos + i + 1

    def poll(self) -> list[dict]:
        out: list[dict] = []
        if self._backlog:                   # explicit since_n: replay the rotated file first
            self._backlog = False
            out, _ = self._read_from(self.dir / "events.1.jsonl", 0)
        st = self._stat()
        if st is None:
            return self._finish(out)
        ident = self._id(st)
        if self.ident is not None and (ident != self.ident or st.st_size < self.pos):
            old, _ = self._read_from(self.dir / "events.1.jsonl", self.pos)   # rest of the rotated file
            out += old
            self.pos = 0
        self.ident = ident
        new, self.pos = self._read_from(self.path, self.pos)
        return self._finish(out + new)

    def _finish(self, evs: list[dict]) -> list[dict]:
        res, seen = [], set()
        for e in sorted(evs, key=lambda e: e["n"]):
            if e["n"] > self.last_n and e["n"] not in seen:
                seen.add(e["n"])
                res.append(e)
        if res:
            self.last_n = res[-1]["n"]
        return res


# ---------------------------------------------------------------- inbox / outbox
_id_seq = [0]


def new_cmd_id(ts_ms: int | None = None, prefix: str = "c") -> str:
    """c<ms hex><4 random hex><2 hex per-process counter>: unique within a process, random across processes."""
    ts_ms = int(time.time() * 1000) if ts_ms is None else ts_ms
    _id_seq[0] = (_id_seq[0] + 1) % 256
    return f"{prefix}{ts_ms:x}{secrets.token_hex(2)}{_id_seq[0]:02x}"


def write_inbox(save_dir: Path, verb: str, args: dict, by: str = "cli", cmd_id: str | None = None,
                ts_ms: int | None = None) -> str:
    """Validate (schema.check 'inbox', raises SchemaError) and write inbox/<ts>-<id>.json. Returns the id."""
    ts_ms = int(time.time() * 1000) if ts_ms is None else int(ts_ms)
    cmd_id = cmd_id or new_cmd_id(ts_ms)
    doc = {"id": cmd_id, "verb": verb, "args": args, "by": by, "ts": ts_ms}
    schema.check("inbox", doc)
    write_json_atomic(Path(save_dir) / "inbox" / schema.inbox_name(cmd_id, ts_ms), doc)
    return cmd_id


def read_outbox(save_dir: Path, cmd_id: str, timeout_s: float = 0.0, poll_s: float = 0.1, delete: bool = True,
                sleep: Callable[[float], None] = time.sleep,
                clock: Callable[[], float] = time.monotonic) -> dict | None:
    """Reply for cmd_id (outbox/<id>.json or <id>-<n>.json), waiting up to timeout_s; deleted after reading."""
    box = Path(save_dir) / "outbox"
    deadline = clock() + max(0.0, timeout_s)
    while True:
        cands = [box / f"{cmd_id}.json"]
        try:
            cands += sorted(box.glob(f"{cmd_id}-*.json"))
        except OSError:
            pass
        for p in cands:
            doc = read_json(p, sleep=sleep)
            if isinstance(doc, dict) and doc.get("id") == cmd_id:
                if delete:
                    try:
                        p.unlink()
                    except OSError:
                        pass
                return doc
        if clock() >= deadline:
            return None
        sleep(poll_s)


def prune_outbox(save_dir: Path, max_age_s: float = 600, now: float | None = None) -> int:
    """Delete outbox replies nobody read within max_age_s (a `cmd --wait` that timed out, a crashed reader).
    CONTRACTS §8: Python deletes replies after reading; this is the backstop. Returns the number deleted."""
    now = time.time() if now is None else now
    n = 0
    try:
        ps = list((Path(save_dir) / "outbox").glob("*.json"))
    except OSError:
        return 0
    for p in ps:
        try:
            if now - p.stat().st_mtime > max_age_s:
                p.unlink()
                n += 1
        except OSError:
            pass
    return n


def pending_inbox(save_dir: Path) -> list[tuple[str, float]]:
    """(name, age_s) of inbox files kern has not consumed yet."""
    out, now = [], time.time()
    try:
        for p in sorted((Path(save_dir) / "inbox").glob("*.json")):
            if not p.name.startswith("."):
                out.append((p.name, now - p.stat().st_mtime))
    except OSError:
        pass
    return out


# ---------------------------------------------------------------- snapshots
def snap_paths(save_dir: Path) -> list[Path]:
    """snap/*.json, newest first."""
    try:
        ps = [p for p in (Path(save_dir) / "snap").glob("*.json") if not p.name.startswith(".")]
    except OSError:
        return []
    return sorted(ps, key=lambda p: p.stat().st_mtime, reverse=True)


def read_snapshot(path: Path) -> dict | None:
    doc = read_json(path)
    return doc if isinstance(doc, dict) and not schema.validate("snapshot", doc) else None


def latest_snapshot(save_dir: Path, purpose: str | None = None) -> dict | None:
    for p in snap_paths(save_dir):
        doc = read_snapshot(p)
        if doc and (purpose is None or doc.get("purpose") == purpose):
            return doc
    return None


def prune_snaps(save_dir: Path, keep: int = 10) -> int:
    n = 0
    for p in snap_paths(save_dir)[keep:]:
        try:
            p.unlink()
            n += 1
        except OSError:
            pass
    return n


# ---------------------------------------------------------------- python log
def log_cli(save_dir: Path | None, origin: str, what: str, args: Any = None, result: str = "ok") -> None:
    """Append to <save>/cli.log: wall, origin, what, args_json, result (tab separated, rotated at 1 MB)."""
    if save_dir is None:
        return
    p = Path(save_dir) / "cli.log"
    line = "\t".join([str(int(time.time())), origin, what, dumps(args if args is not None else {}),
                      str(result).replace("\t", " ").replace("\n", " ")[:300]]) + "\n"
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        if p.exists() and p.stat().st_size > 1 << 20:
            os.replace(p, p.with_name("cli.log.1"))
        with open(p, "a", encoding="utf-8", newline="\n") as f:
            f.write(line)
    except OSError:
        pass
