"""Spec 02: caravan autopilot (`python -m df_llm_helper caravan`).

Builds on the trade automaton (F15, trade_flow.py) and adds:
  * trade/skip decision based on the wish list (data/trade/wants.yaml) and the real offer
    (`claude/handel list 0`, format 'idx|TYPE|vVALUE|nQTY|flags|name').
  * Live selection is approved only if the dry run (`claude/handel select --dry`) buys a must-have good and the
    ratio is >= min_ratio; otherwise a message goes to the orchestrator (no silent decision).
  * Skip: close the window, free the broker, remove caravan.flag + pause.hold, keep playing (no more 23-minute pause).
  * Stuck caravan (Leaving, time_remaining 0 for longer than stuck_ticks game ticks): send the merchants home
    (`claude/pilot_caravan release`, sets flags1.left only for merchants/caravan animals) - ONLY with an FP09 entry in the
    exception register (the player's standing permission, record it verbatim).
Deviation from the spec: a quicksave cannot be loaded without the title menu; "rollback" = clean abort
(abort/finish/release/advance run) + a pointer to the quicksave (loading via spec 09 or the player).
"""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from pathlib import Path

from . import yamlmini
from .holds import danger_reason, release_hold, run_helper
from .trade_flow import TERMINAL, TradeFlow, obs_from_status

__all__ = ["Good", "parse_list", "load_wants", "boost_wants", "classify", "decide", "dry_ok", "CaravanPilot", "DEFAULTS",
           "approve_review", "status_line"]

DEFAULTS = {"min_ratio": 2.0, "skip_if_offer_empty": True, "stuck_ticks": 2000, "release_stuck": True,
            "wants_file": "data/trade/wants.yaml", "max_steps": 40}
_LINE = re.compile(r"^(\d+)\|([A-Z_]+)\|v(\d+)\|n(\d+)\|([^|]*)\|(.*)$")


@dataclass(frozen=True)
class Good:
    idx: int
    type: str
    value: int
    qty: int
    name: str
    category: str = "other"


def load_wants(path: Path) -> list[dict]:
    data = yamlmini.load_file(path) or []
    for w in data:
        if "category" not in w:
            raise ValueError(f"{path}: entry without category: {w}")
    return data


def boost_wants(wants: list[dict], boost: list | None) -> list[dict]:
    """kv 'trade.boost' (e.g. from the mood manager: ['wood']) -> these categories first and as must-haves."""
    if not boost:
        return wants
    first = [dict(w, must=True) for b in boost for w in wants if w["category"] == b]
    return first + [w for w in wants if w["category"] not in boost]


def classify(type_: str, name: str, wants: list[dict]) -> str:
    low = name.lower()
    for w in wants:
        types = set(w.get("types") or [])
        words = [x.lower() for x in (w.get("words") or [])]
        if types and type_ not in types:
            continue
        if words and not any(x in low for x in words):
            continue
        if types or words:
            return w["category"]
    return "other"


def parse_list(j, wants: list[dict]) -> list[Good] | None:
    """Response of 'claude/handel list 0|1' -> goods. None = not readable (window closed?)."""
    if not isinstance(j, dict) or not isinstance(j.get("lines"), list):
        return None
    out = []
    for ln in j["lines"]:
        m = _LINE.match(str(ln))
        if not m:
            continue
        name = re.sub(r"\s*\[\d+\]$", "", m.group(6)).strip()
        out.append(Good(int(m.group(1)), m.group(2), int(m.group(3)), int(m.group(4)), name,
                        classify(m.group(2), name, wants)))
    return out


def decide(offer: list[Good] | None, wants: list[dict], *, skip_if_empty: bool = True) -> tuple[str, dict]:
    """-> ('trade'|'skip'|'unknown', must-have goods {category: quantity})."""
    if offer is None:
        return "unknown", {}
    musts = {w["category"] for w in wants if w.get("must")}
    found: dict = {}
    for g in offer:
        if g.category in musts:
            found[g.category] = found.get(g.category, 0) + g.qty
    if not found and skip_if_empty:
        return "skip", {}
    return "trade", dict(sorted(found.items(), key=lambda kv: [w["category"] for w in wants].index(kv[0])))


