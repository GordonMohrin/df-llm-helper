"""Command line: python -m df_llm_helper <command> ...  (concise English output)."""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

from .client import DFClient, MockClient, RealClient, RecordingClient, ReplayClient
from .clock import SystemClock
from .config import HOME, Config, force_overrides, load_config, mock_overrides
from .fairplay import ExceptionRegistry, FairPlayError
from .store import Store


def _client(args, cfg: Config, clock) -> DFClient:
    reg = ExceptionRegistry(cfg.path("exceptions"))
    if getattr(args, "mock", None):
        c: DFClient = MockClient.from_fixture_dir(args.mock, registry=reg, clock=clock)
        from .client import MAX_REPORT_ID_CMD
        c.set(MAX_REPORT_ID_CMD, c.responses.get(MAX_REPORT_ID_CMD, "-1"))
    elif getattr(args, "replay_file", None):
        c = ReplayClient.from_file(args.replay_file, registry=reg, clock=clock)
    else:
        lint = None
        try:
            from .lint import gate_command
            lint = gate_command(reg, cfg.get("water.forbid_dig"))
        except ImportError:
            pass
        c = RealClient(cfg.get("dfhack_run"), registry=reg, clock=clock, lint=lint)
        if cfg.get("transport.batch", False):
            from .transport import BatchingClient
            c = BatchingClient(c, Path(cfg.get("paths.tools")) / "out", max_bytes=int(cfg.get("transport.max_bytes", 20000)))
    if getattr(args, "record", None):
        c = RecordingClient(c, args.record)
    return c


def _pilot(args):
    from .pilot import Pilot
    cfg = load_config(args.config)
    clock = SystemClock()
    client = _client(args, cfg, clock)
    probe = None
    if not getattr(args, "mock", None) and not getattr(args, "replay_file", None):
        from .guard import ProcessProbe
        probe = ProcessProbe(cfg.get("guard.guard_process", "df_llm_helper waechter"))
    return Pilot(cfg, client, clock=clock, probe=probe)


def _usage(pilot, scope: str, command: str, out: str, t0: float) -> None:
    from .metrics import record_usage
    record_usage(pilot.store, time.time(), scope, command, time.time() - t0, sum(len(c) for c in pilot.client.calls), out)


def _check_scope(scope: str | None) -> None:
    """BUG-117 F: an unknown --scope is an error (it used to report 'No change')."""
    if scope is None:
        return
    from .brief import SCOPES
    known = [*SCOPES, "orchestrator"]
    if scope not in known:
        raise ValueError(f"unknown scope '{scope}' (known: {', '.join(known)})")


def cmd_digest(args) -> int:
    _check_scope(args.scope)
    p = _pilot(args)
    t0 = time.time()
    out = p.digest(scope=args.scope, since_last=not args.full)
    print(out)
    _usage(p, args.scope or "orchestrator", "digest", out, t0)
    return 0


def cmd_cycle(args) -> int:
    p = _pilot(args)
    t0 = time.time()
    rep = p.cycle(dry_run=args.dry_run)
    lines = [rep.digest]
    acts = [a.line() for a in rep.actions] + [f"guard: {g.line()}" for g in rep.guard if g.kind != "info"]
    if acts:
        lines.append("Actions: " + " | ".join(acts)[:600])
    out = "\n".join(lines)
    print(out)
    _usage(p, "orchestrator", "cycle", out, t0)
    return 0


HOOK_REPEAT_MIN = 120          # an unchanged feature line is repeated at most every 2 h


def _fresh_hook_lines(p, key: str, lines: list[str], *, record: bool = True) -> list[str]:
    """Feature hooks (hygiene, reach, tools, ...) print their standing findings on every check - 5-7 identical lines
    (~150 tokens) after a 'No change'. Report a line when its text changed (numbers are ignored) or after
    HOOK_REPEAT_MIN minutes; a dry run reads the memory but never writes it."""
    import re as _re
    now = p.clock.now().epoch
    kv = f"check.hooks.{key}"
    seen = dict(p.store.get(kv) or {})
    out, cur = [], {}
    for ln in lines:
        sig = _re.sub(r"\d+(?:[.,]\d+)?k?", "#", ln)[:120]
        last = seen.get(sig)
        if last is None or now - last >= HOOK_REPEAT_MIN * 60:
            out.append(ln)
            cur[sig] = now
        else:
            cur[sig] = last
    if record:
        p.store.set(kv, cur)
    return out


def cmd_check(args) -> int:
    """Orchestrator check in one call: heartbeat + guard + autopilot + digest (incl. bus)."""
    p = _pilot(args)
    t0 = time.time()
    p.heartbeat()
    rep = p.cycle(dry_run=args.dry_run)
    lines = [rep.digest]
    acts = [a.line() for a in rep.actions if a.kind != "verify"]
    acts += [f"guard {g.kind}={g.value}" for g in rep.guard if g.kind in ("set_fps", "tempo_off", "reset_report_id")]
    if acts:
        lines.append("Autopilot: " + " | ".join(acts)[:400])
    try:                                                     # Spec 05: time series per check, line only on a warning
        from .forecast import Forecaster
        fline, news = Forecaster(p.store, p.clock, p.cfg.get("forecast", {})).update(rep.snapshot,
                                                                                   record=not args.dry_run)
        lines += news
    except Exception as e:                                   # the forecast must never break the check
        lines.append(f"Forecast error: {e}"[:120])
    if p.cfg.get("reboot.auto_in_check", True):              # Spec 09: save reloaded -> start services
        try:
            from .reboot import Reboot
            rb = Reboot(p.client, p.store, p.clock, p.cfg.get("reboot", {}), HOME)
            if rb.detect_loaded(None, rep.snapshot.max_report_id):
                lines += [ln for ln in rb.run(dry=args.dry_run) if not ln.startswith(("ok ", "[dry]"))]
        except Exception as e:
            lines.append(f"Reboot error: {e}"[:120])
    if p.cfg.get("dashboard.in_check", True):                # Spec 11: new page, only if values change
        try:
            from .dashboard import collect as dcollect, render as drender, write_if_changed
            dcfg = p.cfg.get("dashboard", {})
            if not args.dry_run:
                write_if_changed(drender(dcollect(p.store, p.clock.now().epoch, dcfg), dcfg),
                                 Path(p.cfg.get("paths.tools")) / dcfg.get("out", "out/dashboard.html"), p.store)
        except Exception as e:
            lines.append(f"Dashboard error: {e}"[:120])
    if p.cfg.get("water.watch_in_check", True):              # Spec 08: water in the fort, lines only on alarm
        try:
            from .water import WaterWatch
            wl = WaterWatch(p.client, p.tools, p.store, p.clock, p.cfg.get("water", {})).watch(dry=args.dry_run)
            lines += [ln for ln in wl if ln.startswith(("!!", "Emergency wall", "Water in the fort back to 0"))]
        except Exception as e:
            lines.append(f"Water error: {e}"[:120])
    from .features import modules as _features        # v3 feature plug-ins (df_llm_helper/features/)
    for mod in _features():
        hook = getattr(mod, "check_hook", None)
        if hook is None or not p.cfg.get(f"{mod.KEY}.in_check", True):
            continue
        try:
            lines += _fresh_hook_lines(p, mod.KEY, [ln for ln in (hook(p, rep, args.dry_run) or []) if ln],
                                       record=not args.dry_run)
        except Exception as e:                             # a feature must never break the check
            lines.append(f"{mod.KEY} error: {e}"[:120])
    out = "\n".join(lines)
    print(out)
    _usage(p, "orchestrator", "check", out, t0)
    return 0


def cmd_autopilot(args) -> int:
    p = _pilot(args)
    if args.action == "rules":
        for r in p.rules():
            st = p.store.rule_state(r.id)
            off = " [OFF: " + str(st["reason"]) + "]" if st["disabled"] else ""
            print(f"{r.id} ({r.klass}){off}: {r.why}")
        return 0
    if args.action == "conflicts":
        from .rules import find_conflicts
        res = find_conflicts(p.rules())
        print("\n".join(res) if res else "no conflicts")
        return 1 if any(x.startswith("CONFLICT") for x in res) else 0
    if args.action == "enable":
        known = [r.id for r in p.rules()]
        if not args.rule:
            raise ValueError("autopilot enable needs a rule id (see: python -m df_llm_helper autopilot rules)")
        if args.rule not in known:
            raise ValueError(f"unknown rule '{args.rule}' (see: python -m df_llm_helper autopilot rules)")
        p.store.update_rule(args.rule, disabled=0, reason=None)
        print(f"Rule {args.rule} active again")
        return 0
    while True:
        snap = p.snapshot()
        recs = p.autopilot(snap, dry_run=args.dry_run)
        print("\n".join(r.line() for r in recs) or "no action", flush=True)
        if not args.loop:
            return 0
        time.sleep(float(args.interval))


