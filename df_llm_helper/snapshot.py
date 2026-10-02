"""State model (SPEC 5.2) and tolerant parser for the claude/* responses.

Missing/broken fields -> None, never an exception. Parse problems end up in Snapshot.errors.
"""
from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from typing import Any

from .client import SERVICES_CMD, DFClient, Result, parse_json_tolerant
from .clock import GameDate

__all__ = ["Snapshot", "Citizen", "Squad", "SquadMember", "Stocks", "JobsSummary", "Alerts", "Caravan",
           "WorkDetail", "parse_snapshot", "collect", "fixture_snapshot"]


@dataclass
class Citizen:
    id: int
    name: str = ""
    profession: str = ""
    job: str | None = None
    pos: tuple | None = None
    stress: str | None = None
    injured: bool = False
    child: bool = False
    skills: dict = field(default_factory=dict)
    work_details: list = field(default_factory=list)
    thirst: int | None = None
    hunger: int | None = None
    squad: str | None = None
    weapon: str | None = None

    @property
    def idle(self) -> bool:
        return not self.child and not self.job

    @property
    def has_pick(self) -> bool:
        return (self.weapon or "").lower() == "pick"


@dataclass
class SquadMember:
    id: int
    name: str
    weapon: str | None
    parts: int | None
    training: bool
    activity: str | None
    skills: str


@dataclass
class Squad:
    name: str
    members: list = field(default_factory=list)

    @property
    def size(self) -> int:
        return len(self.members)


@dataclass
class Stocks:
    drink: int | None = None
    food: int | None = None
    meals: int | None = None
    plants: int | None = None
    fish: int | None = None
    meat: int | None = None
    seeds: int | None = None
    wood: int | None = None
    boulders: int | None = None
    barrels: int | None = None
    barrels_empty: int | None = None
    bars: int | None = None
    cloth: int | None = None
    mood_gaps: list = field(default_factory=list)


@dataclass
class JobsSummary:
    open: int | None = None
    suspended: int | None = None
    dig: int | None = None
    by_type: dict = field(default_factory=dict)
    unfinished_buildings: int | None = None


@dataclass
class Caravan:
    name: str
    state: str
    time_remaining: int | None = None


@dataclass
class Alerts:
    enemies: int | None = None
    enemies_near: int | None = None
    danger_alarm: int | None = None
    civ_alert: int | None = None
    threats: list = field(default_factory=list)
    danger_top: list = field(default_factory=list)
    moods_active: list = field(default_factory=list)
    caravans: list = field(default_factory=list)
    status_alerts: list = field(default_factory=list)
    corpses_unburied: int | None = None
    stress_high: int | None = None
    refuge_ok: bool | None = None
    animal_corpses: int | None = None                         # claude/report kadaver_tiere_in_festung
    neg_thoughts: dict | None = None                          # claude/report negative_gedanken_top {name: count}


@dataclass
class WorkDetail:
    name: str
    mode: str
    members: list = field(default_factory=list)
    labors: list = field(default_factory=list)