def dry_ok(sel, offer: list[Good], wants: list[dict], min_ratio: float) -> tuple[bool, str]:
    """Check the dry run of 'select --dry': ratio and at least one must-have good in the purchase."""
    if not isinstance(sel, dict):
        return False, "Dry run not readable"
    if sel.get("ok") is False:
        return False, f"Dry run aborted: {sel.get('abort', '?')}"
    ratio = (sel.get("ratio_x100") or 0) / 100.0
    if ratio < min_ratio:
        return False, f"Ratio {ratio:.2f} < {min_ratio}"
    musts = {w["category"] for w in wants if w.get("must")}
    by_idx = {g.idx: g for g in offer}
    bought = set()
    for b in sel.get("buy_top") or []:
        g = by_idx.get(b.get("i"))
        cat = g.category if g else classify("?", str(b.get("d", "")), wants)
        if cat in musts:
            bought.add(cat)
    for s in sel.get("buy_all") or []:                     # "idx:name:vValue"
        m = re.match(r"^(\d+):", str(s))
        g = by_idx.get(int(m.group(1))) if m else None
        if g and g.category in musts:
            bought.add(g.category)
    if not bought:
        return False, "Selection buys no must-have good (adjust handel-regeln.md?)"
    return True, "Must-have goods: " + ", ".join(sorted(bought)) + f"; ratio {ratio:.2f}"


@dataclass
class CaravanState:
    flow: dict = field(default_factory=dict)
    decision: str = ""
    musts: dict = field(default_factory=dict)
    stuck_since_tick: int | None = None
    released: bool = False
    report: list = field(default_factory=list)