def cmd_guard(args) -> int:
    p = _pilot(args)
    if args.action == "ack-gate":
        from .guard import GuardState
        gates = [int(g) for g in (p.cfg.get("guard.pop_gates") or [])]
        if args.gate is None:
            raise ValueError(f"guard ack-gate needs the gate number (configured pop gates: {gates})")
        if args.gate not in gates:
            raise ValueError(f"unknown pop gate {args.gate} (configured: {gates})")
        st = GuardState.from_dict(p.store.get("guard.state"))
        st.gates_acked = [g for g in st.gates_acked if isinstance(g, int)]      # drop junk of older versions
        if args.gate not in st.gates_acked:
            st.gates_acked.append(args.gate)
        p.store.set("guard.state", st.to_dict())
        print(f"Pop gate {args.gate} acknowledged")
        return 0
    while True:
        acts, st, info = p.guard(dry_run=args.dry_run)
        print("; ".join(a.line() for a in acts) or "Guard: all quiet", flush=True)
        print(f"Target fps {info['target_fps']}, time lapse allowed: {info['timestream_allowed']}"
              + (f" (blockers: {', '.join(info['blockers'])})" if info["blockers"] else ""), flush=True)
        if not args.loop:
            return 0
        time.sleep(float(args.interval))


def cmd_waechter(args) -> int:
    """Replaces tools/unpause-guard.ps1: reports -> events.log, flags, pauses, supplies, deadman (not tested live)."""
    from .waechter import Waechter
    p = _pilot(args)
    w = Waechter(p.client, p.tools, p.clock, p.store, p.cfg.data)
    interval = float(args.interval or p.cfg.get("guard.waechter_interval_s", 2))
    while True:
        try:
            for ln in w.step():
                print(ln, flush=True)
        except Exception as e:  # like ps1: never abort, report the error and carry on
            print(f"Watcher error: {type(e).__name__}: {e}", file=sys.stderr, flush=True)
            if not args.loop:
                return 1
        if not args.loop:
            return 0
        time.sleep(interval)


def cmd_tempo(args) -> int:
    """Time lapse on ONLY if the guard reports no blocker (the orchestrator may ask, the guard decides)."""
    p = _pilot(args)
    if args.action == "status":                  # display only: nothing is changed in the game
        snap = p.snapshot()
        _, _, info = p.guard(snap, dry_run=True)
        fps = f"{snap.fps:.0f}" if snap.fps is not None else "?"
        norm = f"{snap.normal_fps:.0f}" if snap.normal_fps else "?"
        ts = "unknown" if snap.timestream is None else ("ON" if snap.timestream else "off")
        run_state = "pause state unknown" if snap.paused is None else ("paused" if snap.paused else "running")
        print(f"Time lapse: {ts}, fps {fps} (normal {norm}), {run_state}")
        print("Guard: " + ("no blockers, 'tempo on' would be allowed" if not info["blockers"]
                           else "blockers: " + ", ".join(info["blockers"])))
        return 0
    if args.action == "off":
        if args.dry_run:
            print("[dry] claude/tempo off")
            return 0
        print("ok" if p.client.run("claude/tempo off").ok else "Error: claude/tempo off")
        return 0
    acts, st, info = p.guard(dry_run=True)
    if info["blockers"]:
        print("Time lapse NOT switched on, blockers: " + ", ".join(info["blockers"]))
        return 1
    if args.dry_run:
        print("[dry] claude/tempo on (no blockers)")
        return 0
    r = p.client.run("claude/tempo on")
    print("Time lapse on (claude/tempo on)" if r.ok else f"Error: {r.stderr[:100]}")
    return 0 if r.ok else 1


def cmd_heartbeat(args) -> int:
    cfg = load_config(args.config)
    from .toolsfs import ToolsDir
    ToolsDir(cfg.path("tools"), SystemClock()).touch_heartbeat()
    print("Heartbeat set")
    return 0


def cmd_wake(args) -> int:
    from .toolsfs import ToolsDir
    from .wake import wake_check
    cfg = load_config(args.config)
    clock = SystemClock()
    store = Store(cfg.path("state_db"))
    tools = ToolsDir(cfg.path("tools"), clock)
    while True:
        wake_check(tools, store, clock, emit_existing=args.emit_existing, sink=lambda ln: print(ln, flush=True))
        if not args.loop:
            return 0
        time.sleep(float(args.interval))


def _runbooks(p):
    from .runbooks import load_runbooks
    return load_runbooks(Path(p.cfg.get("paths.data")) / "runbooks")


def cmd_runbook(args) -> int:
    from .runbooks import diagnose, plan_commands, run_runbook
    p = _pilot(args)
    rbs = {r.id: r for r in _runbooks(p)}
    if args.action == "list":
        for r in rbs.values():
            print(f"{r.id}{' [player consent]' if r.needs_player_approval else ''}: {r.title}")
        return 0
    if args.action == "diagnose":
        snap = p.snapshot()
        hits = diagnose(list(rbs.values()), p.context(snap, p.cancels()))
        print("\n".join(h.line() for h in hits) or "no runbook hits")
        return 0
    if not args.id or args.id not in rbs:
        print(f"Unknown runbook: {args.id}. List: python -m df_llm_helper runbook list", file=sys.stderr)
        return 2
    rb = rbs[args.id]
    if args.action == "show":
        print(f"{rb.id}: {rb.title}\nSymptom: {rb.symptom['when']}\nKB: {', '.join(rb.kb)}"
              f"\nPlayer consent needed: {rb.needs_player_approval}")
        for i, st in enumerate(rb.steps, 1):
            print(f" {i}. " + ", ".join(f"{k}: {v}" for k, v in st.items()))
        print(f"Verify: {rb.verify['when']}")
        if rb.notes:
            print("Note: " + rb.notes)
        return 0
    params = dict(kv.split("=", 1) for kv in (args.param or []))
    snapctx = lambda: p.context(p.snapshot())  # noqa: E731

    def internal(action: str) -> str:
        if action == "reset_report_id":
            snap = p.snapshot()
            if snap.max_report_id is not None:
                p.tools.set_last_report_id(snap.max_report_id)
                return f"last-report-id set to {snap.max_report_id}"
            return "max_report_id unknown - nothing changed"
        if action.startswith("delete_flag:"):
            return "Flag deleted" if p.tools.delete_flag(action.split(":", 1)[1]) else "Flag was not there"
        if action == "heartbeat":
            p.heartbeat()
            return "Heartbeat set"
        return f"unknown: {action}"
    res = run_runbook(rb, p.client, snapctx, clock=p.clock, dry_run=args.dry_run, params=params,
                      registry=p.client.registry, internal=internal)
    print(f"{rb.id}: {res.status}")
    for c in (res.commands if args.dry_run else []):
        print("  " + c)
    for ln in res.log:
        print("  " + ln)
    return 0 if res.status in ("done", "dry", "manual") else 1


def cmd_kb(args) -> int:
    from .kb import KB, format_entry, format_hits, import_markdown, write_jsonl
    cfg = load_config(args.config)
    if args.action == "import":
        for f in args.files:
            es = import_markdown(Path(f))
            target = Path(cfg.get("paths.data")) / "kb" / f"imported_{Path(f).stem.lower()}.jsonl"
            write_jsonl(es, target)
            print(f"{f}: {len(es)} entries -> {target.name} (unreviewed)")
        return 0
    kb = KB.load(cfg)
    if args.action == "search":
        print(format_hits(kb.search(" ".join(args.query), k=args.k), kb.current_run, kb.stale_before,
                          int(cfg.get("kb.max_tokens", 400))))
        return 0
    if args.action == "get":
        e = kb.get(args.query[0]) if args.query else None
        if not e:
            print("unknown ID (python -m df_llm_helper kb search ...)", file=sys.stderr)
            return 2
        print(format_entry(e, kb.current_run, kb.stale_before, int(cfg.get("kb.max_tokens", 400))))
        return 0
    for e in kb.entries:
        if args.all or e.status == "reviewed":
            print(f"{e.id}: {e.title}")
    return 0