@dataclass
class Snapshot:
    fort: str | None = None
    date: GameDate | None = None
    date_text: str | None = None
    paused: bool | None = None
    pop_total: int | None = None
    adults: int | None = None
    children: int | None = None
    idle: int | None = None
    drink_days: int | None = None
    food_days: int | None = None
    drinks_per_head: int | None = None
    wealth: int | None = None
    fps: float | None = None
    normal_fps: float | None = None
    timestream: bool | None = None
    slowmo: bool | None = None
    embark: tuple | None = None
    citizens: list = field(default_factory=list)
    squads: list = field(default_factory=list)
    stocks: Stocks = field(default_factory=Stocks)
    jobs: JobsSummary = field(default_factory=JobsSummary)
    alerts: Alerts = field(default_factory=Alerts)
    workdetails: list = field(default_factory=list)
    broker: dict | None = None
    services: dict = field(default_factory=dict)
    max_report_id: int | None = None
    full_stockpiles: list = field(default_factory=list)
    aquifer_z: list = field(default_factory=list)
    orders_total: int | None = None
    orders_unvalidated: int | None = None
    sources: list = field(default_factory=list)
    errors: list = field(default_factory=list)      # parser problems (unexpected format)
    failed: list = field(default_factory=list)      # failed queries

    # ---- derived values ----
    @property
    def idle_pct(self) -> float | None:
        if self.idle is None or not self.adults:
            return None
        return round(100.0 * self.idle / self.adults, 1)

    @property
    def game_id(self) -> str | None:
        # BUG-105: only a COMPLETE identity counts; a failed claude/config query (embark unknown) or a missing fort
        # name must not look like a different save ("NEW GAME" would wipe acks, loop protection and warnings).
        if not self.fort or not self.embark or len(self.embark) < 2 or None in self.embark[:2]:
            return None
        return f"{self.fort}|{self.embark[0]}|{self.embark[1]}"

    def hungry(self, limit: int) -> list:
        return [c for c in self.citizens if c.hunger is not None and c.hunger > limit]

    def thirsty(self, limit: int) -> list:
        return [c for c in self.citizens if c.thirst is not None and c.thirst > limit]

    def citizen(self, uid: int) -> Citizen | None:
        for c in self.citizens:
            if c.id == uid:
                return c
        return None

    def workdetail(self, name: str) -> WorkDetail | None:
        for w in self.workdetails:
            if w.name == name:
                return w
        return None

    @property
    def injured(self) -> list:
        return [c for c in self.citizens if c.injured]

    @property
    def miners(self) -> list:
        w = self.workdetail("Miners")
        return list(w.members) if w else []

    @property
    def diggers(self) -> int:
        return sum(1 for c in self.citizens if (c.job or "").lower() == "dig")

    @property
    def pick_holders(self) -> int:
        return sum(1 for s in self.squads for m in s.members if (m.weapon or "").lower() == "pick")

    @property
    def caravan_active(self) -> bool:
        return any(c.state not in ("", "Left", "Leaving", None) for c in self.alerts.caravans)

    @property
    def danger(self) -> bool:
        """Real danger: alarm, enemies near the fort, named threats. Hostiles far away (forgotten beasts in the
        caverns: 'enemies on the map' > 0 while claude/config reports feinde_nah = 0) are not a danger; only when the
        proximity is unknown (enemies_near is None) any enemy counts."""
        a = self.alerts
        if (a.danger_alarm or 0) > 0 or (a.enemies_near or 0) > 0 or a.threats:
            return True
        return a.enemies_near is None and (a.enemies or 0) > 0

    def facts(self) -> dict:
        """Flat key figures for delta/digest/metrics."""
        return {
            "fort": self.fort, "date": self.date_text, "pop": self.pop_total, "adults": self.adults,
            "idle": self.idle, "idle_pct": self.idle_pct, "drink_days": self.drink_days, "food_days": self.food_days,
            "drinks": self.stocks.drink, "meals": self.stocks.meals, "plants": self.stocks.plants,
            "jobs_open": self.jobs.open, "jobs_susp": self.jobs.suspended, "dig_jobs": self.jobs.dig,
            "enemies": self.alerts.enemies, "civ_alert": self.alerts.civ_alert, "fps": self.fps,
            "timestream": self.timestream, "wealth": self.wealth, "squad_members": sum(s.size for s in self.squads),
            "diggers": self.diggers, "moods": len(self.alerts.moods_active), "stress_high": self.alerts.stress_high,
            "paused": self.paused,
        }

    def to_dict(self) -> dict:
        d = asdict(self)
        d["date"] = [self.date.year, self.date.year_tick] if self.date else None
        return d


# ------------------------------------------------------------------ parser helpers

def _i(v: Any) -> int | None:
    try:
        if v is None or isinstance(v, bool):
            return None
        return int(float(v))
    except (TypeError, ValueError):
        return None


def _f(v: Any) -> float | None:
    try:
        if v is None or isinstance(v, bool):
            return None
        return float(v)
    except (TypeError, ValueError):
        return None


def _d(v: Any) -> dict:
    return v if isinstance(v, dict) else {}


def _l(v: Any) -> list:
    return v if isinstance(v, list) else []


def _short_name(full: str) -> str:
    return (full or "").split(" ")[0].strip('"') if full else ""


_SKILL = re.compile(r"([A-Z_]+):(\d+)")
_GEF = re.compile(r"^(\d+)\s+(.*)$")


