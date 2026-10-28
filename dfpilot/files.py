"""Runtime files (CONTRACTS §8, §9): read what kern writes, write the inbox. 0 DF calls.

Readers tolerate torn writes: a failed parse is retried once after 50 ms; events are only
consumed as complete ('\\n'-terminated) lines. Python writes via '.<name>.tmp' + os.replace.
"""
from __future__ import annotations

import hashlib
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


# FR-29: `dfllm follow` beats into <save>/.follow.hb (Python-private, like .follow.json); silence from follow
# must never look like "all is well" when it is simply not running
FOLLOW_HB = ".follow.hb"
FOLLOW_STALE_S = 60


def write_follow_hb(save_dir: Path, doc: dict) -> None:
    write_json_atomic(Path(save_dir) / FOLLOW_HB, doc)


def read_follow_hb(save_dir: Path, now: float | None = None) -> tuple[dict | None, float | None]:
    """(doc or None, age in s from the file mtime, None if follow never beat for this save)."""
    p = Path(save_dir) / FOLLOW_HB
    try:
        mt = p.stat().st_mtime
    except OSError:
        return None, None
    doc = read_json(p, retry=False)
    return (doc if isinstance(doc, dict) else None), max(0.0, (time.time() if now is None else now) - mt)


def follow_auto(save_dir: Path, now: float | None = None) -> bool | None:
    """DECISIONS 2: whether a running `dfllm follow` places things itself (True) or runs with --no-auto (False); None
    when no follow beats for this save (or an older one that does not say). With --no-auto the auto-seal never runs."""
    doc, age = read_follow_hb(save_dir, now)
    if doc is None or age is None or age > FOLLOW_STALE_S:
        return None
    v = doc.get("auto")
    return None if isinstance(v, bool) or not isinstance(v, int) else v == 1


def auto_seal_off(save_dir: Path, openings: int, now: float | None = None) -> str | None:
    """DECISIONS 2 (Run 13: follow --no-auto, 14 years of an open door): 'auto-seal off, N openings' when a follow with
    --no-auto is running and the entrance check lists `openings` ways in without door or bridge; else None."""
    if openings > 0 and follow_auto(save_dir, now) is False:
        return f"auto-seal off, {openings} opening{'s' if openings != 1 else ''}"
    return None


def code_stamp() -> str:
    """BUG-042: a digest of the dfpilot package's .py files (path, size, mtime): what a long-running `follow` imported
    against what lies on disk now (Run 11: the BUG-038 placement fix was pulled while an older follow kept running)."""
    root = Path(__file__).resolve().parent
    h = hashlib.sha1()
    for p in sorted(root.rglob("*.py")):
        try:
            st = p.stat()
        except OSError:
            continue
        h.update(f"{p.relative_to(root).as_posix()}:{st.st_size}:{st.st_mtime_ns}\n".encode())
    return h.hexdigest()[:12]


def follow_off(save_dir: Path, now: float | None = None) -> str | None:
    """'follow: OFF (last heartbeat 3h ago)' when follow is not beating for this save; BUG-042: 'follow: OLD CODE ...'
    when the running follow imported other dfpilot code than lies on disk now (a pull it never saw); else None."""
    from .events import fmt_age
    doc, age = read_follow_hb(save_dir, now)
    if age is None:
        return "follow: OFF (no heartbeat yet: start dfllm follow)"
    if age > FOLLOW_STALE_S:
        return f"follow: OFF (last heartbeat {fmt_age(age)} ago)"
    code = (doc or {}).get("code")
    if isinstance(code, str) and code != code_stamp():
        return "follow: OLD CODE (dfpilot changed on disk since it started): restart dfllm follow"
    return None


GUARD = "guard.json"
GUARD_STALE_S = 60                     # the stop guard refreshes `wall` every 5 s while it runs


def read_guard(save_dir: Path, now: float | None = None) -> tuple[dict | None, float | None]:
    """FR-68: (<save>/guard.json of the stop guard, age in s of its `wall`); (None, None) when missing or malformed.
    The guard runs while doc['on'] == 1 and the age is below GUARD_STALE_S."""
    doc = read_json(Path(save_dir) / GUARD, retry=False)
    if not isinstance(doc, dict):
        return None, None
    ints = ("on", "cap", "n", "wall", "since", "ts_off")
    if any(not isinstance(doc.get(k), int) or isinstance(doc.get(k), bool) for k in ints):
        return None, None
    return doc, max(0.0, (time.time() if now is None else now) - doc["wall"])


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


TIMELINE_RESET = "TIMELINE_RESET"      # BUG-121: kern's marker at a boot whose game clock stands before the log's last tick
TICK_SLACK = schema.TICKS["DAY"]       # a state or heartbeat may lag the newest event by a few seconds of timestream


def mark_tick(e: dict) -> int | None:
    """tick_neu of a TIMELINE_RESET event (d.tick_neu, else the event's own tick); None for any other event."""
    if e.get("type") != TIMELINE_RESET:
        return None
    d = e.get("d") if isinstance(e.get("d"), dict) else {}
    t = d.get("tick_neu", e.get("tick"))
    return t if isinstance(t, int) and not isinstance(t, bool) else None