def cmd_brief(args) -> int:
    from .brief import build_brief, load_scopes
    from .kb import KB
    p = _pilot(args)
    t0 = time.time()
    snap = p.snapshot()
    scope_file = "militaer" if args.scope == "verteidigung" else args.scope
    mem = p.tools.memory_file(scope_file)
    out = build_brief(args.scope, scopes_def=load_scopes(Path(p.cfg.get("paths.data")) / "scopes.yaml"),
                      ctx=p.context(snap, p.cancels()), snap=snap, kb=KB.load(p.cfg),
                      memory_text=mem.read_text(encoding="utf-8", errors="replace") if mem.exists() else None,
                      inbox_lines=p.tools.inbox_lines(args.scope), th=p.cfg.th,
                      budget=int(args.budget or p.cfg.get("brief.budget", 1500)),
                      date_text=snap.date.text() if snap.date else "")
    print(out)
    _usage(p, args.scope, "brief", out, t0)
    return 0


def cmd_replay(args) -> int:
    from .scenario import check_expectations, run_scenario
    files = [Path(f) for f in args.files] or sorted((HOME / "scenarios").glob("*.jsonl"))
    bad = 0
    for f in files:
        res = run_scenario(f)
        errs = check_expectations(res)
        if not res.steps:
            errs = [*errs, "scenario has no steps (empty or meta-only file)"]
        print(f"{f.stem}: {'OK' if not errs else 'FAIL'} ({len(res.steps)} steps)")
        for e in errs:
            print("   " + e)
        if args.verbose:
            for s in res.steps:
                print(f"  t={s.t} commands={s.commands} guard={s.guard_kinds} runbooks={s.diagnose}")
        bad += bool(errs)
    return 1 if bad else 0


def cmd_record(args) -> int:
    p = _pilot(args)
    if not getattr(args, "record", None):
        print("specify --record <file.jsonl>", file=sys.stderr)
        return 2
    cmds = args.commands or p.commands()
    for c in cmds:
        r = p.client.run(c)
        print(f"{'ok ' if r.ok else 'ERR'} {c[:70]} ({len(r.stdout)} B)")
    return 0


def cmd_exception(args) -> int:
    cfg = load_config(args.config)
    reg = ExceptionRegistry(cfg.path("exceptions"))
    if args.action == "add":
        objs = [o for o in (args.objects or "").split(",") if o]
        e = reg.add(args.rule, args.reason, args.ja or "", objects=objs, max_uses=args.max_uses, expires=args.expires)
        print(f"Exception registered: {e.action} {e.objects}")
        return 0
    for e in reg.entries:
        print(f"{e.ts} {e.action} {e.objects}: {e.reason} (player consent: {e.player_consent})")
    for err in reg.errors:
        print("Register error: " + err)
    return 0


def cmd_memory(args) -> int:
    from .memory import compact_file, restore
    cfg = load_config(args.config)
    scopes = Path(cfg.get("paths.scopes"))
    if args.scope in ("all", "alle"):     # memory + inbox files only; rule/registry files (handel-regeln.md, REGISTRY.md) stay
        from .brief import SCOPES
        targets = [f for f in sorted(scopes.glob("*.md"))
                   if f.stem in SCOPES or (f.stem.startswith("inbox-") and f.stem[6:] in (*SCOPES, "orchestrator"))]
    else:
        targets = [scopes / f"{args.scope}.md"]
    for p in targets:
        if not p.exists():
            print(f"{p.name}: missing", file=sys.stderr)
            return 2
        if args.action == "restore":
            a = restore(p)
            print(f"{p.name}: restored from {a.name}" if a else f"{p.name}: no archive")
            continue
        res = compact_file(p, stamp=time.strftime("%Y%m%dT%H%M%S"), dry_run=args.dry_run)
        tag = "(dry-run) " if args.dry_run else ""
        print(f"{tag}{p.name}: {res['before']} -> {res['after']} bytes" + (f", archive {Path(res['archive']).name}"
                                                                              if res.get("archive") else ""))
    return 0


def cmd_bus(args) -> int:
    from .bus import Bus
    cfg = load_config(args.config)
    clock = SystemClock()
    store = Store(cfg.path("state_db"))
    bus = Bus(store, clock)
    if args.action == "post":
        mid = bus.post(args.sender, args.to, " ".join(args.text), prio=args.prio, topic=args.topic or "",
                       dedupe_key=args.key)
        if args.md:
            from .toolsfs import ToolsDir
            msg = [m for m in bus.pending(args.to) if m.id == mid][0]
            bus.export_to_inbox(ToolsDir(cfg.path("tools"), clock, cfg.path("scopes")).inbox_file(args.to), msg)
        print(f"#{mid} to {args.to}")
        return 0
    if args.action == "read":
        msgs = bus.read(args.to, limit=args.limit)
        print("\n".join(m.line() for m in msgs) or f"no unread messages for {args.to}")
        return 0
    if args.action == "ack":
        n = bus.ack(args.to, [int(x) for x in args.text] or None)
        print(f"{n} done")
        return 0
    if args.action == "import":
        from .toolsfs import ToolsDir
        tools = ToolsDir(cfg.path("tools"), clock, cfg.path("scopes"))
        files = [Path(f) for f in args.text] or sorted(tools.scopes.glob("inbox-*.md"))
        for f in files:
            new, skip = bus.import_inbox(f)
            print(f"{f.name}: {new} new, {skip} already present")
        return 0
    return 2


def cmd_lint(args) -> int:
    from .lint import lint_paths
    cfg = load_config(args.config)
    fs = lint_paths([Path(p) for p in args.paths], ExceptionRegistry(cfg.path("exceptions")))
    for f in fs:
        print(f)
    errors = [f for f in fs if f.level == "error"]
    print(f"{len(fs)} findings ({len(errors)} errors)")
    return 1 if errors else 0


def cmd_budget(args) -> int:
    from .metrics import budget_report
    cfg = load_config(args.config)
    text, over = budget_report(Store(cfg.path("state_db")), time.time(), int(cfg.get("metrics.daily_token_budget")))
    print(text)
    return 1 if over else 0


def cmd_metrics(args) -> int:
    from .metrics import export_csv
    cfg = load_config(args.config)
    out = export_csv(Store(cfg.path("state_db")))
    if args.out:
        Path(args.out).write_text(out, encoding="utf-8")
        print(f"{out.count(chr(10)) - 1} rows -> {args.out}")
    else:
        print(out, end="")
    return 0


def cmd_overlay(args) -> int:
    from .overlay import overlay_lines, overlay_send
    p = _pilot(args)
    # BUG-101: stateless - the current !!/! items of a read-only digest; the orchestrator's delta stays untouched
    digest = (p.digest(include_warnings=False, since_last=False, persist=False) if not args.text
              else " ".join(args.text))
    lines = overlay_lines(digest, max_lines=int(p.cfg.get("overlay.max_lines", 3)),
                          max_chars=int(p.cfg.get("overlay.max_chars", 120)), fallback=bool(args.text))
    cmds = overlay_send(lines, p.store, p.client, time.time(), dedupe_min=float(p.cfg.get("overlay.dedupe_min", 10)),
                        dry_run=not args.send)
    print("\n".join(cmds) or "nothing new for the display")
    return 0


def cmd_trade(args) -> int:
    from dataclasses import asdict
    from .trade_flow import TradeFlow, obs_from_status
    p = _pilot(args)
    flow = TradeFlow(**(p.store.get("trade.flow") or {}))
    if args.action == "reset":
        p.store.set("trade.flow", asdict(TradeFlow()))
        print("Trade automaton reset")
        return 0
    if args.action == "approve":
        flow.approve()
        p.store.set("trade.flow", asdict(flow))
        print(f"Live selection approved (state {flow.state})")
        return 0
    if args.action == "status":
        print(f"State {flow.state}{' (' + flow.abort_reason + ')' if flow.abort_reason else ''}; "
              f"approved: {flow.approved}; last steps: {' | '.join(flow.log[-4:])}")
        return 0
    st = p.client.run("claude/handel status")
    clock = p.client.run("claude/advance clock")
    paused = bool((clock.json or {}).get("paused")) if isinstance(clock.json, dict) else False
    obs = obs_from_status(st.json if isinstance(st.json, dict) else {}, paused=paused,
                          stable_s=float(args.stable_s), last_ok=st.ok)
    cmds = flow.step(obs, time.time())
    for c in cmds:
        if args.dry_run:
            print("[dry] " + c)
        else:
            r = p.client.run(c)
            print(("ok   " if r.ok else "ERROR ") + c)
            # Live lesson (Run 5): 'handel open' reports "Trade button not unique" with a candidate list when two texts
            # match. The real button is the topmost one (smallest y); the line "... at depot" is not a button.
            cand = (r.json or {}).get("candidates") if isinstance(r.json, dict) and c.startswith("claude/handel open") else None
            if cand and "--x" not in c:
                good = [k for k in cand if "depot" not in str(k.get("after", "")).lower()]
                best = min(good or cand, key=lambda k: k.get("y", 999))
                c2 = f"claude/handel open --live --x {best['x']} --y {best['y']}"
                r2 = p.client.run(c2)
                print(("ok   " if r2.ok else "ERROR ") + c2)
    if not args.dry_run:                       # dry run: the state machine must not advance past commands never sent
        p.store.set("trade.flow", asdict(flow))
    print(f"State now: {flow.state}" + (f" ({flow.abort_reason})" if flow.abort_reason else ""))
    return 0