def _parse_status(snap: Snapshot, j: dict) -> None:
    snap.fort = j.get("fort", snap.fort)
    date = _d(j.get("date"))
    if date:
        y, t = _i(date.get("year")), _i(date.get("year_tick"))
        if y is not None and t is not None:
            snap.date = GameDate(y, t)
        snap.date_text = date.get("text") or snap.date_text
    if isinstance(j.get("paused"), bool):
        snap.paused = j["paused"]
    snap.drink_days = _i(j.get("drink_days"))
    snap.food_days = _i(j.get("food_days"))
    snap.wealth = _i(j.get("wealth"))
    pop = _d(j.get("population"))
    snap.pop_total = _i(pop.get("total"))
    snap.adults = _i(pop.get("adults"))
    snap.children = _i(pop.get("children"))
    snap.idle = _i(pop.get("idle"))
    jobs = _d(j.get("jobs"))
    snap.jobs.open = _i(jobs.get("open"))
    snap.jobs.suspended = _i(jobs.get("suspended"))
    st = _d(j.get("stock"))
    s = snap.stocks
    s.drink = _i(st.get("drink"))
    s.food = _i(st.get("food"))
    s.seeds = _i(st.get("seeds"))
    s.wood = _i(st.get("wood"))
    s.boulders = _i(st.get("boulders"))
    s.barrels = _i(st.get("barrels"))
    s.bars = _i(st.get("bars"))
    s.cloth = _i(st.get("cloth"))
    snap.alerts.status_alerts = [str(a) for a in _l(j.get("alerts"))]
    snap.alerts.threats = [t for t in (_threat(a) for a in _l(j.get("threats"))) if t]


def _threat(t) -> str:
    """BUG-102: claude/status gives threats as {"n": 1, "name": "..."} (older versions: plain strings)."""
    if isinstance(t, dict):
        name = str(t.get("name") or t.get("race") or "").strip()
        n = _i(t.get("n"))
        if not name:
            return ""
        return f"{n}x {name}" if n and n > 1 else name
    return str(t).strip() if t is not None else ""


def _parse_report(snap: Snapshot, j: dict) -> None:
    snap.date_text = snap.date_text or j.get("datum")
    if snap.date is None and j.get("datum"):
        snap.date = GameDate.parse_text(j["datum"])
    snap.pop_total = snap.pop_total if snap.pop_total is not None else _i(j.get("buerger"))
    snap.adults = snap.adults if snap.adults is not None else _i(j.get("erwachsene"))
    snap.children = snap.children if snap.children is not None else _i(j.get("kinder"))
    if snap.idle is None:
        snap.idle = _i(j.get("erwachsene_ohne_auftrag"))
    s = snap.stocks
    s.drink = s.drink if s.drink is not None else _i(j.get("getraenke"))
    s.meals = _i(j.get("mahlzeiten"))
    s.plants = _i(j.get("pflanzen"))
    s.fish = _i(j.get("fisch"))
    s.meat = _i(j.get("fleisch"))
    s.barrels_empty = _i(j.get("leere_faesser"))
    s.mood_gaps = [str(x) for x in _l(j.get("stimmungsvorrat_luecken"))] or s.mood_gaps
    snap.drinks_per_head = _i(j.get("getraenke_pro_kopf"))
    snap.fps = _f(j.get("fps")) if snap.fps is None else snap.fps
    if isinstance(j.get("spiel_pausiert"), bool) and snap.paused is None:
        snap.paused = j["spiel_pausiert"]
    snap.jobs.dig = _i(j.get("grabjobs"))
    snap.full_stockpiles = [str(x) for x in _l(j.get("lager_voll"))]
    snap.jobs.unfinished_buildings = _i(j.get("unfertige_gebaeude"))
    for item in _l(j.get("jobs")):
        m = re.match(r"^(\w+)=(\d+)$", str(item))
        if m:
            snap.jobs.by_type[m.group(1)] = int(m.group(2))
    a = snap.alerts
    a.enemies = _i(j.get("feinde_auf_karte"))
    a.moods_active = [str(x) for x in _l(j.get("stimmungen_aktiv"))]
    a.corpses_unburied = _i(j.get("zwergenleichen_unbestattet"))
    a.animal_corpses = _i(j.get("kadaver_tiere_in_festung"))
    if "negative_gedanken_top" in j:
        neg = {}
        for x in _l(j.get("negative_gedanken_top")):
            m = re.match(r"^\s*([A-Za-z_]+)\s*=\s*(\d+)", str(x))
            if m:
                neg[m.group(1)] = int(m.group(2))
        a.neg_thoughts = neg
    a.stress_high = _i(j.get("hoher_stress"))
    if a.civ_alert is None:
        a.civ_alert = _i(j.get("zivilwarnung"))
    if isinstance(j.get("zeitlupe"), bool):
        snap.slowmo = j["zeitlupe"]
    # gefaehrdet: "414 durst=22303,hunger=47551"
    for g in _l(j.get("gefaehrdet")):
        m = _GEF.match(str(g).strip())
        if not m:
            snap.errors.append(f"report.gefaehrdet not readable: {g!r}")
            continue
        uid = int(m.group(1))
        vals = dict(re.findall(r"(\w+)=(\d+)", m.group(2)))
        c = snap.citizen(uid)
        if c is None:
            c = Citizen(id=uid)
            snap.citizens.append(c)
        if "durst" in vals:
            c.thirst = int(vals["durst"])
        if "hunger" in vals:
            c.hunger = int(vals["hunger"])


