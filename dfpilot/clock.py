"""Time abstraction: real time (RealTime) and game time (GameDate) are separate types.

Never mix them: RealTime counts in seconds (epoch, UTC), GameDate in DF ticks (1 day = 1200 ticks,
1 month = 28 days, 1 year = 12 months = 403200 ticks).
"""
from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import datetime, timezone

__all__ = ["RealTime", "GameDate", "Clock", "SystemClock", "FakeClock", "MONTHS", "TICKS_PER_DAY", "TICKS_PER_YEAR"]

TICKS_PER_DAY = 1200
TICKS_PER_MONTH = 28 * TICKS_PER_DAY
TICKS_PER_YEAR = 12 * TICKS_PER_MONTH
MONTHS = ["Granite", "Slate", "Felsite", "Hematite", "Malachite", "Galena", "Limestone", "Sandstone",
          "Timber", "Moonstone", "Opal", "Obsidian"]


@dataclass(frozen=True, order=True)
class RealTime:
    """Real time in seconds since the epoch (UTC)."""
    epoch: float

    def __add__(self, seconds: float) -> "RealTime":
        if isinstance(seconds, (RealTime, GameDate)):
            raise TypeError("RealTime + timestamp is not defined (only + seconds)")
        return RealTime(self.epoch + float(seconds))

    def __sub__(self, other):
        if isinstance(other, RealTime):
            return self.epoch - other.epoch  # seconds
        if isinstance(other, GameDate):
            raise TypeError("do not mix real time and game time")
        return RealTime(self.epoch - float(other))

    def utc(self) -> datetime:
        return datetime.fromtimestamp(self.epoch, tz=timezone.utc)

    def local(self) -> datetime:
        return datetime.fromtimestamp(self.epoch).astimezone()

    def hhmm(self) -> str:
        return self.local().strftime("%H:%M")

    def iso(self) -> str:
        return self.utc().strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass(frozen=True)
class GameDate:
    """Game time: year + tick within the year."""
    year: int
    year_tick: int

    @property
    def abs_ticks(self) -> int:
        return self.year * TICKS_PER_YEAR + self.year_tick

    @property
    def month_idx(self) -> int:
        return min(11, max(0, self.year_tick // TICKS_PER_MONTH))

    @property
    def day(self) -> int:
        return (self.year_tick % TICKS_PER_MONTH) // TICKS_PER_DAY + 1

    def __sub__(self, other):
        if isinstance(other, GameDate):
            return self.abs_ticks - other.abs_ticks  # ticks
        raise TypeError("subtract game time only from game time (result in ticks)")

    def __lt__(self, other: "GameDate") -> bool:
        if not isinstance(other, GameDate):
            raise TypeError("compare game time only with game time")
        return self.abs_ticks < other.abs_ticks

    def text(self) -> str:
        return f"Y{self.year} {MONTHS[self.month_idx]} {self.day}"

    @staticmethod
    def parse_text(s: str) -> "GameDate | None":
        """'12. Hematite, Jahr 102' (companion script format) or 'J102_Hematite_12' / 'Y102_Hematite_12' -> GameDate (day precision)."""
        import re
        if not s:
            return None
        m = re.search(r"(\d+)\.\s*([A-Za-z]+),\s*(?:Jahr|Year)\s*(\d+)", s) or None
        if m:
            day, mon, year = int(m.group(1)), m.group(2), int(m.group(3))
        else:
            m = re.search(r"[JY](\d+)[_ ]([A-Za-z]+)[_ ](\d+)", s)
            if not m:
                return None
            year, mon, day = int(m.group(1)), m.group(2), int(m.group(3))
        if mon not in MONTHS:
            return None
        return GameDate(year, MONTHS.index(mon) * TICKS_PER_MONTH + (day - 1) * TICKS_PER_DAY)


class Clock:
    def now(self) -> RealTime:  # pragma: no cover - abstract
        raise NotImplementedError

    def sleep(self, seconds: float) -> None:  # pragma: no cover - abstract
        raise NotImplementedError


class SystemClock(Clock):
    def now(self) -> RealTime:
        return RealTime(time.time())

    def sleep(self, seconds: float) -> None:
        time.sleep(max(0.0, seconds))


class FakeClock(Clock):
    """Deterministic clock for tests and replay (sleep only advances the clock)."""

    def __init__(self, start: float = 1_790_000_000.0):
        self._t = float(start)

    def now(self) -> RealTime:
        return RealTime(self._t)

    def sleep(self, seconds: float) -> None:
        self._t += max(0.0, seconds)

    def advance(self, seconds: float) -> RealTime:
        self._t += seconds
        return self.now()

    def set(self, epoch: float) -> None:
        self._t = float(epoch)