def _kv(text: str | None, allowed: tuple[str, ...] | None = None, what: str = "value") -> dict:
    """'k=v,k=v' -> {k: float}. BUG-114: a part without '=', a non-number or an unknown key is an error."""
    out = {}
    for part in (text or "").split(","):
        if not part.strip():
            continue
        if "=" not in part:
            raise ValueError(f"expected name=number, got '{part.strip()}' (e.g. iron=32,bronze=31)")
        k, v = part.split("=", 1)
        k = k.strip()
        if not k:
            raise ValueError(f"missing name in '{part.strip()}'")
        if allowed is not None and k not in allowed:
            raise ValueError(f"unknown {what} '{k}' (allowed: {', '.join(allowed)})")
        try:
            out[k] = float(v)
        except ValueError:
            raise ValueError(f"'{k}': not a number: '{v.strip()}'") from None
        if out[k] < 0:
            raise ValueError(f"'{k}': must not be negative ({v.strip()})")
    return out


TRADE_ITEM_KEYS = ("id", "name", "category", "value", "weight", "qty", "priority_category")
TRADE_EXAMPLE = ('{"own": [{"id": "o1", "name": "Rock mug", "category": "other", "value": 100, "weight": 2, "qty": 10}], '
                 '"offer": [{"id": "f1", "name": "Plump helmet", "category": "food", "value": 10, "weight": 1, "qty": 20}], '
                 '"ratio": 2.3, "reserves": {"o1": 2}, "max_weight": 100, '
                 '"priorities": ["food", "wood", "metal", "cloth", "other"]}')


def _trade_items(xs, where: str) -> list:
    """BUG-113/BUG-123: validate the hand-written trade JSON with a message that names the allowed fields."""
    from .planners import TradeItem
    if xs is None:
        return []
    if not isinstance(xs, list):
        raise ValueError(f"--json: '{where}' must be a list of items")
    out = []
    for i, x in enumerate(xs):
        if not isinstance(x, dict):
            raise ValueError(f"--json: {where}[{i}] must be an object")
        unknown = [k for k in x if k not in TRADE_ITEM_KEYS]
        missing = [k for k in TRADE_ITEM_KEYS[:5] if k not in x]
        if unknown or missing:
            raise ValueError(f"--json: {where}[{i}]: " + (f"unknown field(s) {unknown}; " if unknown else "")
                             + (f"missing field(s) {missing}; " if missing else "")
                             + f"fields: {', '.join(TRADE_ITEM_KEYS)} (qty, priority_category optional)")
        try:
            out.append(TradeItem(id=str(x["id"]), name=str(x["name"]), category=str(x["category"]),
                                 value=int(x["value"]), weight=float(x["weight"]), qty=int(x.get("qty", 1)),
                                 priority_category=x.get("priority_category")))
        except (TypeError, ValueError):
            raise ValueError(f"--json: {where}[{i}]: value/weight/qty must be numbers") from None
    return out


def _map_size(text: str | None) -> tuple[int, int] | None:
    if not text:
        return None
    import re as _re
    m = _re.fullmatch(r"\s*(\d+)\s*[xX,]\s*(\d+)(?:\s*[xX,]\s*\d+)?\s*", text)
    if not m:
        raise ValueError(f"--map-size: expected WxH (e.g. 192x192), got '{text}'")
    return int(m.group(1)), int(m.group(2))


def _origin(text: str | None) -> tuple[int, int] | None:
    if not text:
        return None
    try:
        x, y = (int(v) for v in text.replace(" ", "").split(",")[:2])
    except ValueError:
        raise ValueError(f"--origin: expected x,y (e.g. 100,80), got '{text}'") from None
    return x, y


def _no_data(snap) -> str | None:
    """BUG-106: the planners must not compute with 0 when the game could not be read."""
    from .guard import snapshot_unreadable
    if not snapshot_unreadable(snap):
        return None
    why = "; ".join(str(f) for f in (snap.failed if snap is not None else [])[:2]) or "no population value"
    return f"no data from the game (query failed: {why}) - check DF/dfhack-run"


def cmd_plan(args) -> int:
    from . import planners as pl
    if args.kind == "blueprint":
        if not args.files:
            raise ValueError("plan blueprint needs at least one CSV file")
        msize, origin = _map_size(args.map_size), _origin(args.origin)
        if origin and not msize:
            raise ValueError("--origin needs --map-size")
        bad = 0
        for f in args.files:
            fs = pl.validate_blueprint(Path(f).read_text(encoding="utf-8", errors="replace"),
                                       **({"map_size": msize} if msize else {}),
                                       **({"origin": origin} if origin else {}))
            print(f"{f}: {'ok' if not fs else ''}")
            for x in fs:
                print(f"  {x}")
            bad += pl.has_errors(fs)
        if not msize:
            print("Note: map bounds (E_BOUNDS) not checked; give --map-size WxH [--origin x,y]")
        return 1 if bad else 0
    if args.kind == "trade":
        if not args.json:
            raise ValueError("plan trade needs --json <file>; example: " + TRADE_EXAMPLE)
        d = json.loads(Path(args.json).read_text(encoding="utf-8-sig"))
        if not isinstance(d, dict):
            raise ValueError("--json: top level must be an object, e.g. " + TRADE_EXAMPLE)
        pr = d.get("priorities")
        if pr is not None and not (isinstance(pr, list) and all(isinstance(x, str) for x in pr)):
            raise ValueError("--json: 'priorities' must be a list of category names, e.g. [\"food\", \"gem\"]")
        kw = {"priorities": pr} if pr is not None else {}
        plan = pl.plan_trade(_trade_items(d.get("own"), "own"), _trade_items(d.get("offer"), "offer"),
                             ratio=float(d.get("ratio", 2.3)), reserves=d.get("reserves"),
                             max_weight=d.get("max_weight"), **kw)
        print(f"Buy {plan.buy_value} / sell {plan.sell_value} (ratio {plan.ratio}), weight {plan.weight}, "
              f"method {plan.method}")
        for ln in plan.buy:
            print(f"  buy  {ln.qty}x {ln.name} ({ln.category}) at {ln.value} each")
        for ln in plan.sell:
            print(f"  sell {ln.qty}x {ln.name} at {ln.value} each")
        for n in plan.notes:
            print("  Note: " + n)
        return 0
    if args.kind == "dig":
        if not args.targets or not args.targets.strip():
            raise ValueError("plan dig needs --targets 'x,y[,prio];x,y;...'")
        if not args.area and not args.area_file:
            raise ValueError("plan dig needs --area 'z x y w h' or --area-file <file>")
        try:
            targets = [tuple(int(v) for v in t.split(",")) for t in args.targets.split(";") if t.strip()]
        except ValueError:
            raise ValueError(f"--targets: expected 'x,y[,prio];...', got '{args.targets}'") from None
        if any(len(t) not in (2, 3) for t in targets):
            raise ValueError(f"--targets: each target is x,y or x,y,prio, got '{args.targets}'")
        try:
            picks, max_open = int(args.picks), int(args.max_open)
        except ValueError:
            raise ValueError("--picks/--max-open must be whole numbers") from None
        if picks < 1 or max_open < 1:
            raise ValueError("--picks and --max-open must be at least 1")
        if args.area_file:
            text = Path(args.area_file).read_text(encoding="utf-8")
        else:
            p = _pilot(args)
            text = p.client.run(f"claude/area {args.area}").stdout
        area = pl.parse_area(text)
        plan = pl.plan_dig(area, targets, picks=picks, max_open=max_open)
        for i, b in enumerate(plan.batches, 1):
            print(f"Batch {i}: {len(b)} tiles " + " ".join(f"({x},{y})" for x, y in b[:12]) + (" …" if len(b) > 12 else ""))
            if args.csv:
                csv_text, (x0, y0) = pl.dig.batch_to_csv(b)
                print(f"  quickfort run <file> -c {x0},{y0},{area.z}\n" + csv_text)
        if plan.unreachable:
            print("unreachable: " + " ".join(f"({x},{y})" for x, y in plan.unreachable))
        for n in plan.notes:
            print("Note: " + n)
        if not plan.batches and not plan.unreachable:
            print("nothing to dig")
        return 0
    bars = {k: int(v) for k, v in _kv(args.bars).items()} if args.kind == "armor" else {}
    prod = _kv(args.prod, ("drink", "food"), "resource") if args.kind == "supply" else {}
    if args.kind == "supply" and args.growth is not None and args.growth < 0:
        raise ValueError(f"--growth must not be negative ({args.growth})")
    p = _pilot(args)
    snap = p.snapshot()
    nd = _no_data(snap)
    if nd:
        print(f"Error: {nd}", file=sys.stderr)
        return 1
    if args.kind == "armor":
        # BUG-107: militia miners (pick only) are no soldiers; a carried weapon and a full set (9/9) are equipment
        # the plan must not forge again. claude/mil tabelle gives only a piece COUNT, not which armor slots are worn.
        soldiers, miners, partial = [], 0, 0
        for q in snap.squads:
            for m in q.members:
                weapon = (m.weapon or "").lower().rstrip("*")
                if weapon == "pick":
                    miners += 1
                    continue
                full = m.parts is not None and m.parts >= 9
                eq = list(pl.armor.SLOTS) if full else (["weapon"] if weapon else [])
                partial += 0 if full else 1
                soldiers.append(pl.Soldier(id=m.id, name=m.name, equipped=eq))
        plan = pl.plan_armor(snap.pop_total, soldiers, {}, bars)
        print(f"Quota {plan.quota} soldiers (now {plan.soldiers_now}, missing {plan.recruits_needed}); "
              f"bars needed {plan.bars_needed}, available {plan.bars_available}, missing {plan.bars_missing}")
        for o in plan.orders:
            print(f"  forge {o.qty}x {o.slot} from {o.metal} ({o.bars_total} bars)")
        for o in plan.deferred:
            print(f"  deferred {o.qty}x {o.slot} (bars missing)")
        for n in plan.notes:
            print("  Note: " + n)
        if miners:
            print(f"  Note: {miners} pick carriers (mining squad) not counted as soldiers")
        if partial:
            print(f"  Note: UPPER BOUND - for {partial} soldiers below 9/9 pieces the worn armor slots are unknown "
                  f"(claude/mil tabelle gives only a count) and free stock is not checked; compare with claude/mil equip")
        return 0
    if args.kind == "supply":
        st = snap.stocks
        meals, fish, meat = (st.meals or 0), (st.fish or 0), (st.meat or 0)
        stock = {"drink": float(st.drink or 0), "food": float(meals + fish + meat)}
        fc = pl.forecast(stock, float(snap.pop_total or 0), production=prod or None, growth=args.growth)
        for res, d in fc.days_left.items():
            extra = ""
            if res == "food":       # BUG-108: say what is counted (the digest 'Food Nd' is the game's food_days)
                plants = getattr(st, "plants", None)
                extra = f" (meals {meals}, fish {fish}, meat {meat}" + (
                    f"; raw plants {plants} not counted" if plants else "") + ")"
            print(f"{res}: stock {stock[res]:.0f}{extra}, " + (f"empty in {d:.0f} days" if d is not None else
                                                                "no shortage within the horizon"))
        if getattr(snap, "food_days", None) is not None:
            print(f"Note: the digest shows the game's food_days ({snap.food_days}), which include raw plants")
        for w in fc.warn:
            print("Warning: " + w)
        return 0
    return 2


