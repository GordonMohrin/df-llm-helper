"""`dfllm follow`: tail events.jsonl, rate-limit class-A wakes, print one wake line (<= 150 tokens) per wake.

DESIGN §8 limits: <= 1 wake per type per 5 min, bursts merged within 60 s, <= 6 wakes per hour.
Held events are never dropped: they wait (merged) for the next allowed wake. Class B/C events do
not wake; the follower acts on two of them without the LLM:
  SNAPSHOT_READY purpose=audit -> inspect manifest -> bp.topo.audit(snap, manifest) -> inbox `audit`
  PROJECT_REQUEST tpl=tombs    -> snapshot purpose=sites -> best free site (cmd.place) -> bp.place
The outbox reply of every automatic command is read; a refusal or no reply within AUTO_TIMEOUT_S
wakes as AUTO_FAIL (a refused bp.place is rolled back). Unread replies are pruned after 10 min.
Only wake lines go to stdout (one line = one Monitor notification); details go to <save>/cli.log.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path
from typing import Callable

from . import files, paths, schema
from .events import clip, est_tokens, fmt_tick

WAKE_TOKENS = 150
WAKE_TYPES = {t for t, (c, _, _) in schema.EVENTS.items() if c == "A"}
SYNTH = {"HB_STALE", "AUTO_FAIL"}          # follower's own wake reasons (not kern events)
PRIO = ["BREACH", "GATE_FAIL", "DEATHS_3PLUS", "KERN_FAULT", "HB_STALE", "SIEGE_END", "DRILL_FAIL",
        "PERF_DEGRADED", "DECISION_NEEDED", "PROJECT_BLOCKED", "PLAN_EXHAUSTED", "YEAR_REVIEW", "AUTO_FAIL"]
NEXT = {"YEAR_REVIEW": "dfllm plan propose", "PLAN_EXHAUSTED": "dfllm plan propose",
        "DECISION_NEEDED": "ask Gordon in chat, then config/decisions.yaml", "KERN_FAULT": "dfllm doctor",
        "PERF_DEGRADED": "dfllm doctor", "HB_STALE": "dfllm doctor", "AUTO_FAIL": "dfllm doctor"}
HB_STALE_S = 300
AUTO_TIMEOUT_S = 60
TOMBS_COOLDOWN_S = 600
PRUNE_EVERY_S = 60
ERR_EVERY_S = 60                               # stderr 'poll error' at most once per minute


class WakeGate:
    """Pending class-A events -> at most one wake line per allowed slot."""

    def __init__(self, per_type_s: float = 300, merge_s: float = 60, quiet_s: float = 10, per_hour: int = 6):
        self.per_type_s, self.merge_s, self.quiet_s, self.per_hour = per_type_s, merge_s, quiet_s, per_hour
        self.pending: dict[str, dict] = {}     # type -> {c: count, n0: first n, e: latest event}
        self.first = self.last = None          # wall time of the first / latest pending arrival
        self.type_last: dict[str, float] = {}  # type -> wall of its last wake
        self.wakes: list[float] = []           # walls of wakes (last hour)

    def add(self, e: dict, now: float) -> None:
        t = e["type"]
        p = self.pending.setdefault(t, {"c": 0, "n0": e.get("n"), "e": e})
        p["c"] += 1
        p["e"] = e
        if p["n0"] is None:
            p["n0"] = e.get("n")
        self.first = now if self.first is None else self.first
        self.last = now

    def blocked(self, now: float) -> str | None:
        """Why the pending burst cannot wake now (None = it can)."""
        if not self.pending:
            return "empty"
        if now - self.last < self.quiet_s and now - self.first < self.merge_s:
            return "merging"
        self.wakes = [w for w in self.wakes if now - w < 3600]
        if len(self.wakes) >= self.per_hour:
            return "hourly limit"
        if all(now - self.type_last.get(t, -1e18) < self.per_type_s for t in self.pending):
            return "type cooldown"
        return None

    def flush(self, now: float) -> dict[str, dict] | None:
        if self.blocked(now):
            return None
        out, self.pending, self.first, self.last = self.pending, {}, None, None
        self.wakes.append(now)
        for t in out:
            self.type_last[t] = now
        return out

    def to_json(self) -> dict:
        return {"pending": self.pending, "first": self.first, "last": self.last, "type_last": self.type_last,
                "wakes": self.wakes}

    def load(self, d: dict) -> None:
        if isinstance(d, dict):
            self.pending = d.get("pending") or {}
            self.first, self.last = d.get("first"), d.get("last")
            self.type_last = d.get("type_last") or {}
            self.wakes = d.get("wakes") or []


def _prio(t: str) -> int:
    return PRIO.index(t) if t in PRIO else len(PRIO)


def wake_line(burst: dict[str, dict], state: dict | None, held_s: float = 0) -> str:
    """'WAKE y3 sum d20 PEACE | SIEGE_END: msg | GATE_FAIL x2: msg | next: ...' within WAKE_TOKENS."""
    t = (state or {}).get("t") or {}
    when = fmt_tick(t.get("abs", t["y"] * schema.TICKS["YEAR"] + t["tick"])) if t else "?"
    head = f"WAKE {when} {(state or {}).get('mode', '?')}"
    types = sorted(burst, key=_prio)
    ns = [p["n0"] for p in burst.values() if isinstance(p.get("n0"), int)]
    hint = NEXT.get(types[0], "dfllm brief")
    tail = f" | next: {hint}" + (f"; dfllm events --cls A --since {min(ns) - 1}" if ns else "")
    room = WAKE_TOKENS - est_tokens(head + tail) - 4
    items, used = [], 0
    for i, ty in enumerate(types):
        p = burst[ty]
        e = p["e"]
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        bridge = d.get("bridge") or d.get("module") or ""
        item = f"{ty}{' x%d' % p['c'] if p['c'] > 1 else ''}{' ' + bridge if bridge else ''}: {e.get('msg', '')}"
        left = len(types) - i - 1
        budget = max(8, (room - used) // (left + 1) if left else room - used)
        item = clip(item, budget)
        cost = est_tokens(" | " + item)
        if used + cost > room:
            items.append(f"+{len(types) - i} more")
            break
        items.append(item)
        used += cost
    line = " | ".join([head] + items) + tail
    return clip(line, WAKE_TOKENS)


class Follower:
    """One poll per call; state persisted in <save>/.follow.json (Python-private)."""

    def __init__(self, save: str | None = None, out: Callable[[str], None] | None = None,
                 clock: Callable[[], float] = time.time, since: int | None = None, auto: bool = True,
                 gate: WakeGate | None = None):
        self.pinned, self.out, self.clock, self.since, self.auto = save, out or self._print, clock, since, auto
        self.gate = gate or WakeGate()
        self.dir: Path | None = None
        self.tail: files.EventTail | None = None
        self.jobs: dict = {}                   # auto actions in flight: audits, tombs, replies (cmd id -> what)
        self.hb_woken = False
        self._saved = ""
        self._pruned = 0.0

    @staticmethod
    def _print(line: str) -> None:
        print(line, flush=True)

    # ------------------------------------------------------------ persistence
    def _state_path(self) -> Path:
        return self.dir / ".follow.json"

    def _attach(self, d: Path) -> None:
        if self.dir is not None:
            self.save_state()
        self.dir, self.jobs, self.hb_woken, self._saved = d, {}, False, ""
        st = files.read_json(self._state_path())
        since = self.since
        if isinstance(st, dict) and st.get("v") == 2:
            try:
                self.gate.load(st.get("gate") or {})
                self.jobs = self._fresh_jobs(st.get("jobs") if isinstance(st.get("jobs"), dict) else {})
                self.hb_woken = bool(st.get("hb_woken"))
            except Exception as e:             # noqa: BLE001 - a corrupt .follow.json must not block attaching
                self.gate.__init__(self.gate.per_type_s, self.gate.merge_s, self.gate.quiet_s, self.gate.per_hour)
                self.jobs = {}
                files.log_cli(d, "follow", "resume", {}, f"ignored bad .follow.json: {type(e).__name__}: {e}")
            if since is None and isinstance(st.get("last_n"), int) and not isinstance(st.get("last_n"), bool):
                since = st["last_n"]
        self.tail = files.EventTail(d, since)
        self.since = None
        self._pruned = 0.0
        files.prune_snaps(d)

    def _fresh_jobs(self, jobs: dict) -> dict:
        """Drop auto jobs a previous follow process left unfinished (their replies are gone); keep cooldowns."""
        now, out = self.clock(), {}

        def fresh(j):
            return isinstance(j, dict) and now - (j.get("since") or 0) <= AUTO_TIMEOUT_S
        for key in ("audits", "replies"):
            group = jobs.get(key) if isinstance(jobs.get(key), dict) else {}
            kept = {k: j for k, j in group.items() if fresh(j)}
            if kept:
                out[key] = kept
        t = jobs.get("tombs")
        if isinstance(t, dict) and (t.get("placed") or fresh(t)):
            out["tombs"] = t
        if out != jobs:
            files.log_cli(self.dir, "follow", "resume", {}, f"dropped stale jobs {sorted(jobs)}")
        return out

    def save_state(self) -> None:
        if self.dir is None or self.tail is None:
            return
        doc = {"v": 2, "last_n": self.tail.last_n, "gate": self.gate.to_json(), "jobs": self.jobs,
               "hb_woken": self.hb_woken}
        text = files.dumps(doc)
        if text == self._saved:
            return                             # unchanged: no disk write every second
        try:
            files.write_json_atomic(self._state_path(), doc)
            self._saved = text
        except OSError as e:
            sys.stderr.write(f"follow: cannot save state: {e}\n")

    def _resolve(self) -> Path | None:
        name = self.pinned or paths.active_save()
        if name is None:
            return self.dir                    # DF closed: keep the last save
        d = paths.runtime_root() / name
        return d if d.is_dir() else self.dir

    # ------------------------------------------------------------ poll
    def poll(self) -> list[str]:
        now = self.clock()
        d = self._resolve()
        if d is None:
            return []
        if d != self.dir:
            self._attach(d)
        printed: list[str] = []
        for e in self.tail.poll():
            self._on_event(e, now)
        self._check_heartbeat(now)
        if self.auto:
            self._run_jobs(now)
        if now - self._pruned >= PRUNE_EVERY_S:
            self._pruned = now
            files.prune_outbox(self.dir)
        burst = self.gate.flush(now)
        if burst:
            line = wake_line(burst, files.read_state(self.dir))
            self.out(line)
            printed.append(line)
            files.log_cli(self.dir, "follow", "wake", sorted(burst), line)
        self.save_state()
        return printed

    def _on_event(self, e: dict, now: float) -> None:
        t, d = e.get("type"), e.get("d")
        d = d if isinstance(d, dict) else {}
        if t in WAKE_TYPES and e.get("cls") == "A":
            self.gate.add(e, now)
        if not self.auto:
            return
        try:                                   # one bad event must not lose the rest of the batch
            if t == "SNAPSHOT_READY":
                self._on_snapshot(d, now)
            elif t == "PROJECT_REQUEST" and d.get("tpl") == "tombs":
                self._request_tombs(d, now)
        except Exception as ex:                # noqa: BLE001 - surfaces as one AUTO_FAIL wake
            self._fail(f"event #{e.get('n')} {t}", f"{type(ex).__name__}: {ex}", now)

    def _synth(self, etype: str, msg: str, now: float) -> None:
        self.gate.add({"n": None, "type": etype, "cls": "A", "msg": msg[:200], "d": {}}, now)
        files.log_cli(self.dir, "follow", etype, {}, msg)

    def _check_heartbeat(self, now: float) -> None:
        if paths.active_save() != self.dir.name:
            self.hb_woken = False              # DF closed normally (ACTIVE deleted) or another save
            return
        _, age = files.read_heartbeat(self.dir, now)
        if age is not None and age > HB_STALE_S:
            if not self.hb_woken:
                self.hb_woken = True
                self._synth("HB_STALE", f"heartbeat {int(age)}s old, ACTIVE={self.dir.name}", now)
        elif age is not None:
            self.hb_woken = False

    # ------------------------------------------------------------ auto actions (no LLM)
    def _send(self, verb: str, args: dict, what: str | None, now: float, snap: dict | None = None) -> str:
        """Send without waiting; with `what`, the reply is read in _run_jobs (refusal/timeout -> AUTO_FAIL)."""
        from .cmd import send
        cid, _ = send(self.dir, verb, args, by="follow", wait_s=0, snap=snap)
        if what:
            self.jobs.setdefault("replies", {})[cid] = {"verb": verb, "what": what, "since": now,
                                                        "tpl": args.get("tpl")}
        return cid

    def _fail(self, what: str, err, now: float) -> None:
        self._synth("AUTO_FAIL", f"{what}: {err}", now)

    def _on_snapshot(self, d: dict, now: float) -> None:
        sid, rel, purpose = d.get("id"), d.get("path"), d.get("purpose")
        tombs = self.jobs.get("tombs")
        if tombs and sid and tombs.get("snap") == sid:
            tombs.update(path=rel or f"snap/{sid}.json", ready=now)
        elif purpose == "audit" and sid and rel:
            try:
                cid = self._send("inspect", {"what": "manifest"}, None, now)    # reply read by the audits job
            except Exception as e:             # noqa: BLE001
                return self._fail(f"audit {sid}", e, now)
            self.jobs.setdefault("audits", {})[sid] = {"path": rel, "inspect": cid, "since": now}

    def _request_tombs(self, d: dict, now: float) -> None:
        job = self.jobs.get("tombs")
        if job and now - job.get("since", 0) < (AUTO_TIMEOUT_S if not job.get("placed") else TOMBS_COOLDOWN_S):
            return
        params = {"n": d["n"]} if isinstance(d.get("n"), int) and not isinstance(d.get("n"), bool) else {}
        try:
            cid = self._send("snapshot", {"purpose": "sites"}, "tombs snapshot", now)
        except Exception as e:                 # noqa: BLE001
            return self._fail("tombs snapshot", e, now)
        self.jobs["tombs"] = {"snap": cid, "since": now, "params": params}

    def _run_jobs(self, now: float) -> None:
        self._read_replies(now)
        for sid, job in list((self.jobs.get("audits") or {}).items()):
            reply = files.read_outbox(self.dir, job["inspect"])
            if reply is None:
                if now - job["since"] > AUTO_TIMEOUT_S:
                    del self.jobs["audits"][sid]
                    self._fail(f"audit {sid}", "no manifest reply", now)
                continue
            del self.jobs["audits"][sid]
            self._audit(sid, job["path"], reply, now)
        tombs = self.jobs.get("tombs")
        if tombs and not tombs.get("placed"):
            if tombs.get("ready"):
                self._place_tombs(tombs, now)
            elif now - tombs["since"] > AUTO_TIMEOUT_S:
                del self.jobs["tombs"]
                self._fail("tombs", "no sites snapshot", now)

    def _read_replies(self, now: float) -> None:
        """Outbox replies of auto commands: ok -> done; ok:false or none in time -> AUTO_FAIL."""
        replies = self.jobs.get("replies") or {}
        for cid, r in list(replies.items()):
            reply = files.read_outbox(self.dir, cid)
            if reply is None and now - r.get("since", 0) <= AUTO_TIMEOUT_S:
                continue
            del replies[cid]
            tombs = self.jobs.get("tombs")
            mine = tombs is not None and cid in (tombs.get("snap"), tombs.get("placed"))
            if reply is None:
                if mine and r["verb"] == "snapshot":
                    del self.jobs["tombs"]     # no second 'no sites snapshot' fail for the same cause
                self._fail(r["what"], f"no reply to {r['verb']} {cid} within {AUTO_TIMEOUT_S}s", now)
                continue
            files.log_cli(self.dir, "follow", f"reply:{r['verb']}", {"id": cid},
                          ("ok " if reply.get("ok") else "ERR ") + str(reply.get("msg", "")))
            if reply.get("ok"):
                continue
            if r["verb"] == "bp.place" and r.get("tpl"):
                from .cmd import unplace
                unplace(self.dir, cid, r["tpl"], (tombs or {}).get("prev") if mine else None)
            if mine:
                del self.jobs["tombs"]         # a later PROJECT_REQUEST may try again
            self._fail(r["what"], f"{r['verb']} {cid} refused: {reply.get('msg', '')}", now)
        if not replies:
            self.jobs.pop("replies", None)

    def _audit(self, sid: str, rel: str, reply: dict, now: float) -> None:
        if not reply.get("ok"):
            return self._fail(f"audit {sid}", f"inspect manifest refused: {reply.get('msg', '')}", now)
        data = reply.get("data")
        manifest = data.get("manifest", data) if isinstance(data, dict) else None
        if isinstance(manifest, dict) and manifest.get("trunc"):
            # kern.lua reply(): an inspect `data` > 8 KB is replaced by {trunc, bytes}; never audit that
            return self._fail(f"audit {sid}", f"manifest truncated by kern ({manifest.get('bytes', '?')} bytes "
                                              "> 8 KB inspect limit); audit not sent", now)
        errs = schema.validate("manifest", manifest) if isinstance(manifest, dict) else ["not an object"]
        if errs:
            return self._fail(f"audit {sid}", f"manifest invalid ({errs[0]}); audit not sent", now)
        from .cmd import cache_manifest
        cache_manifest(self.dir, manifest)     # site ranking (cmd.fort_manifest) starts from the kern manifest
        snap = files.read_snapshot(self.dir / rel)
        if snap is None:
            return self._fail(f"audit {sid}", f"snapshot {rel} missing/invalid", now)
        try:
            from .cmd import load_bp
            res = load_bp("topo").audit(snap, manifest)
            args = audit_args(sid, res)
            self._send("audit", args, f"audit {sid}", now)
        except Exception as e:                 # noqa: BLE001 - any audit failure must surface as one wake
            return self._fail(f"audit {sid}", f"{type(e).__name__}: {e}", now)
        files.log_cli(self.dir, "follow", "auto:audit", {"snap": sid}, f"ok={args['ok']} traps={args['min_traps']}")
        files.prune_snaps(self.dir)

    def _place_tombs(self, job: dict, now: float) -> None:
        from .cmd import BpError, _placed
        try:
            snap = files.read_snapshot(self.dir / str(job["path"]))
            if snap is None:
                raise BpError(f"snapshot {job['path']} missing/invalid")
            args = {"tpl": "tombs", "site": "S1"}          # S1 = best free site on this snapshot
            if job.get("params"):
                args["p"] = job["params"]
            prev = files.read_json(_placed(self.dir, "tombs"))
            cid = self._send("bp.place", args, "tombs", now, snap=snap)
        except Exception as e:                 # noqa: BLE001 - WP3 bugs included: one AUTO_FAIL, job dropped
            self.jobs.pop("tombs", None)
            return self._fail("tombs", e, now)
        job.update(placed=cid, since=now, prev=prev if isinstance(prev, dict) else None)
        files.log_cli(self.dir, "follow", "auto:tombs", args, f"placed {cid}")


def audit_args(sid: str, res: dict) -> dict:
    """bp.topo.audit result -> `audit` verb args (types coerced, lists clipped to the schema limits)."""
    fails = [str(f).encode("utf-8")[:80].decode("utf-8", "ignore") for f in (res.get("fails") or [])][:50]
    return {"snap": sid, "ok": bool(res.get("ok")), "fails": fails, "min_traps": max(0, int(res.get("min_traps") or 0)),
            "bypass": bool(res.get("bypass")), "refuge_sep": bool(res.get("refuge_sep")),
            "civ_sep": bool(res.get("civ_sep")), "caverns": bool(res.get("caverns"))}


def run(args) -> int:
    f = Follower(save=args.save_pin, since=args.since, auto=not args.no_auto)
    t0, errors, last_err = time.monotonic(), 0, -1e18
    try:
        while True:
            try:
                f.poll()
                errors = 0
            except Exception as e:             # noqa: BLE001 - never die: the Monitor would go blind
                errors += 1
                now = time.monotonic()
                if now - last_err >= ERR_EVERY_S:      # a persistent error must not flood the Monitor
                    last_err = now
                    sys.stderr.write(f"follow: poll error {errors}: {type(e).__name__}: {e}\n")
                try:
                    files.log_cli(f.dir, "follow", "error", {}, f"{type(e).__name__}: {e}")
                except Exception:              # noqa: BLE001
                    pass
            if args.once or (args.max_s and time.monotonic() - t0 >= args.max_s):
                return 0
            time.sleep(args.interval)
    except KeyboardInterrupt:
        return 0
    finally:
        f.save_state()


def add_parser(sub) -> None:
    p = sub.add_parser("follow", help="Monitor target: one wake line per allowed class-A burst")
    p.add_argument("--since", type=int, help="replay events with n > N (default: resume / start at the end)")
    p.add_argument("--interval", type=float, default=1.0)
    p.add_argument("--once", action="store_true", help="poll once and exit")
    p.add_argument("--max-s", type=float, default=0, help="exit after N seconds")
    p.add_argument("--no-auto", action="store_true", help="no automatic audit / tombs placement")
