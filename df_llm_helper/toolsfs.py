"""Access to the files of the existing system (SPEC 5.3): tools/*.flag, heartbeat, events.log,
last-report-id.txt, tools/scopes/inbox-*.md. Age is always computed via the clock (testable with FakeClock)."""
from __future__ import annotations

import hashlib
import os
import re
from dataclasses import dataclass
from pathlib import Path

from .clock import Clock

__all__ = ["FlagInfo", "ToolsDir", "read_text_tolerant"]


def read_text_tolerant(path: Path) -> str:
    """UTF-8 (with/without BOM), UTF-16 with BOM (PowerShell 5.1 '>' / Out-File), else cp1252, else latin-1."""
    return decode_tolerant(Path(path).read_bytes())


def decode_tolerant(data: bytes) -> str:
    """Bytes -> text like read_text_tolerant."""
    if data[:2] in (b"\xff\xfe", b"\xfe\xff"):
        try:
            return data.decode("utf-16")
        except UnicodeDecodeError:
            pass
    for enc in ("utf-8-sig", "cp1252"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("latin-1")


@dataclass
class FlagInfo:
    name: str
    exists: bool
    age_min: float | None = None
    text: str = ""


class ToolsDir:
    def __init__(self, path: str | Path, clock: Clock, scopes: str | Path | None = None):
        self.path = Path(path)
        self.scopes = Path(scopes) if scopes else self.path / "scopes"
        self.clock = clock

    # ---- general
    def age_min(self, p: Path) -> float | None:
        try:
            return max(0.0, (self.clock.now().epoch - p.stat().st_mtime) / 60.0)
        except OSError:
            return None

    # ---- Flags
    def flag_path(self, name: str) -> Path:
        if name == "pause.hold" or name == "pause":
            return self.path / "pause.hold"
        return self.path / (name if name.endswith(".flag") else f"{name}.flag")

    def flag(self, name: str) -> FlagInfo:
        p = self.flag_path(name)
        key = name.removesuffix(".flag")
        if not p.exists():
            return FlagInfo(key, False)
        try:
            text = read_text_tolerant(p).strip()
        except OSError:
            text = ""
        return FlagInfo(key, True, self.age_min(p), text[:300])

    def flags(self) -> dict[str, FlagInfo]:
        out: dict[str, FlagInfo] = {}
        if self.path.is_dir():
            for p in sorted(self.path.glob("*.flag")):
                out[p.stem] = self.flag(p.stem)
            if (self.path / "pause.hold").exists():
                out["pause.hold"] = self.flag("pause.hold")
        return out

    def delete_flag(self, name: str) -> bool:
        p = self.flag_path(name)
        try:
            p.unlink()
            return True
        except FileNotFoundError:
            return False

    def write_flag(self, name: str, text: str) -> None:
        p = self.flag_path(name)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text, encoding="utf-8")
        t = self.clock.now().epoch
        os.utime(p, (t, t))

    # ---- heartbeat
    @property
    def heartbeat(self) -> Path:
        return self.path / "heartbeat.txt"

    def heartbeat_age_min(self) -> float | None:
        return self.age_min(self.heartbeat)

    def touch_heartbeat(self) -> None:
        self.path.mkdir(parents=True, exist_ok=True)
        now = self.clock.now()
        self.heartbeat.write_text(now.local().strftime("%Y-%m-%dT%H:%M:%S"), encoding="utf-8")
        os.utime(self.heartbeat, (now.epoch, now.epoch))

    # ---- watcher files
    @property
    def last_report_file(self) -> Path:
        return self.path / "last-report-id.txt"

    def last_report_id(self) -> int | None:
        try:
            txt = read_text_tolerant(self.last_report_file).strip().splitlines()
            return int(txt[0]) if txt and re.match(r"^-?\d+$", txt[0].strip()) else None
        except (OSError, ValueError):
            return None

    def set_last_report_id(self, n: int) -> None:
        self.path.mkdir(parents=True, exist_ok=True)
        self.last_report_file.write_text(str(int(n)), encoding="utf-8")
        t = self.clock.now().epoch
        os.utime(self.last_report_file, (t, t))

    @property
    def events_log(self) -> Path:
        return self.path / "events.log"

    def events_info(self) -> tuple[int | None, float | None]:
        p = self.events_log
        if not p.exists():
            return None, None
        return p.stat().st_size, self.age_min(p)

    def append_event(self, level: str, text: str, tag: str = "HELPER") -> str:
        """Line in the format of the PowerShell watcher: 'CRITICAL HH:MM:SS [TAG] text' (legacy logs use 'KRITISCH')."""
        line = f"{level} {self.clock.now().local().strftime('%H:%M:%S')} [{tag}] {text}"
        self.path.mkdir(parents=True, exist_ok=True)
        with self.events_log.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
        return line

    def events_lines(self, last_n: int = 200) -> list[str]:
        if not self.events_log.exists():
            return []
        return read_text_tolerant(self.events_log).splitlines()[-last_n:]

    def events_since(self, pos: int, head: str | None = None, max_lines: int = 5000) -> tuple[list[str], int, str]:
        """New complete lines of events.log after byte offset `pos` (BUG-100: a line-count window of the last N lines
        goes blind once the file is longer than N). `head` = hash of the first line from the previous call: a
        different first line or a shorter file means the log was rotated/recreated -> read from the start.
        Returns (lines, new_pos, head); a trailing line without newline is left for the next call."""
        p = self.events_log
        try:
            with p.open("rb") as f:
                first = f.readline(4096)
                size = f.seek(0, 2)
                h = hashlib.sha1(first.rstrip(b"\r\n")).hexdigest()[:10] if first.endswith(b"\n") else ""
                if pos < 0 or pos > size or (head and h and head != h):
                    pos = 0
                f.seek(pos)
                data = f.read()
        except (FileNotFoundError, IsADirectoryError, PermissionError):
            return [], 0, ""
        end = data.rfind(b"\n")
        if end < 0:
            return [], pos, h
        chunk = data[:end + 1]
        for enc in ("utf-8-sig" if pos == 0 else "utf-8", "cp1252"):
            try:
                text = chunk.decode(enc)
                break
            except UnicodeDecodeError:
                continue
        else:
            text = chunk.decode("latin-1")
        return text.splitlines()[-max_lines:], pos + end + 1, h

    def events_offset_after(self, n_lines: int) -> int:
        """Byte offset after the first n lines (migration of the old line-count state of wake)."""
        try:
            data = self.events_log.read_bytes()
        except OSError:
            return 0
        off = 0
        for _ in range(max(0, n_lines)):
            i = data.find(b"\n", off)
            if i < 0:
                return len(data)
            off = i + 1
        return off

    # ---- inbox (markdown, backwards compatibility)
    def inbox_file(self, scope: str) -> Path:
        return self.scopes / f"inbox-{scope}.md"

    def inbox_lines(self, scope: str) -> list[str]:
        p = self.inbox_file(scope)
        if not p.exists():
            return []
        return [ln.rstrip() for ln in read_text_tolerant(p).splitlines() if ln.startswith("- ")]

    def memory_file(self, scope: str) -> Path:
        return self.scopes / f"{scope}.md"