def _parse_units(snap: Snapshot, j: dict) -> None:
    for u in _l(j.get("units")):
        if not isinstance(u, dict) or _i(u.get("id")) is None:
            continue
        uid = _i(u["id"])
        c = snap.citizen(uid)
        if c is None:
            c = Citizen(id=uid)
            snap.citizens.append(c)
        full = str(u.get("name") or "")
        c.name = _short_name(full)
        c.profession = str(u.get("profession") or "")
        c.job = u.get("job") or None
        pos = u.get("pos")
        c.pos = tuple(pos) if isinstance(pos, list) and len(pos) == 3 else None
        c.stress = u.get("stress")
        c.injured = bool(u.get("injured", False))
        c.child = bool(u.get("child", False))
        c.skills = {k: int(v) for k, v in _SKILL.findall(str(u.get("skills") or ""))}
        wd = str(u.get("work_details") or "")
        c.work_details = [w.strip() for w in wd.split(",") if w.strip()]


def _parse_mil_tabelle(snap: Snapshot, text: str) -> None:
    squads: dict[str, Squad] = {}
    for line in text.splitlines():
        if " | " not in line or line.startswith("Trupp |"):
            continue
        parts = [p.strip() for p in line.split("|")]
        if len(parts) < 7:
            snap.errors.append(f"mil tabelle: incomplete line: {line[:60]!r}")
            continue
        sq, uid, name, weapon, teile, training, skills = parts[:7]
        uid_i = _i(uid)
        if uid_i is None:
            continue
        m = re.match(r"(\d+)/(\d+)", teile)
        act = re.search(r"\(([^()]*)\)\s*$", training)
        member = SquadMember(id=uid_i, name=name, weapon=None if weapon in ("-", "") else weapon,
                             parts=int(m.group(1)) if m else None, training=training.startswith("ja"),
                             activity=(act.group(1) if act and act.group(1) != "-" else None), skills=skills)
        squads.setdefault(sq, Squad(sq)).members.append(member)
        c = snap.citizen(uid_i)
        if c is not None:
            c.squad, c.weapon = sq, member.weapon
    snap.squads = list(squads.values())


def _parse_config(snap: Snapshot, j: dict) -> None:
    emb = _d(j.get("embark"))
    if emb:
        snap.embark = (_i(emb.get("year")), _i(emb.get("tick")))
    if snap.fps is None:
        snap.fps = _f(j.get("fps_ist"))
    snap.normal_fps = _f(j.get("normal_fps"))
    if isinstance(j.get("timestream"), bool) and snap.timestream is None:
        snap.timestream = j["timestream"]
    if isinstance(j.get("slowmo_aktiv"), bool):
        snap.slowmo = j["slowmo_aktiv"]
    if snap.alerts.enemies_near is None:
        snap.alerts.enemies_near = _i(j.get("feinde_nah"))
    snap.aquifer_z = sorted({_i(z) for z in _l(j.get("aquifer_confirmed")) + _l(j.get("aquifer_gesehen_z"))
                             if _i(z) is not None})


def _parse_tempo(snap: Snapshot, j: dict) -> None:
    if isinstance(j.get("timestream"), bool):
        snap.timestream = j["timestream"]
    snap.alerts.civ_alert = _i(j.get("civ_alert_idx")) if j.get("civ_alert_idx") is not None else snap.alerts.civ_alert
    if _f(j.get("enabler_fps")) is not None:
        snap.fps = _f(j.get("enabler_fps"))
    snap.services["tempo"] = {"manual_off": j.get("manuell_aus"), "reason_off": j.get("grund_aus"),
                              "watchdog_alert": j.get("watchdog_alert"), "target_fps": _f(j.get("ziel_fps"))}


def _parse_gefahr(snap: Snapshot, j: dict) -> None:
    a = snap.alerts
    a.danger_alarm = _i(j.get("alarm"))
    if j.get("civ_alert_idx") is not None:
        a.civ_alert = _i(j.get("civ_alert_idx"))
    a.danger_top = [str(t) for t in _l(j.get("top"))]
    ref = _d(j.get("refuge"))
    if "ok" in ref:
        a.refuge_ok = bool(ref.get("ok"))


def _parse_mood(snap: Snapshot, j: dict) -> None:
    moods = _l(j.get("stimmungen"))
    if moods:
        snap.alerts.moods_active = [m if isinstance(m, str) else str(m.get("name") or m) for m in moods]
    gaps = _l(j.get("luecken"))
    if gaps:
        snap.stocks.mood_gaps = [str(g) for g in gaps]