def cmd_siege(args) -> int:
    """Spec 01: work through a siege without LLM moves (pilot_siege.lua, not tested live)."""
    from .siege import SiegeRunner
    p = _pilot(args)
    runner = SiegeRunner(p.client, p.tools, p.store, p.clock, p.cfg.get("siege", {}))
    flow, log = runner.run(loop=not args.once, dry=args.dry_run)
    if args.verbose:
        for ln in log:
            print("  " + ln)
    if flow.state == "IDLE":
        print("no attackers on the map")
        return 0
    print("\n".join(flow.summary()))
    return 0 if flow.state in ("DONE", "ENGAGE", "PREPARE") or args.dry_run else 1


def cmd_caravan(args) -> int:
    """Spec 02: decide on the caravan (trade/skip), trade via the trade automaton, release stuck merchants."""
    from .caravan import CaravanPilot
    from .clock import GameDate
    from .config import HOME
    p = _pilot(args)
    cp = CaravanPilot(p.client, p.tools, p.store, p.clock, p.cfg.get("caravan", {}), HOME, registry=p.client.registry)
    if args.action == "reset":
        p.store.set("caravan.state", {})
        print("Caravan autopilot reset")
        return 0
    if args.action == "status":
        print("\n".join(cp.report()))
        return 0
    for _ in range(int(args.max_steps) if args.loop else 1):
        st = p.client.run("claude/status")
        d = (st.json or {}).get("date") if isinstance(st.json, dict) else None
        tick = GameDate(int(d["year"]), int(d["year_tick"])).abs_ticks if isinstance(d, dict) and "year" in d else None
        state, log = cp.step(dry=args.dry_run, game_tick=tick, stable_s=float(args.stable_s))
        for ln in log:
            print("  " + ln)
        if state in ("idle", "waiting", "skip", "done", "abort", "failed", "review") or args.dry_run:
            break
        p.clock.sleep(float(args.interval))
    print("\n".join(cp.report()))
    return 0


def cmd_mood(args) -> int:
    """Spec 03: check running moods and fix gaps through maintenance; reserve = prevention."""
    from .moods import MoodManager
    p = _pilot(args)
    mm = MoodManager(p.client, p.tools, p.store, p.clock, p.cfg.get("mood", {}))
    lines = mm.reserve() if args.action == "reserve" else mm.check(dry=args.dry_run)
    print("\n".join(lines))
    return 0


def cmd_care(args) -> int:
    """Spec 04: measure care, set doctor labors (labor menu), hospital/water hints."""
    from .care import CareWatch
    p = _pilot(args)
    gl = p.gamelog()
    cw = CareWatch(p.client, p.tools, p.store, p.clock, p.cfg.get("care", {}),
                   gamelog_lines=lambda: (gl.new_lines(), gl.recent())[1])
    print("\n".join(cw.run(dry=args.dry_run)))
    return 0


def cmd_forecast(args) -> int:
    """Spec 05: forecast food/drinks (time series in state.db); backtest against metrics.csv."""
    from .forecast import Forecaster, backtest, series_from_metrics
    p = _pilot(args)
    if args.action == "backtest":
        s = series_from_metrics(args.file)
        for res in ("food", "drink"):
            r = backtest(s, res, int(p.cfg.get("forecast.window", 5)), float(args.horizon))
            print(f"{res}: {r['n']} predictions, mean error {r['mean_err']}, median {r['median_err']}")
        return 0
    fc = Forecaster(p.store, p.clock, p.cfg.get("forecast", {}))
    line, news = fc.update(p.snapshot(), record=not args.dry_run)
    print(line)
    for n in news:
        print(n)
    conf = f"{fc.confidence():.2f}" if fc.store.get("forecast.errors") else "n/a (no calibration yet)"
    print(f"Points {len(fc.series())}, confidence {conf}")
    return 0


def cmd_workload(args) -> int:
    """Spec 06: diagnose the cause of idleness, perform maintenance, measure the effect."""
    from .anomaly import cancel_loops
    from .workload import WorkloadPilot
    p = _pilot(args)
    gl = p.gamelog()
    gl.new_lines()
    wp = WorkloadPilot(p.client, p.store, p.clock, p.cfg.get("workload", {}))
    obs = wp.observe(p.snapshot(), cancel_loops(gl.recent(), min_count=1))
    print("\n".join(wp.run(obs, dry=args.dry_run)))
    return 0


def cmd_bottleneck(args) -> int:
    """Spec 07: bottleneck in the production chains (graph data/graphs/produktion.yaml)."""
    from .bottleneck import BottleneckWatch
    from .clock import TICKS_PER_DAY, GameDate
    p = _pilot(args)
    bw = BottleneckWatch(p.client, p.store, p.clock, p.cfg.get("bottleneck", {}), HOME)
    if args.action == "validate":
        print(f"Graph ok: {len(bw.graph.nodes)} nodes, {len(bw.graph.goals)} goals")
        return 0
    st = p.client.run("claude/status")
    d = (st.json or {}).get("date") if isinstance(st.json, dict) else None
    day = GameDate(int(d["year"]), int(d["year_tick"])).abs_ticks / TICKS_PER_DAY \
        if isinstance(d, dict) and "year" in d and "year_tick" in d else None
    print("\n".join(bw.run(game_day=day, dry=args.dry_run)))
    return 0


