"""Spec 03: mood manager (`python -m df_llm_helper mood`).

Reads the REAL demand of a strange mood (job elements via `claude/pilot_mood need <id>`), decodes NONE elements
via the set job_item flags, checks free/bound stock, fixes gaps through maintenance (releasing CutGems jobs)
and warns in time ("will fail"). No item creation or moving.
Running moods come from `claude/mood status` (field `stimmungen`) or tools/out/mood.log lines.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field

__all__ = ["MoodCase", "Element", "parse_mood_log_line", "decode_none", "case_from_need", "analyse", "MoodManager",
           "reserve_gaps", "reserve_wants", "DEFAULTS", "FLAG_HINTS"]

DEFAULTS = {"reserves": {"wood": 14, "cut_gems": 10, "rough_gems": 12, "bone": 5, "leather": 3, "metal": 3,
                          "cloth": 3, "stone": 5, "silk": 2},
            "release_cutgems": True, "warn_timeout_ticks": 8000, "ticks_per_tile": 12, "work_ticks": 3000,
            "min_pop_reserve": 20, "max_releases_per_hour": 2, "fail_reserve_bump": 2}
# config key (spec, English) -> category in `claude/mood status` (vorrat)
RESERVE_KEYS = {"wood": "holz", "cut_gems": "schliffgem", "rough_gems": "rohgem", "bone": "knochen",
                "leather": "leder", "metal": "metall", "cloth": "stoff", "stone": "stein", "silk": "seide"}
SKILL_RESERVE = {"CARPENTRY": "wood", "WOODCRAFT": "wood", "BOWYER": "wood", "CUTGEM": "rough_gems",
                 "ENCRUSTGEM": "cut_gems", "BONECARVE": "bone", "LEATHERWORK": "leather", "TANNER": "leather",
                 "METALCRAFT": "metal", "FORGE_WEAPON": "metal", "FORGE_ARMOR": "metal", "FORGE_FURNITURE": "metal"}

# job_item flag (DFHack field name) -> material category (for NONE elements)
FLAG_HINTS = {
    "bone": "bone", "shell": "shell", "horn": "horn", "pearl": "pearl", "ivory_tooth": "ivory/tooth",
    "leather": "leather", "silk": "silk", "plant": "plant fiber", "yarn": "wool", "cloth": "cloth",
    "metal": "metal", "glass": "glass", "wood": "wood", "hard": "hard stone", "gem": "gem",
    "totemable": "skull", "body_part": "body part", "any_raw_material": "raw material",
    "non_economic": "stone (non-economic)",
}
# item_type -> category for reports/trade (keys index `claude/mood status` data; German keys kept)
TYPE_CAT = {"WOOD": "holz", "ROUGH": "rohgem", "SMALLGEM": "schliffgem", "BAR": "metall", "BOULDER": "stein",
            "BLOCKS": "stein", "CLOTH": "stoff", "SKIN_TANNED": "leder", "THREAD": "faden", "CORPSEPIECE": "knochen"}
# display text for the category keys above
CAT_LABEL = {"holz": "wood", "rohgem": "rough gems", "schliffgem": "cut gems", "metall": "metal", "stein": "stone",
             "stoff": "cloth", "leder": "leather", "faden": "thread", "knochen": "bone", "seide": "silk"}

_LOG = re.compile(r"id=(\d+) mood=(\S+) skill=(\S+) .*?timeout=(\d+) need=(\S*)")


@dataclass
class Element:
    item_type: str
    quantity: int
    free: int | None = None
    bound: int | None = None
    nearest: int | None = None
    flags: list = field(default_factory=list)
    decoded: str | None = None
    held: int = 0            # already attached to the mood job itself (picked up / on the way): not 'missing'


@dataclass
class MoodCase:
    id: int
    mood: str = ""
    skill: str = ""
    timeout: int | None = None
    elements: list = field(default_factory=list)
    thirst: int | None = None


def parse_mood_log_line(line: str) -> MoodCase | None:
    """Line from tools/out/mood.log (claude/mood watch) -> MoodCase (rough demand, no stock)."""
    m = _LOG.search(line)
    if not m:
        return None
    els = []
    for part in m.group(5).split(","):
        mm = re.match(r"^([A-Z_?]+)x(\d+)$", part)
        if mm:
            els.append(Element(mm.group(1), int(mm.group(2))))
    return MoodCase(int(m.group(1)), m.group(2), m.group(3), int(m.group(4)), els)


def decode_none(flags: list[str]) -> str:
    """Interpret a NONE element via its set flags; never silently empty -> 'unknown(<flags>)'."""
    hits = [FLAG_HINTS[f] for f in flags if f in FLAG_HINTS]
    if hits:
        return "/".join(sorted(set(hits)))
    return "unknown(" + (",".join(sorted(flags)) or "no flags") + ")"


def case_from_need(j: dict) -> MoodCase | None:
    if not isinstance(j, dict) or not j.get("ok"):
        return None
    els = []
    for e in j.get("elements") or []:
        if not isinstance(e, dict):
            continue
        flags = list(e.get("flags1") or []) + list(e.get("flags2") or []) + list(e.get("flags3") or [])
        el = Element(str(e.get("item_type") or "?"), int(e.get("quantity") or 1), e.get("free"), e.get("bound"),
                     e.get("nearest"), flags, held=int(e.get("held") or 0))
        if el.item_type == "NONE":
            el.decoded = decode_none(flags)
        els.append(el)
    return MoodCase(int(j.get("id") or -1), str(j.get("mood") or ""), "", j.get("timeout"), els, j.get("thirst"))


def analyse(case: MoodCase, cfg: dict) -> dict:
    """-> {'gaps', 'release_cutgems', 'wood_missing', 'will_fail', 'est_ticks', 'notes'}.

    Demand is summed per item_type (DF creates e.g. ROUGHx1, ROUGHx1 as two elements); free/bound/nearest
    are returned by pilot_mood per element for the whole type, so evaluate once per type.
    """
    c = {**DEFAULTS, **(cfg or {})}
    gaps, notes = [], []
    need: dict[str, int] = {}
    held: dict[str, int] = {}
    stock: dict[str, Element] = {}
    for el in case.elements:
        if el.item_type == "NONE":
            notes.append(f"Demand NONE x{el.quantity} interpreted as: {el.decoded or decode_none(el.flags)}")
            if not el.decoded:
                el.decoded = decode_none(el.flags)
            if el.decoded.startswith("unknown"):
                gaps.append(f"{el.decoded} x{el.quantity} (not decodable, check by hand)")
            continue
        # quantities >= 100 are cloth/thread units (CLOTHx20000) -> only check 'available?' (1 piece)
        need[el.item_type] = need.get(el.item_type, 0) + (el.quantity if el.quantity < 100 else 1)
        held[el.item_type] = held.get(el.item_type, 0) + el.held
        stock.setdefault(el.item_type, el)
    release = wood = False
    worst = 0
    for t, n in need.items():
        el = stock[t]
        if el.free is None:
            continue
        label = CAT_LABEL.get(TYPE_CAT.get(t, ""), t.lower())
        # material the mood job already holds (item attached to the job, so 'in_job' and never 'free') is not missing:
        # otherwise a mood that has picked up its wood reports 'wood missing' and boosts trade / blocks charcoal for nothing
        have = el.free + held.get(t, 0)
        if have < n:
            short = n - have
            gaps.append(f"{label} missing {short} (need {n}, free {el.free}"
                        + (f", held by the mood {held[t]}" if held.get(t) else "") + f", bound {el.bound or 0})")
            if t == "ROUGH" and (el.bound or 0) >= short and c["release_cutgems"]:
                release = True
            if t == "WOOD":
                wood = True
        if el.nearest is not None:
            worst = max(worst, el.nearest)
    est = worst * 2 * c["ticks_per_tile"] + c["work_ticks"]
    will_fail = case.timeout is not None and (case.timeout < est or (bool(gaps) and case.timeout < c["warn_timeout_ticks"]))
    return {"gaps": gaps, "release_cutgems": release, "wood_missing": wood, "will_fail": bool(will_fail),
            "est_ticks": est, "notes": notes}


def reserve_wants(cfg: dict, minimum: dict | None = None) -> tuple[dict, str]:
    """Reserve per category (`claude/mood status` names) and its source. BUG-220 (player delegated the decision): the
    game script's `minimum` (lua/claude/mood.lua) is authoritative; `mood.reserves` in the config is the fallback for
    an unreadable answer and for categories the script does not list."""
    c = {**DEFAULTS, **(cfg or {})}
    wants = {RESERVE_KEYS.get(k, k): int(v) for k, v in (c["reserves"] or {}).items()}
    used = False
    for cat, v in (minimum or {}).items() if isinstance(minimum, dict) else ():
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            wants[str(cat)] = int(v)
            used = True
    return wants, ("claude/mood minimum" if used else "config mood.reserves")


def reserve_gaps(vorrat: dict, pop: int | None, cfg: dict, extra: dict | None = None,
                 minimum: dict | None = None) -> list[str]:
    """Prevention: from pop >= min_pop_reserve on, check the stock (claude/mood status 'vorrat') against the reserves
    (`minimum` of claude/mood status when given, else config mood.reserves; see reserve_wants).
    extra = surcharges after failed moods (kv mood.reserve_extra, keyed by config name)."""
    c = {**DEFAULTS, **(cfg or {})}
    if pop is None or pop < c["min_pop_reserve"] or not isinstance(vorrat, dict):
        return []
    wants, _ = reserve_wants(c, minimum)
    extra_cat = {RESERVE_KEYS.get(k, k): int(v) for k, v in (extra or {}).items()}
    out = []
    for cat in sorted(wants, key=lambda x: CAT_LABEL.get(x, x)):
        want = wants[cat] + extra_cat.get(cat, 0)
        have = int(vorrat.get(cat) or 0)
        if have < want:
            out.append(f"{CAT_LABEL.get(cat, cat)} {have}/{want}")
    return out


class MoodManager:
    """One call = one check of all running moods (+ aftercare). State kv 'mood.seen'."""

    def __init__(self, client, tools, store, clock, cfg: dict):
        self.client, self.tools, self.store, self.clock = client, tools, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}

    def status(self) -> dict:
        r = self.client.run("claude/mood status")
        return r.json if isinstance(r.json, dict) else {}

    def _aftercare(self, j: dict, now: float, dry: bool) -> list[str]:
        out = []
        seen = dict(self.store.get("mood.seen") or {})
        cur = {str(m["id"]): m for m in j.get("stimmungen") or [] if isinstance(m, dict) and m.get("id") is not None}
        for uid, m in cur.items():
            if m.get("insane") and not (seen.get(uid) or {}).get("failed"):
                skill = str(m.get("skill") or (seen.get(uid) or {}).get("skill") or "")
                gaps = (self.store.get("mood.gaps") or {}).get(uid) or []
                out.append(f"Mood {uid} FAILED ({m.get('mood')}): berserk danger, keep civilians away"
                           + (f"; gaps: {', '.join(gaps)}" if gaps else ""))
                if not dry:
                    self.store.warn(now, "mood", f"mood:insane:{uid}", out[-1], "crit")
                    key = SKILL_RESERVE.get(skill)
                    if key:
                        extra = dict(self.store.get("mood.reserve_extra") or {})
                        extra[key] = int(extra.get(key, 0)) + int(self.cfg["fail_reserve_bump"])
                        self.store.set("mood.reserve_extra", extra)
                        out.append(f"Reserve {key} raised by {self.cfg['fail_reserve_bump']}")
                seen[uid] = {"skill": skill, "failed": True}
            elif uid not in seen:
                seen[uid] = {"skill": str(m.get("skill") or ""), "failed": False}
        gone = [u for u in seen if u not in cur]
        live = [u for u, m in cur.items() if not m.get("insane")]
        if not dry:
            for u in gone:
                seen.pop(u)
            self.store.set("mood.seen", seen)
            if not live:
                if self.store.get("mood.block_charcoal"):
                    self.store.set("mood.block_charcoal", False)
                boost = [b for b in (self.store.get("trade.boost") or []) if b != "wood"]
                if gone and boost != (self.store.get("trade.boost") or []):
                    self.store.set("trade.boost", boost)
                if not cur and self.tools.flag("mood").exists:      # berserk/insanity: flag stays
                    self.tools.delete_flag("mood")
                    out.append("no mood active any more: mood.flag deleted")
        return out

    def check(self, *, dry: bool = False) -> list[str]:
        now = self.clock.now().epoch
        j = self.status()
        out = self._aftercare(j, now, dry)
        ids = [int(m["id"]) for m in j.get("stimmungen") or []
               if isinstance(m, dict) and m.get("id") is not None and not m.get("insane")]
        if not ids:
            return (out or ["no running mood"])[:6]
        for uid in ids:
            case = case_from_need(self.client.run(f"claude/pilot_mood need {uid}").json)
            if case is None:
                out.append(f"Mood {uid}: demand not readable (claude/pilot_mood installed?)")
                continue
            res = analyse(case, self.cfg)
            if not dry:                                   # for aftercare/journal (spec 12): latest gaps per mood
                gs = dict(self.store.get("mood.gaps") or {})
                gs[str(uid)] = res["gaps"][:2]
                self.store.set("mood.gaps", gs)
            out.append((f"Mood {uid} ({case.mood}), {case.timeout} ticks: "
                        + ("; ".join(res["gaps"]) or "material ok"))[:160])
            out += res["notes"][:1]
            if res["release_cutgems"]:
                cmd = "claude/pilot_mood release-cutgems --apply"
                if dry:
                    out.append("[dry] " + cmd)
                elif self.store.count_actions("mood", "release-cutgems", now - 3600) >= self.cfg["max_releases_per_hour"]:
                    out.append("CutGems release blocked (loop guard max_releases_per_hour)")
                else:
                    r = self.client.run(cmd)
                    self.store.log_action(now, "mood", "mood", "release-cutgems", "jobs", cmd, False, r.ok, str(uid))
                    out.append("CutGems jobs removed: rough gems free for the mood" if r.ok
                               else "CutGems release FAILED")
            if res["wood_missing"]:
                out.append("Wood missing: trade buys wood first (trade.boost); NO charcoal start")
                if not dry:
                    boost = list(self.store.get("trade.boost") or [])
                    if "wood" not in boost:
                        self.store.set("trade.boost", ["wood"] + boost)
                    self.store.set("mood.block_charcoal", True)
                    self.store.log_action(now, "mood", "mood", "trade-boost", "wood", "kv trade.boost += wood", False,
                                          True, str(uid))
            if res["will_fail"]:
                msg = (f"Mood {uid} will fail: {case.timeout} ticks < ~{res['est_ticks']} needed"
                       if case.timeout is not None and case.timeout < res["est_ticks"]
                       else f"Mood {uid} will fail: material missing and only {case.timeout} ticks")
                out.append(msg + "; berserk plan: keep civilians away")
                if not dry:
                    self.store.warn(now, "mood", f"mood:fail:{uid}", msg, "crit")
        return out[:6]

    def reserve(self, dry: bool = False) -> list[str]:
        j = self.status()
        st = self.client.run("claude/status")
        popd = (st.json or {}).get("population") if isinstance(st.json, dict) else None
        pop = popd.get("total") if isinstance(popd, dict) else None
        minimum = j.get("minimum") if isinstance(j.get("minimum"), dict) else None
        gaps = reserve_gaps(j.get("vorrat") or {}, pop if isinstance(pop, int) else None, self.cfg,
                            self.store.get("mood.reserve_extra"), minimum)
        src = reserve_wants(self.cfg, minimum)[1]
        if pop is None:
            return ["Population unknown: reserve check skipped"]
        if pop < self.cfg["min_pop_reserve"]:
            return [f"Pop {pop} < {self.cfg['min_pop_reserve']}: no reserve check"]
        if gaps:
            if not dry:                                              # BUG-203: a dry run writes no warning
                self.store.warn(self.clock.now().epoch, "mood", "mood:reserve", "Mood reserve missing: " + ", ".join(gaps))
            return ["Mood reserve missing: " + ", ".join(gaps) + f" (minima: {src})"]
        return [f"Mood reserve ok (minima: {src})"]