class CaravanPilot:
    """One cycle = one observation + commands. State in state.db (kv 'caravan.state')."""

    def __init__(self, client, tools, store, clock, cfg: dict, home: Path, registry=None):
        self.client, self.tools, self.store, self.clock = client, tools, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}
        boost = list(dict.fromkeys(list(store.get("trade.boost") or []) + list(store.get("trade.boost_bottleneck") or [])))
        self.wants = boost_wants(load_wants(home / self.cfg["wants_file"]), boost)   # Spec 03 + Spec 07
        self.registry = registry
        self._dry = False
        self._last: CaravanState | None = None

    def _load(self) -> CaravanState:
        d = self.store.get("caravan.state") or {}
        return CaravanState(**{k: v for k, v in d.items() if k in CaravanState.__dataclass_fields__})

    def _save(self, st: CaravanState) -> None:
        self._last = st                       # report() of this run, also for a dry run
        if not self._dry:                     # a dry run must not move the persistent state machine (approval, SAVE skipped...)
            self.store.set("caravan.state", asdict(st))

    def _run(self, cmd: str, dry: bool, log: list) -> object:
        if dry:
            log.append("[dry] " + cmd)
            return None
        if cmd.startswith("HELPER "):              # BUG-223: the trade's pause.hold, executed locally
            ok, txt = run_helper(cmd, self.tools)
            log.append(("ok " if ok else "ERROR ") + cmd + f" ({txt})")
            return None
        r = self.client.run(cmd)
        self.store.log_action(self.clock.now().epoch, "caravan", "caravan", cmd.split(" ")[0], "caravan", cmd, False,
                              r.ok, "")
        log.append(("ok " if r.ok else "ERROR ") + cmd)
        return r

    def _resume(self, st: CaravanState, dry: bool, log: list, why: str, *, run: bool = True) -> None:
        if not dry:
            self.tools.delete_flag("caravan")
            release_hold(self.tools)              # never an alarm/gefahr hold (BUG-223/224)
        if run:
            self._run("claude/advance run", dry, log)
        if why not in st.report:
            st.report.append(why)

    def _warn(self, key: str, msg: str, dry: bool) -> None:
        """Warnings only in a real run: a dry run must not wake the orchestrator (BUG-203)."""
        if not dry:
            self.store.warn(self.clock.now().epoch, "caravan", key, msg, "warn")

    def _release_stuck(self, status: dict, game_tick: int | None, st: CaravanState, dry: bool, log: list) -> None:
        cars = [c for c in status.get("caravans") or [] if isinstance(c, dict)]
        stuck = [c for c in cars if c.get("state") == "Leaving" and (c.get("time_remaining") or 0) <= 0]
        if not stuck:
            st.stuck_since_tick = None
            return
        if game_tick is None:
            return
        if st.stuck_since_tick is None:
            st.stuck_since_tick = game_tick
            return
        if game_tick - st.stuck_since_tick < self.cfg["stuck_ticks"] or st.released or not self.cfg["release_stuck"]:
            return
        if self.registry is None or not self.registry.allows("FP09"):
            msg = ("Caravan is stuck (Leaving, 0 ticks): sending it home needs the player's standing permission in the register: "
                   "python -m df_llm_helper exception add FP09 --local --reason 'stuck merchants' --ja '<quote>'")
            if msg not in st.report:
                st.report.append(msg)
                self._warn("caravan:stuck", msg, dry)
            return
        r = self._run("claude/pilot_caravan release --apply", dry, log)
        st.released = True
        n = (r.json or {}).get("released") if r is not None and isinstance(r.json, dict) else "?"
        st.report.append(f"stuck merchants sent home (flags1.left, register FP09): {n} units")
        if not dry:
            p = self.tools.path / "out" / "caravan-release.log"
            p.parent.mkdir(parents=True, exist_ok=True)
            with p.open("a", encoding="utf-8") as f:
                f.write(f"{self.clock.now().iso()} released={n}\n")

    def step(self, *, dry: bool = False, game_tick: int | None = None, stable_s: float = 2.0) -> tuple[str, list]:
        st = self._load()
        self._dry = dry
        log: list[str] = []
        stat = self.client.run("claude/handel status")
        j = stat.json if isinstance(stat.json, dict) else {}
        self._release_stuck(j, game_tick, st, dry, log)
        cars = [c for c in j.get("caravans") or [] if isinstance(c, dict)]
        at_depot = any(c.get("state") == "AtDepot" for c in cars)
        flow = TradeFlow(**st.flow) if st.flow else TradeFlow()
        before = flow.state

        # orphaned flags without an active caravan (rule stale_caravan_flag covers legacy leftovers; here right after departure)
        if not cars and flow.state in ("IDLE", "DONE", "ABORT", "FAILED"):
            if self.tools.flag("caravan").exists and (self.tools.flag("caravan").age_min or 0) > 5 and not dry:
                self.tools.delete_flag("caravan")
                release_hold(self.tools)
                log.append("orphaned caravan.flag deleted")
            if flow.state in ("DONE", "ABORT", "FAILED"):
                st = CaravanState()
            self._save(st)
            return "idle", log
        if flow.state == "IDLE" and not at_depot:
            self._save(st)
            return "waiting", log
        danger = danger_reason(self.tools, self.cfg.get("holds"))
        for e in (j.get("errors") or [])[:3]:          # BUG-226: runtime folder / stability mark / rules file
            self._warn("caravan:lua", f"claude/handel: {e}", dry)
            log.append(f"!! claude/handel: {e}")
        reenter = flow.state == "ABORT" and flow.can_reenter(obs_from_status(j, danger=danger))
        if flow.state in TERMINAL and not reenter:
            # BUG-200: this caravan is finished (it stays on the map for days): no commands, no flag deletions
            self._save(st)
            return flow.state.lower(), log

        # decision as soon as the offer is readable (trade window open)
        if flow.state in ("REVIEW", "SELECT_DRY") and st.decision in ("", "unknown"):
            lst = self.client.run("claude/handel list 0")
            offer = parse_list(lst.json, self.wants)
            st.decision, st.musts = decide(offer, self.wants, skip_if_empty=self.cfg["skip_if_offer_empty"])
            if st.decision == "skip":
                for c in ["claude/handel abort --live", "claude/handel finish --live", "claude/handel release --live"]:
                    self._run(c, dry, log)
                self._resume(st, dry, log, "Caravan without must-have goods: no trade, kept playing")
                flow.state = "DONE"
                st.flow = asdict(flow)
                self._save(st)
                return "skip", log
            st.report.append("Must-have goods in offer: " + ", ".join(f"{k} {v}" for k, v in st.musts.items()))
        if flow.state == "REVIEW" and not flow.approved:
            sel = self.client.run("claude/handel select --dry")
            lst = self.client.run("claude/handel list 0")
            offer = parse_list(lst.json, self.wants) or []
            ok, why = dry_ok(sel.json, offer, self.wants, self.cfg["min_ratio"])
            line = ("approved: " if ok else "NOT approved: ") + why
            if line not in st.report:                              # BUG-201: no pile-up of the same line per call
                st.report.append(line)
            if ok:
                flow.approve()
            else:
                hint = (" -> approve by hand: python -m df_llm_helper trade approve (or caravan reset / adjust "
                        "tools/scopes/handel-regeln.md)")
                if not any(r.startswith("Waiting for approval") for r in st.report):
                    st.report.append("Waiting for approval" + hint)
                self._warn("caravan:review", "Trade waits for the orchestrator: " + why + hint, dry)

        clock = self.client.run("claude/advance clock")
        paused = bool((clock.json or {}).get("paused")) if isinstance(clock.json, dict) else False
        obs = obs_from_status(j, paused=paused, stable_s=stable_s, last_ok=stat.ok, danger=danger)
        for c in flow.step(obs, self.clock.now().epoch):
            r = self._run(c, dry, log)
            if c.startswith("claude/handel open") and r is not None:     # BUG-225: raw answer for the abort text
                jr = r.json if isinstance(r.json, dict) else {}
                flow.last_answer = str(jr.get("abort") or jr.get("step") or (r.stdout or "").strip()[:120])[:160]
        if flow.note and flow.note not in st.report:
            st.report = [x for x in st.report if not x.startswith("blocked: ")] + [flow.note]
        if flow.state == "DONE" and before != "DONE":
            # only on the transition; 'advance run' was already sent by the automaton (RELEASE -> RESUME) (BUG-200)
            sent = any(x.startswith(("RELEASE -> RESUME", "RESUME -> DONE")) for x in flow.log)
            self._resume(st, dry, log, "Trade completed", run=not sent)
        elif flow.state in ("ABORT", "FAILED"):
            st.report.append(f"Trade aborted ({flow.abort_reason}); quicksave from the start of the trade available "
                             f"(load only via the title menu/the player)")
            if not dry:
                release_hold(self.tools)          # the trade's own hold only; an alarm hold stays (BUG-224/225)
        st.flow = asdict(flow)
        self._save(st)
        return flow.state.lower(), log

    def report(self) -> list[str]:
        st = self._last or self._load()
        flow = TradeFlow(**st.flow) if st.flow else TradeFlow()
        lines = [f"Caravan: {flow.state}" + (f" ({st.decision})" if st.decision else "")] + st.report
        return lines[:8]