def current_tick(save_dir: Path) -> int | None:
    """The game tick the kernel last published (state, else heartbeat), None when it never did."""
    state = read_state(Path(save_dir))
    t = (state or {}).get("t") if isinstance(state, dict) else None
    if isinstance(t, dict):
        a = t.get("abs")
        if isinstance(a, int) and not isinstance(a, bool):
            return a
        if isinstance(t.get("y"), int) and isinstance(t.get("tick"), int):
            return t["y"] * schema.TICKS["YEAR"] + t["tick"]
    hb, _age = read_heartbeat(Path(save_dir))
    tick = (hb or {}).get("tick") if isinstance(hb, dict) else None
    return tick if isinstance(tick, int) and not isinstance(tick, bool) else None


def tick_cap(save_dir: Path) -> int | None:
    """BUG-121: events with a later tick than this belong to a timeline the loaded save left (the current tick plus a slack
    for a state that lags); None when the clock is unknown."""
    now = current_tick(save_dir)
    return None if now is None else now + TICK_SLACK


def iter_events_rev(save_dir: Path, since_n: int = 0, min_tick: int | None = None,
                    max_tick: int | None = None) -> Iterator[dict]:
    """Events newest first from events.jsonl, then the rotated events.1.jsonl (deduplicated by n).
    Stops at the first event with n <= since_n or tick < min_tick (older than the window).
    BUG-121: events of a discarded timeline are skipped: an event before a TIMELINE_RESET marker (smaller n) whose tick is
    later than the marker's tick_neu (every later marker cuts too), and, with max_tick, any event with a later tick."""
    save_dir, seen = Path(save_dir), set()
    cut = max_tick
    for name in ("events.jsonl", "events.1.jsonl"):
        for ln in _rev_lines(save_dir / name):
            e = _parse_event(ln)
            if e is None or e["n"] in seen:
                continue
            tick = e.get("tick")
            if e["n"] <= since_n or (min_tick is not None and isinstance(tick, int) and tick < min_tick):
                return
            seen.add(e["n"])
            gone = cut is not None and isinstance(tick, int) and tick > cut    # a later marker may drop a marker too
            mt = mark_tick(e)
            if mt is not None:
                cut = mt if cut is None else min(cut, mt)
            if not gone:
                yield e


def tail_events(save_dir: Path, since_n: int = 0, limit: int | None = None, cls: str | None = None,
                types: set[str] | None = None, min_tick: int | None = None, max_tick: int | None = None) -> list[dict]:
    """Events with n > since_n (and tick >= min_tick), ascending, from events.jsonl and events.1.jsonl.
    limit keeps the newest `limit` matches (0/None = all); cls ('A', 'AB', ...) and types filter. BUG-121: events of a
    discarded timeline are left out (iter_events_rev); max_tick also drops events later than the current clock."""
    out = []
    for e in iter_events_rev(save_dir, since_n, min_tick, max_tick):
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

    def __init__(self, save_dir: Path, since_n: int | None = None, tick_fn: Callable[[], int | None] | None = None):
        self.dir = Path(save_dir)
        self.path = self.dir / "events.jsonl"
        self.last_n = last_event_n(self.dir) if since_n is None else since_n
        self.pos, self.ident = 0, None
        self.bad_lines = 0
        # BUG-121: tick_fn = the current game tick (events beyond it + TICK_SLACK are of a discarded timeline);
        # marks = {n: tick_neu} of the TIMELINE_RESET markers: with no replay (since_n None) every event this tail
        # returns is newer than all of them, so only a replay reads the old ones
        self.tick_fn = tick_fn
        self.marks: dict[int, int] = self._scan_marks() if since_n is not None else {}
        if since_n is None:                 # start at the end: no replay of history
            st = self._stat()
            if st:
                self.pos, self.ident = self._complete_end(st.st_size), self._id(st)
        else:
            self._backlog = True

    _backlog = False

    def _scan_marks(self) -> dict[int, int]:
        marks: dict[int, int] = {}
        for name in ("events.1.jsonl", "events.jsonl"):
            try:
                data = (self.dir / name).read_bytes()
            except OSError:
                continue
            if TIMELINE_RESET.encode() not in data:
                continue
            for ln in data.splitlines():
                if TIMELINE_RESET.encode() in ln:
                    e = _parse_event(ln)
                    mt = mark_tick(e) if e else None
                    if mt is not None:
                        marks[e["n"]] = mt
        return marks

    def _discarded(self, e: dict, cap: int | None) -> bool:
        tick = e.get("tick")
        if not isinstance(tick, int):
            return False
        if cap is not None and tick > cap:
            return True
        return any(mn > e["n"] and tick > mt for mn, mt in self.marks.items())

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
        cands, seen = [], set()
        for e in sorted(evs, key=lambda e: e["n"]):
            if e["n"] > self.last_n and e["n"] not in seen:
                seen.add(e["n"])
                cands.append(e)
        if not cands:
            return []
        for e in cands:                     # BUG-121: a marker in this batch cuts the events before it
            mt = mark_tick(e)
            if mt is not None:
                self.marks[e["n"]] = mt
        now = self.tick_fn() if self.tick_fn else None
        cap = now + TICK_SLACK if isinstance(now, int) else None
        self.last_n = cands[-1]["n"]        # the cursor passes the discarded ones too
        return [e for e in cands if not self._discarded(e, cap)]


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


def read_manifest(save_dir: Path) -> dict | None:
    """<save>/manifest.json (kern mirrors the persisted fort manifest there, live L1), if it is a valid
    manifest; None otherwise (callers fall back to `inspect manifest`)."""
    doc = read_json(Path(save_dir) / "manifest.json")
    return doc if isinstance(doc, dict) and not schema.validate("manifest", doc) else None
