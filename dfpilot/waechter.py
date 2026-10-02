"""Real-time watcher in Python - replaces tools/unpause-guard.ps1 (the player asked to replace the PowerShell watcher
and keep only the deadman brake of dfpilot). Logic taken 1:1 from unpause-guard.ps1, NOT TESTED LIVE:

 1. new game reports (world.status.reports) -> tools/events.log ('CRITICAL'/'info' HH:MM:SS [TYPE] text)
 2. report ID reset on a new game (maxId < last) -> last-report-id.txt
 3. caravan arrived -> caravan.flag + pause.hold 'karawane' + claude/advance 0
    (the pause.hold texts 'karawane'/'alarm'/'gefahr...' are shared with the Lua companion scripts and stay German)
 4. critical report (same type at most every 300 s) -> alert.flag (counts as open for 60 s only);
    siege/ambush/undead -> siege.flag; real enemies -> pause.hold 'alarm' + pause + civilian alert + tempo suspend
 5. supplies every ~10 s (at the earliest 3 min after the last alarm): meals+meat+fish < 25 or drinks < 40 -> food.flag
 6. pause.hold 'gefahr...' older than 20 min -> delete pause.hold + alert.flag
 7. deadman/watcher self-check: dfpilot guard (guard.py) every ~30 s, without a snapshot (only files + report IDs)
 8. dismiss message windows; lift the pause if there is no pause.hold/alert.flag and focus is dwarfmode/Default
 9. spec v3-04 (freeze_guard.py): game time stands still (frame counter + year tick unchanged for 3 ticks) while an
    Info/Help/MessageBox/... window is on top -> simulated LEAVESCREEN/SELECT like a player; trade aftercare after
    trade.flow == DONE (pause.hold 'karawane' + caravan.flag + MessageBox); never during SELECT_LIVE/CONFIRM/FINISH
10. spec v3-03 (features/perf.py): latency of the light queries -> LatencyMonitor -> perf.flag after >= 5 outliers in
    5 min; services a crashed `perf bisect` left switched off are restarted when their deadline has passed
Heartbeat: tools/out/waechter.alive (the guard checks it instead of the PowerShell process).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

from .client import MAX_REPORT_ID_CMD
from .features.perf import LatencyMonitor, digest_line, recover as perf_recover, state_path as perf_state_path
from . import freeze_guard as fg

__all__ = ["Waechter", "reports_cmd", "CRITICAL", "INFO", "ENEMY", "SIEGE", "FOOD_CMD", "CLEAR_CMD", "UNPAUSE_RE"]

CRITICAL = re.compile(r"(ambush|siege|invader|invasion|thief|thieves|snatcher|kidnap|titan|demon|werebeast|undead|zombie|"
                      r"vampire|berserk|tantrum|insane|went mad|has been found dead|has been killed|been slain|struck down|"
                      r"starv|dehydrat|cave-in|collapse|flood|on fire|fire!|magma|plague|epidemic|goblin|elves|"
                      r"humans arrive|army|enemy)", re.I)
INFO = re.compile(r"(migrant|caravan|merchant|liaison|diplomat|strange mood|artifact|is now (spring|summer|autumn|winter)|"
                  r"has arrived|married|has given birth|grown to become)", re.I)
NOT_ALARM = re.compile(r"COMBAT|CANCEL_JOB|TANTRUM|PET_DEATH|EXHAUSTION|ERA_CHANGE|MISCHIEVOUS|MASTERPIECE|SHOOT_WEB|"
                       r"BREATHE_FIRE")
SIEGE = re.compile(r"(siege|vile force|force of darkness|UNDEAD_ATTACK|AMBUSH|ambush)")
ENEMY = re.compile(r"(ambush|siege|invader|invasion|thief|thieves|snatcher|kidnap|titan|demon|werebeast|undead|zombie|"
                   r"vampire|goblin|elves|humans arrive|army|enemy|berserk|insane|went mad)", re.I)

FOOD_CMD = ('lua "local it=df.global.world.items.other local function c(v) local n=0 for _,i in ipairs(v) do '
            "local f=i.flags if not (f.forbid or f.rotten or f.dump or f.trader) then n=n+i:getStackSize() end end "
            "return n end print('S '..c(it.FOOD)..' '..c(it.MEAT)..' '..c(it.FISH)..' '..c(it.DRINK)..' '..c(it.PLANT))\"")
CLEAR_CMD = ('lua "local p=df.global.world.status.popups local n=#p while #p>0 do local x=p[#p-1] p:erase(#p-1) '
             "x:delete() end print((df.global.pause_state and 'P' or 'R')..' '..n..' '..table.concat("
             "dfhack.gui.getCurFocus(true),'|')..' fc='..df.global.world.frame_counter..' yt='..df.global.cur_year_tick)\"")
# pause lifted only on the plain map; the trailing frame counter/year tick (spec v3-04) is optional for older output
UNPAUSE_RE = re.compile(r"^P \d+ dwarfmode/Default(?: fc=\d+)?(?: yt=\d+)?$")
CARAVANS_CMD = 'lua "print(#df.global.plotinfo.caravans)"'


def reports_cmd(last: int) -> str:
    return (f'lua "local last={int(last)} local r=df.global.world.status.reports local out={{}} for i=#r-1,0,-1 do '
            "local x=r[i] if x.id<=last then break end out[#out+1]=x.id..'|'..(df.announcement_type[x.type] or x.type)"
            "..'|'..x.year..'.'..x.time..'|'..dfhack.df2utf(x.text) if #out>=60 then break end end for i=#out,1,-1 do "
            'print(out[i]) end"')


@dataclass
class Waechter:
    client: object
    tools: object
    clock: object
    store: object
    cfg: dict
    seen: dict = field(default_factory=dict)       # report type -> last alarm time
    tick: int = 0
    next_food: float = 0.0
    last: int | None = None
    log: list = field(default_factory=list)
    freeze: object = None                          # freeze_guard.FreezeGuard (spec v3-04)
    perf: object = None                            # features.perf.LatencyMonitor (spec v3-03)

    def __post_init__(self) -> None:
        if self.freeze is None:
            self.freeze = fg.FreezeGuard(self.cfg.get("freeze_guard") or {})
            done = self.store.get(f"{fg.RULE}.aftercare_since")
            self.freeze.aftercare_done = done
        if self.perf is None:
            self.perf = LatencyMonitor(self.cfg.get("perf") or {})

    # ---- helpers
    def _hold(self, text: str) -> None:
        p = self.tools.path / "pause.hold"
        p.write_text(text, encoding="utf-8")

    def _event(self, level: str, text: str, tag: str = "GUARD") -> None:
        self.log.append(self.tools.append_event(level, text, tag))

    def _int(self, out: str) -> int | None:
        s = (out or "").strip().splitlines()
        return int(s[-1]) if s and re.match(r"^-?\d+$", s[-1].strip()) else None

    def _alive(self) -> None:
        d = self.tools.path / "out"
        d.mkdir(parents=True, exist_ok=True)
        (d / "waechter.alive").write_text(self.clock.now().iso(), encoding="utf-8")

    def _q(self, cmd: str):
        """Light query with latency measurement (spec v3-03 auto detection)."""
        t0 = self.clock.now().epoch
        res = self.client.run(cmd)
        self.perf.add(t0, max(float(res.elapsed_s or 0.0), self.clock.now().epoch - t0))
        return res

    def _perf_check(self, now: float) -> None:
        if perf_state_path(self.tools).exists():
            for ln in perf_recover(self.client, self.tools, self.store, self.clock, overdue_only=True):
                self._event("CRITICAL", ln)
        if not self.perf.should_flag(now) or self.tools.flag("perf").exists:
            return
        pc = self.cfg.get("perf") or {}
        if self.store.count_actions("perf", "perf_flag", now - 60 * float(pc.get("flag_repeat_min", 30))):
            return
        line = digest_line(self.perf.stats(now))
        self.tools.write_flag("perf", line)
        self.store.set("perf.auto", {**self.perf.stats(now), "ts": now})
        self.store.log_action(now, "waechter", "perf", "perf_flag", "perf.flag", "", False, True, line)
        self._event("CRITICAL", line, "PERF")

    def _freeze_check(self, o: str) -> None:
        fcfg = {**fg.CFG_DEFAULTS, **(self.cfg.get("freeze_guard") or {})}
        if not fcfg.get("enabled", True):
            return
        obs = fg.parse_status(o)
        if obs is None:
            return
        now = self.clock.now().epoch
        ctx = fg.ctx_from(self.store, self.tools, now)
        d = self.freeze.decide(obs, now, ctx)
        if d.kind != "none":
            fg.apply(d, self.freeze, ctx, client=self.client, tools=self.tools, store=self.store, clock=self.clock,
                     event=self._event)

    # ---- one pass (ps1: while loop, 2 s)
    def step(self) -> list[str]:
        self.log = []
        now = self.clock.now().epoch
        self._alive()
        if self.last is None:
            self.last = self.tools.last_report_id() or 0
            if self.last <= 0:
                self.last = self._int(self.client.run(MAX_REPORT_ID_CMD).stdout) or 0
        mx = self._int(self._q(MAX_REPORT_ID_CMD).stdout)
        if mx is not None and mx >= 0 and mx < self.last:
            self.last = mx
            self.tools.set_last_report_id(mx)
            self._event("info", f"Report ID reset (new game): {mx}")
        res = self.client.run(reports_cmd(self.last))
        new = [ln for ln in res.stdout.splitlines() if re.match(r"^\d+\|", ln)] if res.ok else []
        crit: list[str] = []
        for ln in new:
            p = ln.split("|", 3)
            if len(p) < 4:
                continue
            typ, text = p[1], re.sub(r"goblin-cap|goblin cap", "fungus-cap", p[3]).strip()
            rid = int(p[0])
            self.last = max(self.last, rid)
            hay = f"{typ} {text}"
            tag = "CRITICAL" if CRITICAL.search(hay) else ("info" if INFO.search(hay) else "")
            if tag:
                self.log.append(self.tools.append_event(tag, text, typ))
            line = f"{self.clock.now().local().strftime('%H:%M:%S')} [{typ}] {text}"
            if "CARAVAN_ARRIVAL" in typ:
                n = self._int(self.client.run(CARAVANS_CMD).stdout) or 0
                if n > 0 and not self.tools.flag("caravan").exists:
                    self.tools.write_flag("caravan", line)
                    self._hold("karawane")
                    self.client.run("claude/advance 0")
            if tag == "CRITICAL" and not NOT_ALARM.search(typ):
                if now - self.seen.get(typ, -1e18) > 300:
                    self.seen[typ] = now
                    crit.append(line)
        if new:
            self.tools.set_last_report_id(self.last)
        alert = self.tools.flag("alert")
        alert_open = alert.exists and alert.age_min is not None and alert.age_min * 60 < 60
        if crit and not alert_open:
            body = "\n".join(crit[:6])
            self.tools.write_flag("alert", body)
            joined = " ".join(crit)
            if SIEGE.search(joined) and not self.tools.flag("siege").exists:
                self.tools.write_flag("siege", body)
            if ENEMY.search(joined):
                self._hold("alarm")
                for c in ("claude/advance 0", "claude/alert on", "claude/tempo suspend"):
                    self.client.run(c)
            else:
                self._event("info", "Alert flag without pause (no enemy)")
        # supplies
        self.tick += 1
        if self.tick % 5 == 1 and not self.tools.flag("food").exists and now > self.next_food:
            out = self.client.run(FOOD_CMD).stdout
            m = re.search(r"S (\d+) (\d+) (\d+) (\d+) (\d+)", out or "")
            if m:
                eat = int(m.group(1)) + int(m.group(2)) + int(m.group(3))
                if eat < 25 or int(m.group(4)) < 40:
                    self.tools.write_flag("food", f"Supplies low: meals+meat+fish={eat}, drinks={m.group(4)}, "
                                                  f"plants={m.group(5)} ({self.clock.now().local().strftime('%H:%M:%S')})")
                    self.next_food = now + 180
        # 'gefahr' pause expires after 20 min
        hold = self.tools.flag("pause.hold")
        if hold.exists and (hold.age_min or 0) > 20 and hold.text.startswith("gefahr"):
            self.tools.delete_flag("pause.hold")
            self.tools.delete_flag("alert")
            self._event("info", "danger pause expired after 20 min (pause.hold/alert.flag deleted)")
        # deadman + watcher self-check (dfpilot guard) about every 30 s
        if self.tick % 15 == 1:
            from .guard import GuardRunner
            GuardRunner(self.client, self.store, self.tools, self.clock, self.cfg).cycle(None)
        # dismiss windows, lift the pause
        o = (self._q(CLEAR_CMD).stdout or "").strip().splitlines()
        o = o[-1].strip() if o else ""
        if not self.tools.flag("pause.hold").exists and not self.tools.flag("alert").exists and UNPAUSE_RE.match(o):
            self.client.run("claude/advance run")
        # time stands still although not paused (Info/Help/MessageBox on top) + trade aftercare (spec v3-04)
        self._freeze_check(o)
        self._perf_check(now)
        return self.log