def _parse_handel(snap: Snapshot, j: dict) -> None:
    snap.alerts.caravans = [Caravan(name=str(c.get("name") or "?"), state=str(c.get("state") or ""),
                                    time_remaining=_i(c.get("time_remaining")))
                            for c in _l(j.get("caravans")) if isinstance(c, dict)]
    if isinstance(j.get("broker"), dict):
        snap.broker = j["broker"]


def _parse_workdetail(snap: Snapshot, j: dict) -> None:
    snap.workdetails = [WorkDetail(name=str(d.get("name")), mode=str(d.get("mode") or ""),
                                   members=[_i(m) for m in _l(d.get("members")) if _i(m) is not None],
                                   labors=[str(x) for x in _l(d.get("labors"))])
                        for d in _l(j.get("details")) if isinstance(d, dict)]


def _parse_orders(snap: Snapshot, j: dict) -> None:
    orders = [o for o in _l(j.get("orders")) if isinstance(o, dict)]
    snap.orders_total = len(orders)
    snap.orders_unvalidated = sum(1 for o in orders if o.get("validated") is False)


def _parse_service(snap: Snapshot, name: str, j: dict) -> None:
    if "running" in j:
        snap.services[name] = {"running": bool(j.get("running"))}


_PARSERS = {
    "claude/status": _parse_status,
    "claude/report": _parse_report,
    "claude/units": _parse_units,
    "claude/config": _parse_config,
    "claude/tempo status": _parse_tempo,
    "claude/gefahr status": _parse_gefahr,
    "claude/mood status": _parse_mood,
    "claude/handel status": _parse_handel,
    "claude/workdetail list": _parse_workdetail,
    "claude/orders status": _parse_orders,
}
# order: units before report (names), status before report; mil tabelle after units
_ORDER = ["claude/status", "claude/units", "claude/report", "claude/mil tabelle", "claude/config",
          "claude/tempo status", "claude/gefahr status", "claude/mood status", "claude/handel status",
          "claude/workdetail list"]
_SERVICE = re.compile(r"^claude/(watchdog|arbeit|trinken|ueberwacher|essen|orders|gesund|auslastung|material) status$")


def parse_snapshot(results: dict[str, Result | str]) -> Snapshot:
    """results: command -> Result or raw text. Never raises."""
    snap = Snapshot()
    norm: dict[str, Result] = {}
    for cmd, r in results.items():
        norm[cmd] = r if isinstance(r, Result) else Result.make(cmd, True, str(r))
    order = [c for c in _ORDER if c in norm] + [c for c in norm if c not in _ORDER]
    for cmd in order:
        r = norm[cmd]
        if not r.ok:
            snap.failed.append(f"{cmd[:40]}: {(r.stderr or 'error').strip()[:80]}")
            continue
        try:
            if cmd == "claude/mil tabelle":
                _parse_mil_tabelle(snap, r.stdout)
                snap.sources.append(cmd)
                continue
            if cmd == SERVICES_CMD:
                for k, v in re.findall(r"claude-([\w-]+)=(true|false)", r.stdout):
                    snap.services.setdefault(k, {})["running"] = (v == "true")
                snap.sources.append(cmd)
                continue
            if cmd.startswith('lua "local r=df.global.world.status.reports'):
                snap.max_report_id = _i(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else None)
                snap.sources.append(cmd)
                continue
            j = r.json if r.json is not None else parse_json_tolerant(r.stdout)
            if not isinstance(j, dict):
                snap.errors.append(f"{cmd}: no JSON object")
                continue
            m = _SERVICE.match(cmd)
            if m:
                _parse_service(snap, m.group(1), j)
            elif cmd in _PARSERS:
                _PARSERS[cmd](snap, j)
            else:
                continue
            snap.sources.append(cmd)
        except Exception as e:  # tolerance: never abort
            snap.errors.append(f"{cmd}: parser error {type(e).__name__}: {e}")
    return snap


def collect(client: DFClient, commands: list[str], timeout: float = 40.0) -> Snapshot:
    """One call set (run_many) -> snapshot."""
    res = client.run_many(list(commands), timeout=timeout)
    return parse_snapshot({c: r for c, r in zip(commands, res)})


def fixture_snapshot(path) -> Snapshot:
    from .client import MockClient
    from .config import DEFAULTS
    mc = MockClient.from_fixture_dir(path)
    return collect(mc, DEFAULTS["collect"]["commands"])
