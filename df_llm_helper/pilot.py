"""Pilot: connects client, store, files, clock -> collector, digest, autopilot, guard (one cycle)."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from .client import MAX_REPORT_ID_CMD, SERVICES_CMD, DFClient
from .clock import Clock, SystemClock
from .config import Config
from .digest import DigestState, build_digest, tokens
from .guard import GuardRunner, GuardState, target_fps, GuardInputs
from .rules import Engine, build_context, load_rules
from .anomaly import GamelogReader, cancel_loops
from .snapshot import Snapshot, collect
from .store import Store
from .toolsfs import ToolsDir

__all__ = ["Pilot", "CycleReport"]


@dataclass
class CycleReport:
    digest: str = ""
    actions: list = field(default_factory=list)
    guard: list = field(default_factory=list)
    new_game: bool = False
    snapshot: Snapshot | None = None

    def commands(self) -> list[str]:
        return [a.cmd for a in self.actions if getattr(a, "cmd", None)]


class Pilot:
    def __init__(self, cfg: Config, client: DFClient, *, store: Store | None = None, clock: Clock | None = None,
                 tools: ToolsDir | None = None, probe=None, rules=None):
        self.cfg = cfg
        self.client = client
        self.clock = clock or client.clock or SystemClock()
        self.store = store or Store(cfg.path("state_db"))
        self.tools = tools or ToolsDir(cfg.path("tools"), self.clock, cfg.path("scopes"))
        self.probe = probe
        self._rules = rules

    # ---- Snapshot
    def commands(self) -> list[str]:
        cmds = list(self.cfg.get("collect.commands"))
        for extra in (MAX_REPORT_ID_CMD, SERVICES_CMD):
            if extra not in cmds and self.cfg.get("collect.guard_probes", True):
                cmds.append(extra)
        return cmds

    def snapshot(self) -> Snapshot:
        snap = collect(self.client, self.commands(), timeout=float(self.cfg.get("collect.timeout_s", 40)))
        self._check_new_game(snap)
        return snap

    def _check_new_game(self, snap: Snapshot) -> bool:
        gid = snap.game_id
        old = self.store.get("game_id")
        if gid and old and gid != old:
            self.store.reset_game_state()
            self.store.set("game_id", gid)
            self.store.warn(self.clock.now().epoch, "pilot", "new_game", f"NEW GAME detected ({snap.fort}): "
                            f"counters/caches reset", "warn")
            self._new_game = True
            return True
        if gid and not old:
            self.store.set("game_id", gid)
        self._new_game = False
        return False

    # ---- gamelog / cancel loops
    def gamelog(self) -> GamelogReader:
        return GamelogReader(self.cfg.get("paths.gamelog"), self.store)

    def cancels(self, refresh: bool = True) -> list:
        gl = self.gamelog()
        if refresh:
            gl.new_lines()
        return cancel_loops(gl.recent(), min_count=int(self.cfg.get("anomaly.cancel_min", 20)),
                            top=int(self.cfg.get("anomaly.cancel_top", 3)))

    def kb_hint(self, loop) -> str:
        try:
            from .kb import KB
            hits = KB.load(self.cfg).search(f"{loop.job} {loop.reason}", k=1)
            return f"kb {hits[0].entry.id}" if hits and hits[0].score > 1.0 else ""
        except Exception:
            return ""

    # ---- context
    def context(self, snap: Snapshot, cancels: list | None = None) -> dict:
        guard_info = self.store.get("guard.info") or {}
        if "target_fps" not in guard_info:
            st = GuardState.from_dict(self.store.get("guard.state"))
            guard_info = {"slowed": st.slowed, "target_fps": target_fps(st, GuardInputs(normal_fps=snap.normal_fps),
                                                                          self.cfg["guard"])}
        files = {"last_report_id": self.tools.last_report_id(), "heartbeat_age_min": self.tools.heartbeat_age_min(),
                 "events_age_min": self.tools.events_info()[1]}
        return build_context(snap, flags=self.tools.flags(), guard=guard_info, cfg=self.cfg.data,
                             cancels=cancels if cancels is not None else self.cancels(refresh=False), files=files)

    # ---- Digest
    def digest(self, snap: Snapshot | None = None, *, scope: str | None = None, since_last: bool = True,
               include_warnings: bool = True, persist: bool = True) -> str:
        """persist=False (BUG-101/BUG-117 B: overlay, --dry-run): a read-only report - the delta state, inbox/bus
        'seen' marks, warnings, snapshot and KPI rows stay untouched, so the orchestrator's next digest is complete."""
        snap = snap or self.snapshot()
        key = f"digest.state.{scope or 'all'}"
        state = DigestState.from_dict(self.store.get(key))
        inbox_scope = scope or self.cfg.get("digest.inbox_scope", "orchestrator")
        warnings: list = []
        if include_warnings and scope in (None, "orchestrator"):
            warnings = self.store.take_warnings() if persist else self.store.peek_warnings()
            warnings = [_with_age(w, self.clock.now().epoch) for w in warnings]
        if scope in (None, "orchestrator"):
            warnings += self.trend_warnings(snap)
        bus_map = self._bus_unread(inbox_scope)
        text, new = build_digest(snap, state, th=self.cfg.th, max_tokens=int(self.cfg.get("digest.max_tokens", 600)),
                                 flags=self.tools.flags(),
                                 inbox=self.tools.inbox_lines(inbox_scope) + list(bus_map),
                                 warnings=warnings, scope=scope,
                                 now_hhmm=self._last_hhmm(state), since_last=since_last,
                                 inbox_max=int(self.cfg.get("digest.inbox_max_lines", 6)),
                                 inbox_width=int(self.cfg.get("digest.inbox_line_chars", 110)),
                                 cancels=self.cancels(refresh=persist), hint=self.kb_hint,
                                 extra=self.loop_items() if scope in (None, "orchestrator") else None)
        if not persist:
            return text
        # BUG-111: only bus messages that were really shown are marked read; the rest stays unread
        import hashlib
        shown = set(new.inbox_seen) - set(state.inbox_seen)
        ids = [mid for ln, mid in bus_map.items() if hashlib.sha1(ln.encode("utf-8")).hexdigest()[:12] in shown]
        if ids:
            self.store.db.execute(f"UPDATE messages SET status='read' WHERE status='new' AND id IN "
                                  f"({','.join('?' * len(ids))})", tuple(ids))
        new.ts = self.clock.now().epoch
        self.store.set(key, new.to_dict())
        self.store.add_snapshot(self.clock.now().epoch, snap.game_id, snap.facts())
        if scope in (None, "orchestrator"):
            from .metrics import record_kpis
            record_kpis(self.store, self.clock.now().epoch, snap)
        return text

    def loop_items(self) -> list:
        """FEATURE-006: duplicate/hanging background loops as digest items (delta: shown once, then 'still open')."""
        from .digest import Item
        try:
            from .loops import scan
            infos = scan(self.tools.path, self.cfg.get("loops", {}))
        except Exception:  # noqa: BLE001 - the registry must never break the digest
            return []
        out = []
        for name in sorted({i.name for i in infos if "DUPLICATE" in i.marks}):
            pids = [str(i.pid) for i in infos if i.name == name and "DUPLICATE" in i.marks]
            out.append(Item("warn", f"loop:dup:{name}", "Loops", f"Loop {name} runs {len(pids)}x (pids {', '.join(pids)})"
                            f" -> python -m df_llm_helper loops list", str(len(pids)), ("orchestrator", "infra")))
        for i in infos:
            if "STALE" in i.marks and "DUPLICATE" not in i.marks:
                out.append(Item("warn", f"loop:stale:{i.name}", "Loops", f"Loop {i.name} (pid {i.pid}) without "
                                f"heartbeat -> python -m df_llm_helper loops stop {i.name} --kill", str(i.pid),
                                ("orchestrator", "infra")))
        return out

    def _bus_unread(self, recipient: str) -> dict:
        """Unread bus messages as inbox lines -> message id (not marked read here)."""
        from .bus import Bus
        out: dict = {}
        for m in Bus(self.store, self.clock).read(recipient, limit=50, mark=False):
            out.setdefault(self._bus_line(m), m.id)
        return out

    @staticmethod
    def _bus_line(m) -> str:
        return (f"- from {m.sender}, {m.topic or 'bus'}: {('[' + m.prio.upper() + '] ') if m.prio != 'info' else ''}"
                f"{m.text}" + (f" (x{m.count})" if m.count > 1 else ""))

    def bus_lines(self, recipient: str) -> list[str]:
        """Unread bus messages as inbox lines (they are marked as read in the process)."""
        from .bus import Bus
        bus = Bus(self.store, self.clock)
        return [self._bus_line(m) for m in bus.read(recipient, limit=50)]

    def trend_warnings(self, snap: Snapshot) -> list[dict]:
        """F14: robust trend anomalies (MAD) on the snapshot history, with a KB cause hint."""
        from .anomaly import series_anomalies
        hist = [h["facts"] for h in self.store.snapshots(200) if h.get("game_id") in (None, snap.game_id)]
        hist.append(snap.facts())

        def hint(q: str) -> str:
            try:
                from .kb import KB
                hits = KB.load(self.cfg).search(q, k=1, include_unreviewed=False)
                return f"kb {hits[0].entry.id}" if hits else ""
            except Exception:
                return ""
        out = []
        for a in series_anomalies(hist, hint=hint):
            word = "falls" if a.kind == "fall" else "rises"
            out.append({"level": "warn", "key": f"anomaly:{a.series}", "source": "trend", "ts": round(a.value),
                        "text": f"{a.series} {word} unusually: {a.value:g} (z={a.score})"
                                + (f" -> {a.hint}" if a.hint else "")})
        return out

    def _last_hhmm(self, state: DigestState) -> str:
        from .clock import RealTime
        return RealTime(state.ts).hhmm() if state.ts else ""

    # ---- Autopilot
    def rules(self):
        if self._rules is None:
            self._rules = load_rules(Path(self.cfg.get("paths.data")) / "rules")
        return self._rules

    def autopilot(self, snap: Snapshot | None = None, *, dry_run: bool = False):
        snap = snap or self.snapshot()
        eng = Engine(self.rules(), self.client, self.store, self.tools, self.clock, cfg=self.cfg.data, dry_run=dry_run)
        return eng.cycle(self.context(snap), refresh=lambda: self.context(self.snapshot()))

    # ---- Guard
    def guard(self, snap: Snapshot | None = None, *, dry_run: bool = False):
        snap = snap or self.snapshot()
        return GuardRunner(self.client, self.store, self.tools, self.clock, self.cfg.data, self.probe).cycle(
            snap, dry_run=dry_run)

    # ---- one cycle: collector -> guard -> autopilot -> digest
    def cycle(self, *, dry_run: bool = False, digest: bool = True) -> CycleReport:
        snap = self.snapshot()
        rep = CycleReport(snapshot=snap, new_game=getattr(self, "_new_game", False))
        gacts, _, _ = self.guard(snap, dry_run=dry_run)
        rep.guard = gacts
        rep.actions = self.autopilot(snap, dry_run=dry_run)
        if digest:      # BUG-117 B: a dry run must not consume the report of the next real check
            rep.digest = self.digest(snap, persist=not dry_run)
        return rep

    def heartbeat(self) -> None:
        self.tools.touch_heartbeat()


def _with_age(w: dict, now: float, min_age_s: float = 1800) -> dict:
    """BUG-117 A: a queued warning older than 30 min says how old it is (it may be obsolete by now)."""
    try:
        age = now - float(w.get("ts"))
    except (TypeError, ValueError):
        return w
    if age < min_age_s:
        return w
    ago = f"{age / 3600:.0f}h" if age >= 5400 else f"{age / 60:.0f} min"
    return {**w, "text": f"{w.get('text')} ({ago} ago)"}


def token_report(text: str) -> str:
    return f"{tokens(text)} tokens (approximation len/3)"