def cmd_water(args) -> int:
    """Spec 08: scan | check x y z | watch (water in the fort) | lint-cmd "<command>"."""
    from .lint import lint_dig
    from .water import WaterWatch
    p = _pilot(args)
    ww = WaterWatch(p.client, p.tools, p.store, p.clock, p.cfg.get("water", {}))
    if args.action == "check":
        x, y, z = (int(v) for v in args.xyz)
        v = ww.check(x, y, z)
        print(v.line())
        return 0 if v.result == "ok" else 1
    if args.action == "scan":
        for name in ("fort_box", "watch_box"):
            j = ww.scan(ww.cfg[name])
            print(f"{name}: " + ("not readable" if j is None else
                                 f"water {j.get('water')}, magma {j.get('magma')}, front {j.get('front')}, "
                                 f"levels {j.get('by_z')}"))
        return 0
    if args.action == "lint-cmd":
        fs = lint_dig(" ".join(args.xyz), ww.cfg["forbid_dig"], p.client.registry)
        print("\n".join(map(str, fs)) or "ok")
        return 1 if fs else 0
    print("\n".join(ww.watch(dry=args.dry_run)))
    return 0


def cmd_reboot(args) -> int:
    """Spec 09: check and start services after load/restart; load = title-menu load helper (only with auto_load)."""
    from .reboot import Reboot, load_commands
    p = _pilot(args)
    rb = Reboot(p.client, p.store, p.clock, p.cfg.get("reboot", {}), HOME)
    if args.action == "validate":
        print(f"services.yaml ok: {len(rb.services)} entries, all with check command")
        return 0
    if args.action == "load":
        if not rb.cfg["auto_load"]:
            print("Load helper off (reboot.auto_load: false) - only enable at the player's request")
            return 1
        for c in load_commands(rb.cfg):
            r = p.client.run(c) if not args.dry_run else None
            print(("[dry] " if args.dry_run else ("ok " if r and r.ok else "ERROR ")) + c)
            p.clock.sleep(0 if args.dry_run else 4)
        return 0
    lines = rb.run(dry=args.dry_run)
    print("\n".join(ln for ln in lines if args.verbose or not ln.startswith(("ok ", "[dry] claude/advance"))))
    return 0 if not any("NOT" in ln for ln in lines) else 1


def cmd_agents(args) -> int:
    """Spec 10: prompt <scope> --task | lint-report <file|-> | cost [--dir] [--compare]."""
    from datetime import datetime

    from . import agents as ag
    cfg_all = load_config(args.config)
    cfg = {**ag.DEFAULTS, **(cfg_all.get("agents") or {})}
    if args.action == "prompt":
        from .brief import build_brief, load_scopes
        from .kb import KB
        p = _pilot(args)
        args.scope = args.target
        if not args.scope:
            print("Usage: python -m df_llm_helper agents prompt <scope> --task \"...\"")
            return 2
        if not args.force and not ag.TaskDedupe(p.store, p.clock, int(cfg["dedupe_s"])).check_and_mark(
                args.scope, args.task or ""):
            print(f"Same task for {args.scope} was assigned < {int(cfg['dedupe_s']) // 60} min ago "
                  f"(--force to repeat)")
            return 1
        snap = p.snapshot()
        scope_file = "militaer" if args.scope == "verteidigung" else args.scope
        mem = p.tools.memory_file(scope_file)
        brief = build_brief(args.scope, scopes_def=load_scopes(Path(p.cfg.get("paths.data")) / "scopes.yaml"),
                            ctx=p.context(snap, p.cancels()), snap=snap, kb=KB.load(p.cfg),
                            memory_text=mem.read_text(encoding="utf-8", errors="replace") if mem.exists() else None,
                            inbox_lines=p.tools.inbox_lines(args.scope), th=p.cfg.th,
                            budget=int(cfg["prompt_budget"]), date_text=snap.date.text() if snap.date else "")
        print(ag.build_prompt(args.scope, args.task or "", brief, fort=snap.fort or "?",
                              max_lines=int(cfg["max_report_lines"]), budget=int(cfg["prompt_budget"])))
        return 0
    if args.action == "lint-report":
        src = sys.stdin.read() if args.target in (None, "-") else Path(args.target).read_text(encoding="utf-8")
        rc = ag.lint_report(src, int(cfg["max_report_lines"]))
        if rc.truncated:
            arch = ag.archive_report(src, args.scope or "agent",
                                     Path(cfg_all.get("paths.tools")) / cfg["archive_dir"], datetime.now())
            print(f"Original archived: {arch}")
        print(("ok" if rc.ok else "Report: " + "; ".join(rc.problems)))
        if rc.truncated:
            print(rc.text)
        return 0 if rc.ok else 1
    base = Path(args.dir or cfg["transcript_dir"]).expanduser()
    files = sorted(base.rglob("subagents/*.jsonl")) + sorted(base.glob("*.jsonl")) if base.exists() else []
    files = sorted(set(files))
    if not files:
        print(f"no transcripts under {base}")
        return 1
    rows, lines = ag.cost_report(files, cfg)
    print("\n".join(lines))
    if args.compare:
        print(ag.compare(rows))
    return 0


def cmd_dashboard(args) -> int:
    """Spec 11: HTML from state.db; map <name> x y z w h stores a map excerpt (claude/area) in state.db."""
    from .dashboard import collect as dcollect, render as drender, validate_html, write_if_changed
    p = _pilot(args)
    dcfg = p.cfg.get("dashboard", {})
    if args.action == "map":
        if len(args.rest) != 6:
            print("Usage: python -m df_llm_helper dashboard map <name> x y z w h")
            return 2
        name, x, y, z, w, h = args.rest
        r = p.client.run(f"claude/area {int(z)} {int(x)} {int(y)} {int(w)} {int(h)}")
        if not r.ok:
            print("claude/area failed: " + (r.stderr or "")[:100])
            return 1
        maps = dict(p.store.get("dashboard.maps") or {})
        maps[name] = r.stdout.rstrip("\n")
        p.store.set("dashboard.maps", maps)
        print(f"Map '{name}' saved ({len(r.stdout.splitlines())} lines)")
        return 0
    if args.action == "unmap":
        maps = dict(p.store.get("dashboard.maps") or {})
        maps.pop(args.rest[0] if args.rest else "", None)
        p.store.set("dashboard.maps", maps)
        return 0
    if not args.offline:                                   # refresh the building counters for the build plan (read only)
        from .client import register_read
        from .dashboard import LOCATIONS_CMD, parse_locations
        register_read(LOCATIONS_CMD)
        r = p.client.run("claude/buildings")
        if r.ok and isinstance(r.json, dict) and isinstance(r.json.get("counts"), dict):
            counts = dict(r.json["counts"])
            lr = p.client.run(LOCATIONS_CMD)
            counts.update(parse_locations(lr.stdout if lr.ok else ""))
            p.store.set("dashboard.buildings", {"counts": counts, "ts": p.clock.now().epoch})
    text = drender(dcollect(p.store, p.clock.now().epoch, dcfg), dcfg)
    errs = validate_html(text)
    out = Path(args.out) if args.out else Path(p.cfg.get("paths.tools")) / dcfg.get("out", "out/dashboard.html")
    changed = write_if_changed(text, out, p.store)
    print(f"{out} ({len(text.encode('utf-8')) // 1024} KB, {'newly written' if changed else 'unchanged'})"
          + (" ERROR: " + "; ".join(errs) if errs else ""))
    return 1 if errs else 0


def _journal_target(cfg_j: dict, path: str | None, key: str) -> Path:
    """Spec 12 acceptance 5: write only under df-llm-helper/ or to the configured file."""
    p = (HOME / (path or cfg_j[key])).resolve()
    allowed = {(HOME / cfg_j[k]).resolve() for k in ("chronik", "metrics", "postmortem") if cfg_j.get(k)}
    if p not in allowed and HOME.resolve() not in p.parents:
        raise SystemExit(f"Write refused: {p} lies outside df-llm-helper/ and is not configured")
    return p