def status_line(store) -> str:
    """One line about the caravan autopilot's trade (shown by `trade status`, BUG-201)."""
    st = store.get("caravan.state") or {}
    flow = st.get("flow") or {}
    if not flow:
        return "Caravan autopilot: no trade"
    return (f"Caravan autopilot: {flow.get('state', 'IDLE')}" + (f" ({st.get('decision')})" if st.get("decision") else "")
            + f"; approved: {bool(flow.get('approved'))}")


def approve_review(store) -> tuple[bool, str]:
    """`trade approve` (BUG-201): approve the live selection of the trade that waits in REVIEW - the caravan autopilot's
    (kv caravan.state) and/or the manual automaton (kv trade.flow). Refused when nothing waits for an approval, so a
    stale approval can never skip the review of a later trade."""
    done = []
    st = store.get("caravan.state") or {}
    if (st.get("flow") or {}).get("state") in ("REVIEW", "WAIT"):
        st["flow"]["approved"] = True
        store.set("caravan.state", st)
        done.append("caravan")
    tf = store.get("trade.flow") or {}
    if tf.get("state") in ("REVIEW", "WAIT"):
        tf["approved"] = True
        store.set("trade.flow", tf)
        done.append("trade")
    if not done:
        states = f"caravan {(st.get('flow') or {}).get('state', 'IDLE')}, trade {tf.get('state', 'IDLE')}"
        return False, f"Refused: no trade waits for an approval (state {states}); approve only in REVIEW/WAIT"
    return True, ("Live selection approved (REVIEW/WAIT: " + ", ".join(done) + ") - next: "
                  + ("python -m df_llm_helper caravan --loop" if "caravan" in done else "python -m df_llm_helper trade step"))