def cmd_journal(args) -> int:
    """Spec 12: ingest | chronik [--append] | lessons [--accept KEY] | metrics [--out] | postmortem [--out]."""
    from datetime import date as _date

    from .journal import Journal
    from .toolsfs import read_text_tolerant
    p = _pilot(args)
    cj = {**p.cfg.get("journal", {})}
    j = Journal(p.store, cj, HOME, registry=p.client.registry)
    if args.action == "ingest":
        src = Path(args.events) if args.events else (HOME / cj["events_log"])
        if not src.exists():
            print(f"Event log missing: {src}")
            return 1
        text = read_text_tolerant(src)
        if args.date:
            day0 = _date.fromisoformat(args.date)
        else:        # the log only has times of day: its last line is "today" (mtime), count day changes backwards
            from .journal import infer_first_day
            day0 = infer_first_day(text, _date.fromtimestamp(src.stat().st_mtime))
        new, total = j.ingest_log(text, day0)
        w = j.ingest_warnings()
        print(f"{total} chronicle events in the log, {new} new; {w} critical df-llm-helper warnings taken over")
        return 0
    if args.action == "chronik":
        lines = j.chronik()
        print("\n".join(lines) or "no events (run journal ingest first)")
        print(f"(coverage {j.coverage() * 100:.0f} % of the events)")
        if args.append and lines:
            _journal_target(cj, None, "chronik")
            print(f"appended to {j.append_chronik(lines)}")
        return 0
    if args.action == "lessons":
        ls = j.lessons()
        if args.accept:
            hit = [x for x in ls if x.key == args.accept]
            if not hit:
                print("no open proposal with this key")
                return 1
            print(f"KB draft: {j.accept(hit[0])}")
            j.mark_suggested(hit)
            return 0
        for x in ls:
            print(f"- [{x.key}] {x.text}")
        print(f"{len(ls)} suggestions" + (" (approval: journal lessons --accept '<key>')" if ls else ""))
        return 0
    if args.action == "metrics":
        text = j.monthly_metrics()
        if args.out:
            t = _journal_target(cj, args.out, "metrics")
            t.write_text(text, encoding="utf-8")
            print(f"{text.count(chr(10)) - 1} monthly lines -> {t}")
        else:
            print(text, end="")
        return 0
    text = j.postmortem()
    if args.out:
        t = _journal_target(cj, args.out, "postmortem")
        t.write_text(text, encoding="utf-8")
        print(f"Postmortem skeleton -> {t}")
    else:
        print(text, end="")
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="df-llm-helper", description="Helper for LLM control of Dwarf Fortress")
    ap.add_argument("--config", default=None, help="config.yaml (default: config.yaml in the project folder)")
    ap.add_argument("--mock", default=None, help="fixture folder instead of a real DF (e.g. fixtures/run5)")
    ap.add_argument("--replay-file", default=None, help="recorded session (*.jsonl) instead of a real DF")
    ap.add_argument("--record", default=None, help="record all DF calls into this JSONL file")
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("digest", help="compact status report (delta)")
    s.add_argument("--scope")
    s.add_argument("--full", action="store_true", help="without delta (everything notable)")
    s.set_defaults(fn=cmd_digest)
    s = sub.add_parser("check", help="orchestrator check: heartbeat + guard + autopilot + digest (one call)")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_check)
    s = sub.add_parser("cycle", help="one cycle: guard + autopilot + digest")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_cycle)
    s = sub.add_parser("autopilot", help="deterministic rules")
    s.add_argument("action", nargs="?", default="run", choices=["run", "rules", "conflicts", "enable"])
    s.add_argument("rule", nargs="?")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--loop", action="store_true")
    s.add_argument("--once", action="store_true")
    s.add_argument("--interval", type=float, default=60)
    s.set_defaults(fn=cmd_autopilot)
    s = sub.add_parser("guard", help="deadman/tempo/watcher check")
    s.add_argument("action", nargs="?", default="run", choices=["run", "ack-gate"])
    s.add_argument("gate", nargs="?", type=int)
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--loop", action="store_true")
    s.add_argument("--once", action="store_true")
    s.add_argument("--interval", type=float, default=60)
    s.set_defaults(fn=cmd_guard)
    s = sub.add_parser("waechter", help="real-time watcher (replaces unpause-guard.ps1), permanent with --loop")
    s.add_argument("--loop", action="store_true")
    s.add_argument("--interval", default=None)
    s.set_defaults(fn=cmd_waechter)
    s = sub.add_parser("tempo", help="time lapse: status (display only) | on (only without guard blockers) | off")
    s.add_argument("action", choices=["on", "off", "status"])
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_tempo)
    s = sub.add_parser("siege", help="Siege autopilot (spec 01): until the end (default), --once for one step")
    s.add_argument("--once", action="store_true")
    s.add_argument("--loop", action="store_true", help="(default) until no attackers are left")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("-v", "--verbose", action="store_true")
    s.set_defaults(fn=cmd_siege)
    s = sub.add_parser("caravan", help="Caravan autopilot (spec 02): step|status|reset")
    s.add_argument("action", nargs="?", default="step", choices=["step", "status", "reset"])
    s.add_argument("--loop", action="store_true", help="repeat until completion/approval wait point")
    s.add_argument("--max-steps", default=40)
    s.add_argument("--interval", default=3)
    s.add_argument("--stable-s", default=2.0)
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_caravan)
    s = sub.add_parser("mood", help="Mood manager (spec 03): check|reserve")
    s.add_argument("action", nargs="?", default="check", choices=["check", "reserve"])
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_mood)
    s = sub.add_parser("care", help="Hunger/hospital watcher (spec 04)")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_care)
    s = sub.add_parser("forecast", help="Famine forecast (spec 05): show|backtest")
    s.add_argument("action", nargs="?", default="show", choices=["show", "backtest"])
    s.add_argument("--file", default=str(Path(__file__).resolve().parents[2] / "metrics.csv"))
    s.add_argument("--horizon", default=3)
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_forecast)
    s = sub.add_parser("workload", help="Workload control (spec 06)")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_workload)
    s = sub.add_parser("bottleneck", help="Bottleneck watcher material/fuel (spec 07): check|validate")
    s.add_argument("action", nargs="?", default="check", choices=["check", "validate"])
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_bottleneck)
    s = sub.add_parser("water", help="Water/flood watcher (spec 08): watch|scan|check x y z|lint-cmd <command>")
    s.add_argument("action", nargs="?", default="watch", choices=["watch", "scan", "check", "lint-cmd"])
    s.add_argument("xyz", nargs="*")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_water)
    s = sub.add_parser("reboot", help="Restart/load (spec 09): run|validate|load")
    s.add_argument("action", nargs="?", default="run", choices=["run", "validate", "load"])
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("-v", "--verbose", action="store_true")
    s.set_defaults(fn=cmd_reboot)
    s = sub.add_parser("agents", help="Subagents (spec 10): prompt <scope> --task | lint-report <file> | cost")
    s.add_argument("action", choices=["prompt", "lint-report", "cost"])
    s.add_argument("target", nargs="?", help="prompt: scope; lint-report: file or -")
    s.add_argument("--task", default="")
    s.add_argument("--scope", default=None, help="lint-report: scope for the archive")
    s.add_argument("--force", action="store_true")
    s.add_argument("--dir", default=None, help="cost: folder with transcripts")
    s.add_argument("--compare", action="store_true")
    s.set_defaults(fn=cmd_agents)
    s = sub.add_parser("dashboard", help="Dashboard HTML (spec 11): build | map <name> x y z w h | unmap <name>")
    s.add_argument("action", nargs="?", default="build", choices=["build", "map", "unmap"])
    s.add_argument("rest", nargs="*")
    s.add_argument("--out", default=None)
    s.add_argument("--offline", action="store_true", help="state.db only, no DF query")
    s.set_defaults(fn=cmd_dashboard)
    s = sub.add_parser("journal", help="Chronicle/lessons (spec 12): ingest|chronik|lessons|metrics|postmortem")
    s.add_argument("action", choices=["ingest", "chronik", "lessons", "metrics", "postmortem"])
    s.add_argument("--events", default=None, help="ingest: event log (default journal.events_log)")
    s.add_argument("--date", default=None, help="ingest: date of the first log line (YYYY-MM-DD)")
    s.add_argument("--append", action="store_true", help="chronik: append to journal.chronik")
    s.add_argument("--accept", default=None, help="lessons: approve a proposal (KB draft)")
    s.add_argument("--out", default=None)
    s.set_defaults(fn=cmd_journal)
    s = sub.add_parser("heartbeat", help="set the orchestrator heartbeat")
    s.set_defaults(fn=cmd_heartbeat)
    s = sub.add_parser("wake", help="wake filter for the monitor (files only, one line per event)")
    s.add_argument("--loop", action="store_true")
    s.add_argument("--interval", type=float, default=10)
    s.add_argument("--emit-existing", action="store_true", help="also report legacy flags on the first run")
    s.set_defaults(fn=cmd_wake)
    s = sub.add_parser("runbook", help="Runbooks: list|show|run|diagnose")
    s.add_argument("action", choices=["list", "show", "run", "diagnose"])
    s.add_argument("id", nargs="?")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--param", action="append", help="name=value")
    s.set_defaults(fn=cmd_runbook)
    s = sub.add_parser("kb", help="knowledge base: search|get|list|import")
    s.add_argument("action", choices=["search", "get", "list", "import"])
    s.add_argument("query", nargs="*")
    s.add_argument("-k", type=int, default=3)
    s.add_argument("--all", action="store_true")
    s.add_argument("--files", nargs="*", default=[])
    s.set_defaults(fn=cmd_kb)
    s = sub.add_parser("brief", help="briefing for a scope agent")
    s.add_argument("scope")
    s.add_argument("--budget", type=int)
    s.set_defaults(fn=cmd_brief)
    s = sub.add_parser("replay", help="replay and check scenarios")
    s.add_argument("files", nargs="*")
    s.add_argument("-v", "--verbose", action="store_true")
    s.set_defaults(fn=cmd_replay)
    s = sub.add_parser("record", help="execute and record commands (with --record)")
    s.add_argument("commands", nargs="*")
    s.set_defaults(fn=cmd_record)
    s = sub.add_parser("exception", help="exception register (fair play)")
    s.add_argument("action", choices=["list", "add"])
    s.add_argument("rule", nargs="?")
    s.add_argument("--objects")
    s.add_argument("--reason", default="")
    s.add_argument("--ja", help="verbatim quote of the player's consent")
    s.add_argument("--max-uses", type=int)
    s.add_argument("--expires")
    s.set_defaults(fn=cmd_exception)
    s = sub.add_parser("memory", help="compact memory (F6): compact|restore <scope|all>")
    s.add_argument("action", choices=["compact", "restore"])
    s.add_argument("scope")
    s.add_argument("--dry-run", action="store_true")
    s.set_defaults(fn=cmd_memory)
    s = sub.add_parser("bus", help="Event-Bus (F7): post|read|ack|import")
    s.add_argument("action", choices=["post", "read", "ack", "import"])
    s.add_argument("text", nargs="*")
    s.add_argument("--to", default="orchestrator")
    s.add_argument("--from", dest="sender", default="orchestrator")
    s.add_argument("--prio", choices=["crit", "warn", "info"])
    s.add_argument("--topic")
    s.add_argument("--key", help="dedupe key")
    s.add_argument("--limit", type=int, default=20)
    s.add_argument("--md", action="store_true", help="additionally write to inbox-<to>.md")
    s.set_defaults(fn=cmd_bus)
    s = sub.add_parser("lint", help="fair-play linter (F9) for Lua files/folders")
    s.add_argument("paths", nargs="+")
    s.set_defaults(fn=cmd_lint)
    s = sub.add_parser("budget", help="token budget per scope (F13)")
    s.set_defaults(fn=cmd_budget)
    s = sub.add_parser("overlay", help="short text for claude/schau say (F16), display only without --send")
    s.add_argument("text", nargs="*")
    s.add_argument("--send", action="store_true")
    s.set_defaults(fn=cmd_overlay)
    s = sub.add_parser("trade", help="trade automaton (F15): step|status|approve|reset")
    s.add_argument("action", choices=["step", "status", "approve", "reset"])
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--stable-s", default=2.0, help="seconds the focus has been stable (measured by the caller)")
    s.set_defaults(fn=cmd_trade)
    s = sub.add_parser("plan", help="planners (F11): blueprint|trade|dig|armor|supply")
    s.add_argument("kind", choices=["blueprint", "trade", "dig", "armor", "supply"])
    s.add_argument("files", nargs="*")
    s.add_argument("--json", help="trade: input {own:[...], offer:[...], ratio, reserves, max_weight}")
    s.add_argument("--area", help="dig: 'z x y w h' (live via claude/area)")
    s.add_argument("--area-file", help="dig: saved claude/area output")
    s.add_argument("--targets", help="dig: 'x,y[,prio];x,y;...'")
    s.add_argument("--picks", default=1)
    s.add_argument("--max-open", default=150)
    s.add_argument("--csv", action="store_true", help="dig: print the quickfort #dig CSV per batch")
    s.add_argument("--bars", help="armor: bars per metal, e.g. iron=32,bronze=31")
    s.add_argument("--prod", help="supply: production per day, e.g. drink=10,food=4")
    s.add_argument("--growth", type=float, default=None, help="supply: immigrants per day")
    s.add_argument("--map-size", help="blueprint: map size WxH (e.g. 192x192, claude/status map_size) -> E_BOUNDS check")
    s.add_argument("--origin", help="blueprint: quickfort cursor x,y (with --map-size: also the lower bound)")
    s.set_defaults(fn=cmd_plan)
    s = sub.add_parser("metrics", help="KPI time series as CSV (header like metrics.csv)")
    s.add_argument("--out")
    s.set_defaults(fn=cmd_metrics)
    return ap


EXTENSIONS: list = []   # M2/M3 commands register here (fn(sub))


def _utf8_streams() -> None:
    """BUG-112: on Windows a piped stdout uses the ANSI code page (cp1252); game text such as '\u263c' then aborts the
    command. Always write UTF-8 (unencodable characters are replaced, never fatal) and flush per line."""
    for s in (sys.stdout, sys.stderr):
        reconf = getattr(s, "reconfigure", None)
        if reconf is None:
            continue
        try:
            if (getattr(s, "encoding", "") or "").lower().replace("-", "") != "utf8":
                reconf(encoding="utf-8", errors="replace")
            else:
                reconf(errors="replace")
        except (ValueError, OSError, TypeError):
            pass


def _error_text(e: BaseException) -> str:
    """One line for an input/IO error (BUG-113): what went wrong and which file."""
    if isinstance(e, IsADirectoryError) or (isinstance(e, PermissionError) and e.filename
                                            and Path(str(e.filename)).is_dir()):
        return f"is a directory, expected a file: {e.filename}"
    if isinstance(e, FileNotFoundError) and e.filename:
        return f"file or folder not found: {e.filename}"
    if isinstance(e, FileExistsError) and e.filename:
        return f"cannot create, a file is in the way: {e.filename}"
    if isinstance(e, OSError) and e.filename:
        return f"{e.strerror or type(e).__name__}: {e.filename}"
    if isinstance(e, KeyError):
        return f"missing key {e}"
    text = str(e) or type(e).__name__
    return text if isinstance(e, (ValueError, OSError)) else f"{type(e).__name__}: {text}"


def _check_global_args(args) -> None:
    """BUG-103/BUG-120 D: an explicit --config / --mock / --replay-file must exist (no silent fallback to defaults)."""
    if args.config:
        c = Path(args.config)
        if c.is_dir():
            raise ValueError(f"--config is a directory, expected a file: {c}")
        if not c.is_file():
            raise ValueError(f"config file not found: {c}")
    if args.mock and not Path(args.mock).is_dir():
        raise ValueError(f"fixture folder not found: {args.mock}")
    if args.replay_file and not Path(args.replay_file).is_file():
        raise ValueError(f"replay file not found: {args.replay_file}")


def main(argv: list[str] | None = None) -> int:
    _utf8_streams()
    ap = build_parser()
    sub = next(a for a in ap._actions if isinstance(a, argparse._SubParsersAction))
    for ext in EXTENSIONS:
        ext(sub)
    from .features import modules as _features
    for mod in _features():
        if hasattr(mod, "register"):
            mod.register(sub)
    args = ap.parse_args(argv)
    if args.cmd == "kb" and args.action == "import" and args.query and not args.files:
        args.files = args.query
    debug = bool(os.environ.get("DF_LLM_HELPER_DEBUG"))
    try:
        _check_global_args(args)
        # BUG-104: --mock/--replay-file never touch the live state.db/tools folder. An explicit --config may still
        # choose its OWN paths (tests, private copies); paths equal to the live/default ones are replaced.
        force_overrides(mock_overrides(args.config) if (args.mock or args.replay_file) else None)
        return int(args.fn(args) or 0)
    except FairPlayError as e:
        print(f"FAIR PLAY: {e}", file=sys.stderr)
        return 3
    except KeyboardInterrupt:
        print("Interrupted", file=sys.stderr)
        return 130
    except (ValueError, KeyError, OSError, TypeError, AttributeError, IndexError) as e:
        # BUG-113: user/input/IO errors -> one line + exit 2 (traceback only with DF_LLM_HELPER_DEBUG=1)
        if debug:
            raise
        print(f"Error: {_error_text(e)}"[:500], file=sys.stderr)
        return 2
    finally:
        force_overrides(None)         # the mock isolation lives only for this call (tests call main() in-process)
