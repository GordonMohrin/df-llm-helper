"""Fair-play lint (v2, WP4): Lua rules of DESIGN §11.3 and the command policy of §11.4-11.5.

    lua(paths) -> [{file, line, rule, msg}]     # token based: comments and strings never match code rules
    lua_source(src, name) -> same, for one source text (role from the name: dfllm/act.lua, ...)
    cmd(text) -> (allowed, reason)              # shell text (hook) or one DFHack command line
    main(argv)                                  # python -m df_llm_helper.lint [PATH ...] | --cmd STR | --config

Roles (CONTRACTS §1.4): only dfllm/act.lua writes df.* / DF vectors and calls mutating APIs or commands;
only dfllm/sense.lua and dfllm/snapshot.lua iterate units or read tiles; only selftest.lua's M.exec loads
code. dfllm/util/k_mock.lua and tests/** are exempt (test doubles). Rules that hold everywhere, act.lua
included: no item/unit creation, no removeJob outside act.cancel_own_lever_job, no hidden-tile or aquifer
reads, no --instant, no teleport, no writes to hidden, skills, body, pos, timers or labors, no blocked
commands. Aliases are followed: `local W = df.global.world` (W.units = world.units), `S.x = df.global`.
The shell policy fails closed: any dfhack-run word outside a mention-only command (echo, grep, git, ...)
is a call, also behind wrappers, variables, aliases, $( ), backticks, heredocs and -c/-e code strings.
v1 names (RULES, lint_paths, gate_command, ...) are forwarded to df_llm_helper._v1.lint.
"""
from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

from . import fairplay, schema

# ================================================================ Lua tokenizer (Lua 5.3)
KEYWORDS = frozenset("and break do else elseif end false for function goto if in local nil not or "
                     "repeat return then true until while".split())
_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_NUM = re.compile(r"0[xX][0-9a-fA-F]*(?:\.[0-9a-fA-F]*)?(?:[pP][+-]?\d+)?|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?")
_WS = re.compile(r"[ \t\r\f\v]+")
_LONG = re.compile(r"\[(=*)\[")
_OPS = ("...", "..", "==", "~=", "<=", ">=", "//", "::", "<<", ">>")
_ESC = {"n": "\n", "t": "\t", "r": "\r", "a": "\a", "b": "\b", "f": "\f", "v": "\v",
        "\\": "\\", '"': '"', "'": "'"}


@dataclass(slots=True)
class Tok:
    kind: str       # name kw str num op
    v: str
    line: int


class LuaSyntaxError(ValueError):
    def __init__(self, line: int, msg: str):
        super().__init__(f"line {line}: {msg}")
        self.line = line


def tokenize(src: str) -> list[Tok]:
    out: list[Tok] = []
    i, n, line = 0, len(src), 1
    if src.startswith("﻿"):                            # UTF-8 BOM (luaL_loadfilex skips it)
        i = 1
    if src.startswith("#", i):                               # shebang
        j = src.find("\n", i)
        i = n if j < 0 else j
    while i < n:
        c = src[i]
        if c == "\n":
            line, i = line + 1, i + 1
            continue
        m = _WS.match(src, i)
        if m:
            i = m.end()
            continue
        if src.startswith("--", i):
            m = _LONG.match(src, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                if j < 0:
                    raise LuaSyntaxError(line, "unfinished long comment")
                line += src.count("\n", i, j)
                i = j + len(close)
            else:
                j = src.find("\n", i)
                i = n if j < 0 else j
            continue
        if c == "[":
            m = _LONG.match(src, i)
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, m.end())
                if j < 0:
                    raise LuaSyntaxError(line, "unfinished long string")
                body = src[m.end():j]
                body = body[2:] if body.startswith("\r\n") else body[1:] if body.startswith("\n") else body
                out.append(Tok("str", body, line))
                line += src.count("\n", i, j)
                i = j + len(close)
                continue
        if c in "\"'":
            j, buf, start = i + 1, [], line
            while True:
                if j >= n:
                    raise LuaSyntaxError(start, "unfinished string")
                d = src[j]
                if d == c:
                    break
                if d == "\n":
                    raise LuaSyntaxError(line, "unfinished string")
                if d == "\\":
                    e = src[j + 1:j + 2]
                    if e == "\n":
                        line, j = line + 1, j + 2
                        buf.append("\n")
                    elif e == "z":                           # \z skips following whitespace
                        j += 2
                        while j < n and src[j] in " \t\r\n\f\v":
                            line += src[j] == "\n"
                            j += 1
                    else:
                        buf.append(_ESC.get(e, "\\" + e))
                        j += 2
                    continue
                buf.append(d)
                j += 1
            out.append(Tok("str", "".join(buf), start))
            i = j + 1
            continue
        if "0" <= c <= "9" or (c == "." and "0" <= src[i + 1:i + 2] <= "9" and src[i + 1:i + 2] != ""):
            m = _NUM.match(src, i)
            out.append(Tok("num", m.group(), line))
            i = m.end()
            continue
        m = _NAME.match(src, i)
        if m:
            w = m.group()
            out.append(Tok("kw" if w in KEYWORDS else "name", w, line))
            i = m.end()
            continue
        op = next((o for o in _OPS if src.startswith(o, i)), None)
        if op is None and c in "+-*/%^#&~|<>=(){}[];:,.":
            op = c
        if op is None:
            raise LuaSyntaxError(line, f"unexpected character {c!r}")
        out.append(Tok("op", op, line))
        i += len(op)
    return out


# ================================================================ rule tables
LUA_RULES = {
    "df-write": "assignment to DF data outside act.lua (use K.act.*)",
    "df-vector": "DF vector insert/erase/resize outside act.lua",
    "df-alloc": "allocating a DF object outside act.lua",
    "mutating-api": "mutating DFHack API outside act.lua (use K.act.*)",
    "command": "running commands or simulating input outside act.lua (use K.act.run)",
    "script": "reqscript/script_environment outside act.lua",
    "unit-iter": "unit iteration outside sense.lua/snapshot.lua (use K.census or df.unit.find(id))",
    "tile-read": "tile/map read outside sense.lua/snapshot.lua (use K.call('snapshot','tile',...))",
    "create": "item/unit creation (armok)",
    "remove-job": "removeJob outside act.cancel_own_lever_job",
    "hidden-write": "writing a hidden flag (reveals tiles/units)",
    "hidden-read": "reading hidden knowledge (water_table, aquifer, features, caverns)",
    "instant": "--instant / leverPullInstant (armok)",
    "teleport": "teleporting units",
    "pos-write": "writing a unit/item position",
    "skill-write": "writing skills",
    "body-write": "writing body, wounds or attributes",
    "timer-write": "writing unit timers/counters",
    "labor-write": "writing labors or work details (labormanager is the sole owner)",
    "armok": "armok/memory API",
    "blocked-command": "blocked command (config/allowlist.json 'blocked', inline lua or claude/*)",
    "not-allowlisted": "act.run command or arguments not in config/allowlist.json",
    "owned-actuator": "act.run of a command that has a dedicated, owner-checked act function",
    "dynamic-code": "load/loadstring/dofile/loadfile outside selftest.lua's M.exec (bypasses every rule)",
    "visibility": "sense/snapshot reads units or tiles without the visibility/revealed check",
    "perf-loop": "items.all/buildings.all/reqscript/require inside a loop",
    "parse": "Lua syntax error (file not checked)",
    "io": "file missing or unreadable",
}

_FORBIDDEN_NAMES = {          # any occurrence, every file (Lua API.txt names)
    "createItem": "create", "createitem": "create", "leverPullInstant": "instant",
    "water_table": "hidden-read", "isTileAquifer": "hidden-read", "isTileHeavyAquifer": "hidden-read",
    "setTileAquifer": "hidden-read", "removeTileAquifer": "hidden-read", "feature_map": "hidden-read",
    "underground_region": "hidden-read", "underground_regions": "hidden-read", "map_features": "hidden-read",
    "patchBytes": "armok", "patchMemory": "armok", "memmove": "armok",
    "setAddress": "armok", "setArmokTools": "armok", "setMortalMode": "armok", "makeown": "armok",
    "setLaborValidity": "labor-write", "setActionTimers": "timer-write", "multiplyActionTimers": "timer-write",
    "subtractActionTimers": "timer-write", "setGroupActionTimers": "timer-write",
    "multiplyGroupActionTimers": "timer-write", "subtractGroupActionTimers": "timer-write",
}
_MUT = {   # mutating functions per dfhack namespace (hack/docs/docs/dev/Lua API.txt)
    "buildings": "allocInstance completeBuild constructAbstract constructBuilding constructWithFilters "
                 "constructWithItems deconstruct notifyCivzoneModified setOwner setSize",
    "burrows": "clearTiles clearUnits setAssignedBlockTile setAssignedTile setAssignedUnit",
    "constructions": "designateNew designateRemove insert",
    "items": "cancelMelting createItem makeProjectile markForMelting markForTrade moveToBuilding "
             "moveToContainer moveToGround moveToInventory remove setOwner",
    "job": "addGeneralRef addWorker assignToWorkshop attachJobItem checkBuildingsNow checkDesignationsNow "
           "createLinked linkIntoWorld removeJob removeWorker setJobCooldown",
    "kitchen": "addExclusion removeExclusion",
    "maps": "addItemSpatter addMaterialSpatter enableBlockUpdates removeTileAquifer resetTileAssignment "
            "setTileAquifer setTileAssignment spawnFlow",
    "military": "addToSquad makeSquad removeFromSquad updateRoomAssignments",
    "units": "assignTrainer create makeown multiplyActionTimers multiplyGroupActionTimers setActionTimers "
             "setAutomaticProfessions setGroupActionTimers setLaborValidity setNickname setPathGoal "
             "subtractActionTimers subtractGroupActionTimers teleport unassignTrainer",
    "world": "SetCurrentWeather SetPauseState",
    "screen": "dismiss show",
    # pauseRecenter/resetDwarfmodeView pause by default (Lua API.txt:1212-1218); announcements write
    # reports and popups (:1248-1300)
    "gui": "pauseRecenter resetDwarfmodeView revealInDwarfmodeMap makeAnnouncement addCombatReport "
           "addCombatReportAuto showAnnouncement showZoomAnnouncement showPopupAnnouncement "
           "showAutoAnnouncement autoDFAnnouncement",
}
MUTATORS = {f"dfhack.{ns}.{f}" for ns, fs in _MUT.items() for f in fs.split()}
# hack/lua/utils.lua vector/object mutators (Lua API.txt:3616-3668)
_UTILS_VEC = {"insert_sorted", "insert_or_update", "erase_sorted", "erase_sorted_key", "sort_vector"}
_UTILS_FNS = _UTILS_VEC | {"assign"}
_DYNAMIC = {"load", "loadstring", "dofile", "loadfile"}
COMMAND_FNS = {"dfhack.run_command", "dfhack.run_command_silent", "dfhack.run_script",
               "dfhack.run_script_with_env", "dfhack.internal.runCommand", "os.execute", "io.popen",
               "gui.simulateInput"}
_RUN_LAST = {"run_command", "run_command_silent", "run_script", "runCommand"}
UNIT_LIST_FNS = {"dfhack.units.getCitizens", "dfhack.units.getUnitsInBox", "df.unit.get_vector"}
TILE_FNS = {f"dfhack.maps.{f}" for f in ("getTileType getTileFlags getTileBlock getBlock ensureTileBlock "
                                          "forEachTile getPlantAtTile getWalkableGroup canWalkBetween "
                                          "getTileBiomeRgn getLocalInitFeature").split()}
_DF_NS = {"units", "items", "buildings", "maps", "job", "burrows", "military", "gui", "world", "constructions",
          "kitchen"}
_DF_INTER = {"flags1", "flags2", "flags3", "flags4", "designation", "occupancy", "gate_flags", "pickup_flags"}
_DF_LAST = {"flags1", "flags2", "flags3", "flags4", "cur_routine_idx", "tiletype", "hist_figure_id",
            "population_id"}
_BODY = {"wounds", "blood_count", "physical_attrs", "mental_attrs"}
_COUNTERS = {"counters", "counters2", "counters3"}
_BLOCKS = {"func", "if", "do", "loop"}
_LOOPS = {"loop", "forhdr", "whilehdr"}


def _kind_of(parts: list[str]) -> str:
    s = ".".join(parts).lower()
    return "order" if ("order" in s or ".job" in s) else "unit" if "unit" in s else "item" if "item" in s else "df"


def _role(name: str) -> str:
    p = Path(str(name).replace("\\", "/"))
    return p.stem if p.parent.name == "dfllm" and p.stem in ("act", "sense", "snapshot", "selftest") else ""


def _exempt(path: Path) -> bool:
    """CONTRACTS §1.4: util/k_mock.lua and tests/** of this repo are test doubles."""
    if path.name == "k_mock.lua" and path.parent.name == "util":
        return True
    try:
        rel = path.resolve().relative_to(fairplay.REPO)
    except ValueError:
        return False
    return bool(rel.parts) and rel.parts[0] == "tests"


# ================================================================ analyzer
class _Lint:
    def __init__(self, toks: list[Tok], role: str, al: dict):
        self.t, self.n, self.role, self.al = toks, len(toks), role, al
        self.stack: list[dict] = []
        self.glob: dict = {}
        self.flags: set[str] = set()
        self.found: dict[tuple[int, str], str] = {}

    # ---- helpers
    def add(self, line: int, rule: str, msg: str = "") -> None:
        self.found.setdefault((line, rule), msg or LUA_RULES[rule])

    def op(self, i: int, *vals: str) -> bool:
        return 0 <= i < self.n and self.t[i].kind == "op" and (not vals or self.t[i].v in vals)

    def lookup(self, name: str):
        for e in reversed(self.stack):
            if "scope" in e and name in e["scope"]:
                return e["scope"][name]
        return self.glob.get(name)

    def bind(self, name: str, val, local: bool) -> None:
        if local:
            for e in reversed(self.stack):
                if "scope" in e:
                    e["scope"][name] = val
                    return
            self.glob[name] = val
            return
        for e in reversed(self.stack):
            if "scope" in e and name in e["scope"]:
                e["scope"][name] = val
                return
        self.glob[name] = val

    def defined(self, name: str) -> bool:
        """A local, parameter or global of this file shadows the name (e.g. `local function load`)."""
        return name in self.glob or any(name in e.get("scope", ()) for e in self.stack)

    def bound(self, parts: list[str]):
        """(length, binding) of the longest prefix of a dotted path with a binding: plain names
        (`W`) and table fields (`S.lev`, recorded by on_assign)."""
        for i in range(len(parts), 0, -1):
            b = self.lookup(".".join(parts[:i]))
            if b:
                return i, b
        return 0, None

    def in_loop(self) -> bool:
        return any(e["k"] in _LOOPS for e in self.stack)

    def in_func(self, fname: str) -> bool:
        return any(e["k"] == "func" and e.get("fname") == fname for e in self.stack)

    def match(self, i: int, step: int) -> int | None:
        pairs = {"(": ")", "[": "]", "{": "}"}
        a = self.t[i].v
        b = pairs[a] if step > 0 else {v: k for k, v in pairs.items()}[a]
        d, j = 0, i
        while 0 <= j < self.n:
            if self.t[j].kind == "op":
                d += self.t[j].v == a
                d -= self.t[j].v == b
                if d == 0:
                    return j
            j += step
        return None

    def path_at(self, j: int) -> tuple[bool, list[str]]:
        """(rooted at a plain name, parts) of the access path ending at token j: a name, or the `]` of
        a string index (`w['units']`)."""
        parts, k = [], j
        while True:
            if 0 <= k < self.n and self.t[k].kind == "name":
                parts.append(self.t[k].v)
                if self.op(k - 1, ".", ":"):
                    k -= 2
                    continue
                return True, parts[::-1]
            if self.op(k, "]") and k >= 2 and self.t[k - 1].kind == "str" and self.op(k - 2, "["):
                parts.append(self.t[k - 1].v)
                k -= 3
                continue
            return False, parts[::-1]

    def qual(self, j: int) -> str:
        """Dotted path ending at token j with aliases resolved: dfhack namespaces and modules
        (`local m = dfhack.maps`), DF paths (`local W = df.global.world`) and table fields (`S.g = df.global`)."""
        rooted, parts = self.path_at(j)
        if not rooted:
            return "?." + ".".join(parts)
        i, b = self.bound(parts)
        if b and b[0] in ("ns", "mod"):
            parts = b[1].split(".") + parts[i:]
        elif b and b[0] == "df" and b[2]:
            parts = b[2].split(".") + parts[i:]
        return ".".join(parts)

    def chain_fwd(self, k: int):
        """Forward access chain from token k: (parts, end, first call index, first index index);
        a string index counts as a field."""
        parts, j, call, idx = [self.t[k].v], k + 1, None, None
        while j < self.n:
            tk = self.t[j]
            if self.op(j, ".", ":") and j + 1 < self.n and self.t[j + 1].kind == "name":
                parts.append(self.t[j + 1].v)
                j += 2
            elif self.op(j, "[") and j + 2 < self.n and self.t[j + 1].kind == "str" and self.op(j + 2, "]"):
                parts.append(self.t[j + 1].v)
                j += 3
            elif self.op(j, "(", "[", "{"):
                if tk.v == "[":
                    idx = len(parts) if idx is None else idx
                elif call is None:
                    call = len(parts)
                m = self.match(j, 1)
                j = (m if m is not None else self.n) + 1
            elif tk.kind == "str":
                call = len(parts) if call is None else call
                j += 1
            else:
                break
        return parts, j, call, idx

    def classify(self, k: int):
        """Binding value of the expression starting at token k: ('df', kind, path|None) |
        ('ns'|'mod', path) | None. A df path is kept for pure field chains (`df.global.world`)."""
        if not (0 <= k < self.n) or self.t[k].kind != "name":
            return None
        parts, _, call, idx = self.chain_fwd(k)
        pure = call is None and idx is None
        if parts[0] == "df":
            return "df", _kind_of(parts), ".".join(parts) if pure else None
        i, b = self.bound(parts)
        if b and b[0] == "df":
            return "df", b[1], ".".join([b[2]] + parts[i:]) if pure and b[2] else None
        if b and b[0] in ("ns", "mod"):
            if i == len(parts):
                return b
            pre = b[1].split(".")
            parts = pre + parts[i:]
            call = None if call is None else call + len(pre) - i
        if parts[0] == "dfhack" and len(parts) >= 2:
            if len(parts) == 2 and call is None:
                return "ns", "dfhack." + parts[1]
            if parts[1] in _DF_NS and len(parts) >= 3 and parts[2].startswith(("get", "find")):
                return "df", _kind_of(parts), None
        if parts[:2] == ["K", "act"] and len(parts) <= 3 and pure:     # local run = K.act.run
            return "ns", ".".join(parts)
        if parts[0] in ("require", "reqscript") and len(parts) == 1 and call == 1 and k + 1 < self.n:
            lit = self.t[k + 1] if self.t[k + 1].kind == "str" else self.t[k + 2] if k + 2 < self.n else None
            if lit is not None and lit.kind == "str":
                return "mod", lit.v
        return None

    def back(self, j: int):
        """LHS chain ending at token j -> (start, segs); segs[0] is ('root', name) or ('paren', None)."""
        segs: list[tuple[str, str | None]] = []
        while j >= 0:
            tk = self.t[j]
            if tk.kind == "name":
                if self.op(j - 1, ".", ":"):
                    segs.append(("field", tk.v))
                    j -= 2
                    continue
                segs.append(("root", tk.v))
                return j, segs[::-1]
            if self.op(j, "]", ")"):
                k = self.match(j, -1)
                if k is None:
                    return j, []
                if tk.v == "]":
                    segs.append(("index", None))
                    j = k - 1
                    continue
                if k >= 1 and (self.t[k - 1].kind == "name" or self.op(k - 1, "]", ")")):
                    segs.append(("call", None))
                    j = k - 1
                    continue
                segs.append(("paren", None))
                return k, segs[::-1]
            break
        if not segs:
            return j + 1, []
        segs.append(("paren", None))
        return j + 1, segs[::-1]

    # ---- token handlers
    def on_function(self, i: int) -> None:
        t, j, fname, method = self.t, i + 1, None, False
        if j < self.n and t[j].kind == "name":
            parts = [t[j].v]
            j += 1
            while self.op(j, ".", ":") and j + 1 < self.n and t[j + 1].kind == "name":
                method = method or t[j].v == ":"
                parts.append(t[j + 1].v)
                j += 2
            fname = parts[-1]
            if i > 0 and t[i - 1].kind == "kw" and t[i - 1].v == "local":
                self.bind(parts[0], None, True)
        elif self.op(i - 1, "="):
            _, segs = self.back(i - 2)
            names = [s[1] for s in segs if s[0] in ("root", "field")]
            fname = names[-1] if names else None
        params = {"self": None} if method else {}
        if self.op(j, "("):
            k = j + 1
            while k < self.n and not self.op(k, ")"):
                if t[k].kind == "name":
                    params[t[k].v] = None
                k += 1
        self.stack.append({"k": "func", "scope": params, "fname": fname})

    def on_for(self, i: int) -> None:
        vars_, j = [], i + 1
        while j < self.n and self.t[j].kind == "name":
            vars_.append(self.t[j].v)
            j += 1
            if not self.op(j, ","):
                break
            j += 1
        self.stack.append({"k": "forhdr", "vars": vars_, "numeric": self.op(j, "="), "start": j})

    def on_do(self, i: int) -> None:
        if not (self.stack and self.stack[-1]["k"] in ("forhdr", "whilehdr")):
            self.stack.append({"k": "do", "scope": {}})
            return
        hdr = self.stack.pop()
        scope = {v: None for v in hdr.get("vars", [])}
        if hdr["k"] == "forhdr" and not hdr["numeric"]:
            for k in range(hdr["start"], i):
                if self.t[k].kind == "name" and not self.op(k - 1, ".", ":"):
                    c = self.classify(k)
                    if c and c[0] == "df":
                        for v in hdr["vars"][1:] or hdr["vars"]:
                            scope[v] = ("df", c[1], None)          # an element, not the vector
                        break
        self.stack.append({"k": "loop", "scope": scope})

    def pop_block(self) -> None:
        while self.stack:
            if self.stack.pop()["k"] in _BLOCKS:
                return

    def pop_bracket(self, v: str) -> None:
        want = {")": "(", "]": "[", "}": "{"}[v]
        for d in range(len(self.stack) - 1, -1, -1):
            k = self.stack[d]["k"]
            if k == want:
                del self.stack[d:]
                return
            if k in _BLOCKS:
                return

    def on_local(self, i: int) -> None:
        if i + 1 < self.n and self.t[i + 1].kind == "kw":
            return                                           # local function: on_function binds it
        names, j = [], i + 1
        while j < self.n and self.t[j].kind == "name":
            names.append(self.t[j].v)
            j += 1
            if not self.op(j, ","):
                break
            j += 1
        if not self.op(j, "="):
            for nm in names:
                self.bind(nm, None, True)

    def on_assign(self, i: int) -> None:
        top = self.stack[-1]["k"] if self.stack else "func"
        if top not in _BLOCKS:
            return                                           # table field, numeric for, ...
        targets, j = [], i - 1
        while True:
            s, segs = self.back(j)
            if not segs:
                break
            targets.append((s, segs))
            if self.op(s - 1, ","):
                j = s - 2
                continue
            break
        targets.reverse()
        if not targets:
            return
        s0 = targets[0][0]
        local = s0 > 0 and self.t[s0 - 1].kind == "kw" and self.t[s0 - 1].v == "local"
        vals, k = [], i + 1
        for _ in targets:
            vals.append(self.classify(k))
            if len(targets) == 1:
                break
            d, k2 = 0, k
            while k2 < self.n:                               # next top-level comma of the expression list
                tk = self.t[k2]
                if tk.kind == "op" and tk.v in "([{":
                    d += 1
                elif tk.kind == "op" and tk.v in ")]}":
                    d -= 1
                elif d == 0 and (self.op(k2, ",", "=") or (tk.kind == "kw" and tk.v not in
                                                                 ("and", "or", "not", "nil", "true", "false", "function", "end"))):
                    break
                k2 += 1
            if not self.op(k2, ","):
                break
            k = k2 + 1
        for idx, (s, segs) in enumerate(targets):
            val = vals[idx] if idx < len(vals) else None
            if segs[0][0] == "root" and len(segs) == 1:
                self.bind(segs[0][1], val, local)
            elif segs[0][0] == "root":
                self.check_write(segs, self.t[i].line)
                if all(x[0] == "field" for x in segs[1:]):     # S.lev = df.building.find(5)
                    key = ".".join(x[1] for x in segs)
                    if val or key in self.glob:
                        self.glob[key] = val

    def check_write(self, segs, line: int) -> None:
        root = segs[0][1]
        b = self.lookup(root)
        fields = []
        for s in segs[1:-1]:                                 # a DF reference kept in a table field
            if s[0] != "field":
                break
            fields.append(s[1])
            bb = self.lookup(".".join([root] + fields))
            if bb and bb[0] == "df":
                b = bb
        dfroot = root == "df" or bool(b and b[0] == "df")
        kind = b[1] if b and b[0] == "df" else "df" if root == "df" else None
        names = [s[1] for s in segs[1:] if s[0] == "field"]
        inter = {s[1] for s, nxt in zip(segs[1:], segs[2:]) if s[0] == "field"}
        last = segs[-1][1] if segs[-1][0] == "field" else None
        every = [root] + names
        order_ctx = kind == "order" or any("order" in x or x.startswith("job") for x in every)
        # The field-name rules hold in act.lua too. Without a known DF root they need a DF-typical
        # path, so module-private tables (st.counters[id], M.st.skills, ui.hidden) stay clean.
        unitish = dfroot or any(x in ("u", "unit", "units", "it", "item", "items") for x in every)
        prev = segs[-2] if len(segs) >= 2 else ("", None)
        hits = []
        if last == "hidden" and (dfroot or prev[0] == "index" or prev[1] in ("flags", "designation")):
            hits.append("hidden-write")
        if "pos" in names and not order_ctx and unitish:
            pi = segs.index(("field", "pos"))
            after = segs[pi + 1] if pi + 1 < len(segs) else None
            if (after and after[0] == "field" and after[1] in ("x", "y", "z")) or last == "pos":
                hits.append("pos-write")
        if ("skills" in names and (dfroot or "soul" in every or "current_soul" in every)) or \
                (dfroot and last in ("rating", "experience")):
            hits.append("skill-write")
        if (dfroot and "body" in inter) or any(x in _BODY for x in names):
            hits.append("body-write")
        if "counters2" in names or (dfroot and inter & _COUNTERS) or \
                (last and last.endswith("_timer") and (dfroot or "counters" in names)):
            hits.append("timer-write")
        if ("labors" in names and (dfroot or "status" in every)) or \
                ("work_details" in names and (dfroot or "labor_info" in names)):
            hits.append("labor-write")
        for r in hits:
            self.add(line, r)
        if not hits and self.role != "act" and (dfroot or inter & _DF_INTER or last in _DF_LAST):
            self.add(line, "df-write")

    def on_method(self, i: int) -> None:
        if not (i + 1 < self.n and self.t[i + 1].kind == "name"):
            return
        m, line = self.t[i + 1].v, self.t[i].line
        if not (self.op(i + 2, "(", "{") or (i + 2 < self.n and self.t[i + 2].kind == "str")):
            return
        if m in ("insert", "erase", "resize") and self.role != "act":
            self.add(line, "df-vector")
        elif m in ("assign", "delete") and self.role != "act":
            self.add(line, "df-write")
        elif m == "new" and i >= 1 and self.t[i - 1].kind == "name":
            q = self.qual(i - 1).split(".")
            if q[0] == "df":
                if any(p.startswith("item") or p == "unit" for p in q[1:]):
                    self.add(line, "create")
                elif self.role != "act":
                    self.add(line, "df-alloc")

    def literal_args(self, i: int) -> tuple[list[str], bool]:
        t, j = self.t, i + 1
        if j < self.n and t[j].kind == "str":
            return [t[j].v], False
        if not self.op(j, "(", ","):
            return [], True
        j += 1
        if self.op(j, "{"):
            j += 1
        out = []
        while j < self.n and t[j].kind == "str":
            out.append(t[j].v)
            j += 1
            if self.op(j, ","):
                j += 1
                continue
            return out, not self.op(j, ")", "}")
        return out, True

    def check_command(self, i: int, q: str) -> None:
        args, partial = self.literal_args(i)
        toks = " ".join(args).split()
        if not toks:
            return
        line, head = self.t[i].line, toks[0].lstrip(":")
        b = fairplay.blocked_match(toks, self.al)
        if b:
            self.add(line, "blocked-command", f"blocked command: {b}")
        elif head == "lua" or head == "claude" or head.startswith("claude/"):
            self.add(line, "blocked-command", f"blocked command: {head} (inline lua / v1 claude/*)")
        elif q in ("os.execute", "io.popen") and not partial:
            ok, why = cmd(" ".join(args), dev=False, shell=True, al=self.al)
            if not ok:
                self.add(line, "blocked-command", f"{q}: {why}")
        elif q.endswith("act.run"):
            o = fairplay.owned_match(toks)
            if o:
                self.add(line, "owned-actuator", f"act.run: '{o[0]}' is owned by {o[1]}; call that act function")
            elif toks[0] not in self.al["commands"]:
                self.add(line, "not-allowlisted", f"act.run: {toks[0]} is not in config/allowlist.json")
            elif not partial:
                ok, why = fairplay.check_run(toks[0], toks[1:], self.al)
                if not ok:
                    self.add(line, "not-allowlisted", f"act.run: {why}")

    def from_require(self, i: int, mod: str) -> bool:
        """Name token i directly follows `require('mod').` or `require 'mod' .`."""
        k = i - 2
        if not self.op(i - 1, ".", ":"):
            return False
        if self.op(k, ")"):
            m = self.match(k, -1)
            return (m is not None and m >= 1 and self.t[m - 1].v == "require" and k - m == 2
                    and self.t[m + 1].kind == "str" and self.t[m + 1].v == mod)
        return k >= 1 and self.t[k].kind == "str" and self.t[k].v == mod and self.t[k - 1].v == "require"

    def on_str(self, i: int) -> None:
        """A string index `x['units']` is a field access: the same read rules as a name."""
        tk = self.t[i]
        if "--instant" in tk.v:
            self.add(tk.line, "instant")
        if self.op(i - 1, "[") and self.op(i + 1, "]"):
            self.check_ref(tk.v, self.qual(i + 1), tk.line)

    def check_ref(self, v: str, q: str, line: int) -> None:
        """Rules on a resolved access path q whose last part is v (a name or a string index)."""
        if v in _FORBIDDEN_NAMES:
            self.add(line, _FORBIDDEN_NAMES[v])
        if v == "features" and q.endswith("world.features"):
            self.add(line, "hidden-read")
        if q == "dfhack.units.teleport":
            self.add(line, "teleport")
        if self.role != "act" and q in MUTATORS and v not in _FORBIDDEN_NAMES and v not in ("removeJob", "teleport", "create"):
            self.add(line, "mutating-api", f"mutating DFHack API outside act.lua: {q}")
        if (v == "units" and q.endswith("world.units")) or q in UNIT_LIST_FNS:
            self.flags.add("unit_iter")
            if self.role not in ("sense", "snapshot"):
                self.add(line, "unit-iter")
        if q in TILE_FNS or (v == "map" and q.endswith("world.map")) or q.startswith("df.map_block"):
            self.flags.add("tile_read")
            if self.role not in ("sense", "snapshot"):
                self.add(line, "tile-read")
        if self.in_loop() and ((v == "all" and (q.endswith("items.all") or q.endswith("buildings.all")))
                               or q in ("df.item.get_vector", "df.building.get_vector")):
            self.add(line, "perf-loop")

    def on_name(self, i: int) -> None:
        tk, line = self.t[i], self.t[i].line
        v, q = tk.v, self.qual(i)
        called = self.op(i + 1, "(", "{") or (i + 1 < self.n and self.t[i + 1].kind == "str")
        bare = not self.op(i - 1, ".", ":")
        self.check_ref(v, q, line)
        if v in _DYNAMIC and ((bare and not self.defined(v) and not self.op(i + 1, "="))
                              or q in (f"_G.{v}", f"_ENV.{v}")):
            if not (self.role == "selftest" and self.in_func("exec")):
                self.add(line, "dynamic-code")
        if self.role != "act" and v in _UTILS_FNS and (q == f"utils.{v}" or self.from_require(i, "utils")):
            self.add(line, "df-vector" if v in _UTILS_VEC else "df-write", f"utils.{v} mutates DF data outside act.lua")
        if v == "teleport" and (q.endswith("units.teleport") or (bare and called)):
            self.add(line, "teleport")
        if q == "dfhack.units.create":
            self.add(line, "create")
        if q == "df.new" and called and self.role != "act":
            self.add(line, "df-alloc")
        if v == "removeJob" and not (self.role == "act" and self.in_func("cancel_own_lever_job")):
            self.add(line, "remove-job")
        if self.role != "act" and (q in COMMAND_FNS or (v == "simulateInput" and not bare)):
            self.add(line, "command", f"{LUA_RULES['command']}: {q}")
        if (bare and v == "reqscript" and called) or q in ("dfhack.reqscript", "dfhack.script_environment"):
            if self.role != "act":
                self.add(line, "script")
            if self.in_loop():
                self.add(line, "perf-loop")
            args, _ = self.literal_args(i)
            if args and args[0] not in self.al["armok_exceptions"]:
                b = fairplay.blocked_match(args[0].split(), self.al)
                if b or args[0].startswith("claude/"):
                    self.add(line, "blocked-command", f"blocked script: {args[0]}")
        if bare and v == "require" and called and self.in_loop():
            self.add(line, "perf-loop")
        if v in ("isVisible", "isHidden", "hidden"):
            self.flags.add(v)
        # q, not the token: `local rc = dfhack.run_command; rc('fastdwarf')` is checked too
        if (called or self.pcall_arg(i)) and (q.endswith("act.run") or q.rsplit(".", 1)[-1] in _RUN_LAST
                                              or q in COMMAND_FNS):
            self.check_command(i, q)

    def pcall_arg(self, i: int) -> bool:
        """Name token i is the function argument of pcall(f, ...) / xpcall / safecall."""
        k = i
        while k >= 2 and self.op(k - 1, ".", ":") and self.t[k - 2].kind == "name":
            k -= 2
        return (self.op(i + 1, ",") and self.op(k - 1, "(") and k >= 2 and self.t[k - 2].kind == "name"
                and self.t[k - 2].v in ("pcall", "xpcall", "safecall"))

    def run(self) -> list[tuple[int, str, str]]:
        t = self.t
        for i, tk in enumerate(t):
            if tk.kind == "kw":
                v = tk.v
                if v == "function":
                    self.on_function(i)
                elif v == "if":
                    self.stack.append({"k": "if", "scope": {}})
                elif v == "for":
                    self.on_for(i)
                elif v == "while":
                    self.stack.append({"k": "whilehdr"})
                elif v == "do":
                    self.on_do(i)
                elif v == "repeat":
                    self.stack.append({"k": "loop", "scope": {}})
                elif v in ("end", "until"):
                    self.pop_block()
                elif v == "local":
                    self.on_local(i)
            elif tk.kind == "op":
                if tk.v in ("(", "[", "{"):
                    self.stack.append({"k": tk.v})
                elif tk.v in (")", "]", "}"):
                    self.pop_bracket(tk.v)
                elif tk.v == "=":
                    self.on_assign(i)
                elif tk.v == ":":
                    self.on_method(i)
            elif tk.kind == "name":
                self.on_name(i)
            elif tk.kind == "str":
                self.on_str(i)
        if self.role == "sense" and "unit_iter" in self.flags and not {"isVisible", "isHidden"} <= self.flags:
            self.add(1, "visibility", "sense.lua iterates units but never calls both isVisible and isHidden")
        if self.role == "snapshot" and "tile_read" in self.flags and "hidden" not in self.flags:
            self.add(1, "visibility", "snapshot.lua reads tiles but never checks designation.hidden")
        return sorted((ln, r, m) for (ln, r), m in self.found.items())


def lua_source(src: str, name: str = "<lua>", role: str | None = None, allowlist: dict | None = None) -> list[dict]:
    al = allowlist or fairplay.allowlist()
    try:
        toks = tokenize(src)
    except LuaSyntaxError as e:
        return [{"file": name, "line": e.line, "rule": "parse", "msg": str(e)}]
    res = _Lint(toks, _role(name) if role is None else role, al).run()
    return [{"file": name, "line": ln, "rule": r, "msg": m} for ln, r, m in res]


def lua(paths, allowlist: dict | None = None, exempt: bool = True) -> list[dict]:
    """Lint .lua files (directories recursively). Exempt files (util/k_mock.lua, tests/**) are skipped."""
    al = allowlist or fairplay.allowlist()
    out: list[dict] = []
    seen: set = set()
    for p in [Path(x) for x in ([paths] if isinstance(paths, (str, Path)) else paths)]:
        if not p.exists():
            out.append({"file": str(p), "line": 0, "rule": "io", "msg": "no such file or directory"})
            continue
        for f in sorted(p.rglob("*.lua")) if p.is_dir() else [p]:
            key = f.resolve()
            if key in seen or (exempt and _exempt(f)):
                continue
            seen.add(key)
            try:
                text = f.read_bytes().decode("utf-8-sig", errors="replace")
            except OSError as e:
                out.append({"file": str(f), "line": 0, "rule": "io", "msg": f"not readable: {e}"})
                continue
            if "\x00" in text:
                out.append({"file": str(f), "line": 0, "rule": "io", "msg": "not a text file (NUL bytes)"})
                continue
            out += lua_source(text, str(f), allowlist=al)
    return out


# ================================================================ command policy (hook, DESIGN §11.5)
DFLLM_SUBS = {"boot", "adopt", "stop", "status", "selftest", "restore", "inspect", "help"}
_SHELL_WORDS = {"source", "ls", "help", "enable", "disable", "set", "alias", "type", "time", "clean", "force",
                "launch", "plant", "feature", "points", "tags", "dfllm"}
# words before the command word; options and durations after them are skipped too (timeout 30, nice -n 5)
_SKIP_HEADS = {"&", ".", "call", "exec", "start", "start-process", "time", "nohup", "command", "env", "sudo",
               "doas", "then", "do", "else", "!", "$", "if", "while", "until", "timeout", "nice", "ionice",
               "winpty", "stdbuf", "chrt", "taskset", "xargs", "parallel"}
# commands that never execute their arguments: a dfhack-run word there is a mention
_MENTION = {"echo", "printf", "grep", "egrep", "fgrep", "rg", "findstr", "select-string", "sls", "git", "cat",
            "type", "get-content", "gc", "sed", "awk", "head", "tail", "less", "more", "wc", "write-host",
            "write-output", "ls", "dir", "stat", "file", "which", "where.exe", "whereis", "test", "[", "[[",
            "test-path", "get-item", "get-childitem", "gci", "get-command", "gcm", "resolve-path", "cp", "mv",
            "copy-item", "move-item"}
_SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish", "cmd", "powershell", "pwsh", "iex", "invoke-expression",
           "wsl", "python", "python3", "py", "pythonw", "node", "perl", "ruby", "lua", "luajit"}
_ARGV_FEEDERS = {"xargs", "parallel"}                    # supply the arguments of the command they run
_ECHOERS = {"echo", "printf", "write-output", "write-host"}  # output = arguments: code inside $( ) / <( )
# mention-only commands that can still run a program named in an argument
_RUNS_ARG = {"awk": re.compile(r"system\s*\(|getline|\|\s*\""), "sed": re.compile(r"/[gIip0-9]*e[gIip0-9]*$|(^|[;{])\s*e\b"),
             "git": re.compile(r"=\s*!|^!"), "rg": re.compile(r"^--pre\b")}
_RUNS_ARG.update(gawk=_RUNS_ARG["awk"], mawk=_RUNS_ARG["awk"], nawk=_RUNS_ARG["awk"])
_SET_WORDS = {"set", "export", "declare", "local", "readonly", "typeset"}
_ALIAS_WORDS = {"alias", "set-alias", "new-alias", "sal", "nal"}
_DFR = re.compile(r"dfhack-run(?![\w-])", re.I)          # dfhack-run, dfhack-run.exe; not dfhack-runner
_CODEY = re.compile(r"[\s;|&()$`<>\"']")                 # a token that is itself shell or program text
_EDGE = "[](){},;'\"`"
_ASSIGN = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)
_PS_ASSIGN = re.compile(r"^\$\{?((?:env:)?[A-Za-z_][A-Za-z0-9_]*)\}?=(.*)$", re.S | re.I)
_DURATION = re.compile(r"^\d+(?:\.\d+)?[smhd]?$")
_REDIR = re.compile(r"^\d*(?:>>?|<)(&\d*)?$")
_LISTFORM = re.compile(r"""dfhack-run(?:\.exe)?(['"])\s*,""", re.I)
_LISTITEM = re.compile(r"""\s*(['"])(.*?)\1\s*(,?)""")
_MAX_DEPTH = 6


@dataclass
class _Seg:
    toks: list = field(default_factory=list)     # [(text, quoted)]
    end: str = ""                                # separator that ended the segment ('' = end of text)
    subs: list = field(default_factory=list)     # command substitutions $( ) and ` `, already lexed
    docs: list = field(default_factory=list)     # [(body, expands)] heredoc / here-string bodies


def _heredoc_word(s: str, i: int) -> tuple[str, bool, int]:
    buf, quoted, n = [], False, len(s)
    while i < n and s[i] not in " \t\r\n;|&()<>":
        c = s[i]
        if c in "'\"":
            j = s.find(c, i + 1)
            j = n if j < 0 else j
            buf.append(s[i + 1:j])
            quoted, i = True, j + 1
        elif c == "\\" and i + 1 < n:
            buf.append(s[i + 1])
            quoted, i = True, i + 2
        else:
            buf.append(c)
            i += 1
    return "".join(buf), quoted, i


def _heredoc_body(s: str, i: int, delim: str, strip: bool) -> tuple[str, int]:
    lines, n = [], len(s)
    while i < n:
        e = s.find("\n", i)
        e = n if e < 0 else e
        line = s[i:e].rstrip("\r")
        i = e + 1
        if (line.lstrip("\t") if strip else line) == delim:
            return "\n".join(lines), min(i, n)
        lines.append(line)
    return "\n".join(lines), n


def _dq_scan(s: str, i: int, depth: int, subs: list, stop: bool = True) -> tuple[str, int]:
    """Text of a double-quoted string from i (or of an expanding heredoc body, stop=False); every
    $( ) and ` ` inside is lexed into subs, since bash and PowerShell run them."""
    buf, n = [], len(s)
    while i < n:
        c = s[i]
        if stop and c == '"':
            return "".join(buf), i + 1
        if c in "\\`" and i + 1 < n and s[i + 1] in '"\\$`':
            buf.append(s[i + 1])
            i += 2
            continue
        if c == "$" and s[i + 1:i + 2] == "(":
            inner, j = _lex(s, i + 2, depth + 1, close=True)
            subs.append(inner)
            buf.append(s[i:j])
            i = j
            continue
        if c == "`":
            j = s.find("`", i + 1)
            if j > 0 and not (stop and '"' in s[i + 1:j].replace('\\"', "")):
                subs.append(_lex(s[i + 1:j], 0, depth + 1)[0])
                buf.append(s[i:j + 1])
                i = j + 1
                continue
        buf.append(c)
        i += 1
    return "".join(buf), n


def _lex(s: str, i: int = 0, depth: int = 0, close: bool = False) -> tuple[list[_Seg], int]:
    """Approximate bash/PowerShell/cmd lexer: words (quotes removed), separators ; | & && || ( ) { }
    and newlines, $( ) and backtick substitutions, heredocs and here-strings. With close=True it stops
    after the `)` that closes a $( (returns the index after it)."""
    if depth > 40:
        raise ValueError("shell text nested too deeply")
    n, segs = len(s), [_Seg()]
    st = {"cur": None, "q": False, "here": False}
    pending: list = []                                  # [delim, strip_tabs, expands, seg]
    paren = 0

    def add(txt: str, quoted: bool = False) -> None:
        st["cur"] = (st["cur"] or "") + txt
        st["q"] = st["q"] or quoted

    def end_tok() -> None:
        if st["cur"] is not None:
            if st["here"]:
                segs[-1].docs.append((st["cur"], False))     # its $( ) were lexed into subs already
                st["here"] = False
            else:
                segs[-1].toks.append((st["cur"], st["q"]))
        st["cur"], st["q"] = None, False

    def split(term: str) -> None:
        end_tok()
        g = segs[-1]
        if g.toks or g.subs or g.docs:
            g.end = term
            segs.append(_Seg())

    while i < n:
        c = s[i]
        if c == "@" and s[i + 1:i + 2] in ("'", '"') and s[i + 2:i + 3] in ("\n", "\r"):   # PowerShell here-string
            qc = s[i + 1]
            j = s.find("\n" + qc + "@", i + 2)
            j = n if j < 0 else j
            if qc == '"':
                _dq_scan(s[i + 2:j], 0, depth, segs[-1].subs, stop=False)
            add(s[i + 2:j], True)
            i = j + 3
            continue
        if c == "'":
            j = s.find("'", i + 1)
            j = n if j < 0 else j
            add(s[i + 1:j], True)
            i = j + 1
            continue
        if c == '"':
            txt, i = _dq_scan(s, i + 1, depth, segs[-1].subs)
            add(txt, True)
            continue
        if c in "$<>" and s[i + 1:i + 2] == "(":                  # $( ), process substitution <( ) >( )
            inner, j = _lex(s, i + 2, depth + 1, close=True)
            segs[-1].subs.append(inner)
            add(s[i:j])
            i = j
            continue
        if c == "$" and s[i + 1:i + 2] == "{":
            j = s.find("}", i)
            j = n - 1 if j < 0 else j
            add(s[i:j + 1])
            i = j + 1
            continue
        if c == "`":
            if s[i + 1:i + 2] in ("\n", "\r"):                    # line continuation
                i += 3 if s[i + 1:i + 3] == "\r\n" else 2
                continue
            j = s.find("`", i + 1)
            if j > 0:
                segs[-1].subs.append(_lex(s[i + 1:j], 0, depth + 1)[0])
                add(s[i:j + 1])
                i = j + 1
            else:                                                 # PowerShell escape
                add(s[i + 1:i + 2], True)
                i += 2
            continue
        if c == "\\":
            nx = s[i + 1:i + 2]
            if nx == "\n":
                i += 2
            elif nx and nx in " ()|;&<>\"'`$":
                add(nx, True)
                i += 2
            else:
                add(c)
                i += 1
            continue
        if s.startswith("<<<", i):
            end_tok()
            st["here"] = True
            i += 3
            continue
        if s.startswith("<<", i):
            end_tok()
            j = i + 2
            strip = s[j:j + 1] == "-"
            j += strip
            while j < n and s[j] in " \t":
                j += 1
            word, wq, j = _heredoc_word(s, j)
            if word:
                pending.append([word, strip, not wq, segs[-1]])
            i = j
            continue
        if c == "\n":
            split("\n")
            i += 1
            for delim, strip, expands, g in pending:
                body, i = _heredoc_body(s, i, delim, strip)
                g.docs.append((body, expands))
            pending = []
            continue
        if c in " \t\r":
            end_tok()
            i += 1
            continue
        if c == "&" and st["cur"] and st["cur"][-1] in "<>":        # 2>&1
            add(c)
            i += 1
            continue
        if c == ")" and close and paren == 0:
            end_tok()
            return [g for g in segs if g.toks or g.subs or g.docs], i + 1
        if c in ";|&(){}":
            if c == "&" and st["cur"] is None and s[i + 1:i + 2] != "&" and \
                    (not segs[-1].toks or segs[-1].toks[-1][0] == "="):
                i += 1                                            # PowerShell call operator
                continue
            paren += (c == "(") - (c == ")")
            paren = max(paren, 0)
            two = s[i:i + 2] in ("&&", "||")
            split(s[i:i + 2] if two else c)
            i += 2 if two else 1
            continue
        add(c)
        i += 1
    end_tok()
    return [g for g in segs if g.toks or g.subs or g.docs], n


def _strip_redir(toks: list[str]) -> list[str]:
    out, skip = [], False
    for t in toks:
        if skip:
            skip = False
            continue
        if _REDIR.match(t):
            skip = "&" not in t
            continue
        if re.match(r"^\d*(?:>>?|<)\S", t):
            continue
        out.append(t)
    return out


def _base(w: str) -> str:
    return re.sub(r"\.exe$", "", re.split(r"[\\/]", w.strip())[-1].lower())


def _exe(w: str) -> bool:
    """w names the dfhack-run executable (a path may contain spaces and parentheses, not separators)."""
    return _base(w) == "dfhack-run" and not re.search(r"[;|&\n`\"']", w)


def _var_name(w: str) -> str:
    m = re.match(r"^[$%]\{?((?:env:)?[A-Za-z_][A-Za-z0-9_]*)", w.strip(), re.I)
    return re.sub(r"^env:", "", m.group(1).lower()) if m else ""


class _Env:
    """Shell variables (name -> value) and aliases of one command text that hold dfhack-run."""

    def __init__(self):
        self.vars: dict[str, str] = {}
        self.aliases: set[str] = set()

    def note(self, name: str, value: str) -> None:
        if _DFR.search(value):
            self.vars[re.sub(r"^env:", "", name.lower())] = value

    def expand(self, name: str) -> list[str]:
        """Words after dfhack-run in the variable's value: c="dfhack-run reveal"; $c -> ['reveal']."""
        words = self.vars.get(name, "").split()
        k = next((i for i, w in enumerate(words) if _DFR.search(w)), len(words))
        return words[k + 1:]


def _dfr_tok(w: str, env: _Env, head: bool) -> tuple[list[str], bool] | None:
    """(words after dfhack-run inside the token, embedded) when token w invokes dfhack-run, else None.
    Embedded = dfhack-run inside program text such as ['dfhack-run','lua']."""
    if _exe(w):
        return [], False
    lw = w.strip().lower()
    if lw[:1] in ("$", "%"):
        name = _var_name(w)
        if name in env.vars:
            return env.expand(name), False
        if "dfhackrun" in re.sub(r"[^a-z]", "", name) or (head and "dfhack" in lw):
            return [], False
    if lw in env.aliases:
        return [], False
    if _DFR.search(w) and not _CODEY.search(w):
        parts = [p for p in (x.strip(_EDGE) for x in w.split(",")) if p]
        for k, p in enumerate(parts):
            if _exe(p):
                return parts[k + 1:], True
    return None


def _head(g: _Seg, env: _Env | None) -> tuple[int, bool]:
    """(index of the command word, pure) after wrappers and assignments; pure = the segment only assigns
    variables or aliases (recorded in env when given)."""
    toks, k, wrapped = g.toks, 0, False
    n = len(toks)
    while k < n:
        t = toks[k][0]
        tl = t.lower()
        m = _ASSIGN.match(t)
        if m:                                                    # bash: NAME=value [cmd]
            if env:
                env.note(m.group(1), m.group(2))
            k += 1
            continue
        m = _PS_ASSIGN.match(t)
        if m:                                                    # PowerShell: $name=value
            if env:
                env.note(m.group(1), m.group(2) + " " + " ".join(x for x, _ in toks[k + 1:]))
            return n, True
        if t.startswith("$") and k + 1 < n and toks[k + 1][0] == "=":   # PowerShell: $name = value
            val = [x for x, _ in toks[k + 2:]]
            if env:
                env.note(_var_name(t), " ".join(val))
            if len(val) <= 1:
                return n, True
            k, wrapped = k + 2, True                             # $o = & $dfr dfllm status
            continue
        if k == 0 and tl in _SET_WORDS:                          # export X=..., cmd: set X=...
            for x, _ in toks[1:]:
                m = _ASSIGN.match(x)
                if m and env:
                    env.note(m.group(1), m.group(2))
            return n, True
        if k == 0 and tl in _ALIAS_WORDS:                        # alias d=dfhack-run, Set-Alias d <path>
            words = [x for x, _ in toks[1:] if not x.startswith("-")]
            if words:
                name, val = words[0].split("=", 1) if "=" in words[0] else (words[0], " ".join(words[1:]))
                if env and _DFR.search(val):
                    env.aliases.add(name.lower())
            return n, True
        if tl in _SKIP_HEADS:
            k, wrapped = k + 1, True
            continue
        if wrapped and (t.startswith("-") or _DURATION.match(t)):
            k += 1
            continue
        break
    return k, k >= n


def _lint_cli(words: list[str]) -> bool:
    """`dfllm lint ...` / `python -m df_llm_helper[.lint] lint ...` only judges its arguments."""
    w = [x.lower() for x in words[:6]]
    if w[:2] == ["dfllm", "lint"]:
        return True
    if not w or _base(w[0]) not in ("python", "python3", "py", "pythonw") or "-m" not in w:
        return False
    rest = w[w.index("-m") + 1:]
    return rest[:1] == ["df_llm_helper.lint"] or rest[:2] == ["df_llm_helper", "lint"]


def _judge_text(text: str, env: _Env, depth: int, out: list, al: dict, in_sub: bool = False) -> None:
    if depth > _MAX_DEPTH:
        if _DFR.search(text):
            out.append(([], "unparsable"))
        return
    _judge(_lex(text, 0, depth)[0], env, depth, out, al, in_sub)


def _judge(segs: list[_Seg], env: _Env, depth: int, out: list, al: dict, in_sub: bool = False) -> None:
    """Append the dfhack-run calls of lexed segments to out. in_sub: the segments are a command
    substitution, whose output may be run (eval "$(echo dfhack-run x)", source <(echo ...))."""
    for gi, g in enumerate(segs):
        n0 = len(out)
        texts = [t for t, _ in g.toks]
        k, pure = _head(g, env)
        head = _base(texts[k]) if k < len(texts) else ""
        nxt = segs[gi + 1] if gi + 1 < len(segs) else None
        nk = _head(nxt, None)[0] if nxt else 0
        into_shell = g.end == "|" and nxt is not None and nk < len(nxt.toks) and _base(nxt.toks[nk][0]) in _SHELLS
        for sub in g.subs:
            _judge(sub, env, depth + 1, out, al, True)
        for body, expands in g.docs:                             # stdin of a shell is code; else data
            if head in _SHELLS or into_shell:
                _judge_text(body, env, depth + 1, out, al)
            elif expands:
                subs: list = []
                _dq_scan(body, 0, depth + 1, subs, stop=False)
                for sub in subs:
                    _judge(sub, env, depth + 1, out, al, True)
        if pure:
            continue
        if head in _MENTION or _lint_cli(texts[k:]):
            if into_shell or (in_sub and head in _ECHOERS):      # echo 'dfhack-run x' | bash
                _judge_text(" ".join(texts[k + 1:]), env, depth + 1, out, al)
            rx = _RUNS_ARG.get(head)                             # awk system(), sed e, git !alias, rg --pre
            if rx and _DFR.search(" ".join(texts)) and any(rx.search(t) for t in texts):
                out.append((texts, "unrecognised"))
            continue
        j, found = None, None
        for idx in range(k, len(texts)):
            found = _dfr_tok(texts[idx], env, head=idx == k)
            if found is not None:
                j = idx
                break
        for idx, (t, quoted) in enumerate(g.toks):               # bash -c "...", python -c "...", paths
            if quoted and (j is None or idx <= j) and _DFR.search(t) and _CODEY.search(t):
                _judge_text(t, env, depth + 1, out, al)
        if j is not None:
            rest, emb = found
            args = rest + [a.strip(_EDGE) if emb else a for a in texts[j + 1:]]
            args = _strip_redir([a for a in args if a])
            if args and args[0].startswith("-") and len(args[0]) > 1:
                kind = "unparsable"                              # Start-Process ... -ArgumentList
            elif not args and (g.end in ("(", ")", "{") or any(_base(t) in _ARGV_FEEDERS for t in texts[:j])):
                kind = "unparsable"                              # & (path) args, xargs, find -exec {}
            else:
                kind = "ok"
            out.append((args, kind))
        elif k + 1 < len(texts) and texts[k][:1] in ("$", "%") and _dfhack_word(texts[k + 1], al):
            out.append((texts[k + 1:], "ok"))                    # & $unknown reveal
        if len(out) == n0 and any(_DFR.search(t) for t in texts):
            out.append((texts, "unrecognised"))


def shell_invocations(text: str, al: dict | None = None) -> list[tuple[list[str], str]]:
    """Every dfhack-run call in shell text as (DFHack command tokens, 'ok'|'unparsable'|'unrecognised').
    A dfhack-run word is a call unless the command only mentions it (echo, grep, git commit -m, ls, ...);
    $( ), backticks, expanding heredocs and the code strings of bash -c / python -c are judged as well."""
    al = al or fairplay.allowlist()
    out: list[tuple[list[str], str]] = []
    _judge(_lex(text)[0], _Env(), 0, out, al)
    for m in _LISTFORM.finditer(text):                           # subprocess.run(['dfhack-run', 'lua', ...])
        items, j = [], m.end()
        while True:
            mi = _LISTITEM.match(text, j)
            if not mi:
                break
            items.append(mi.group(2))
            j = mi.end()
            if not mi.group(3):
                break
        out.append((" ".join(items).split(), "ok"))
    return out


def _dfhack_word(w: str, al: dict) -> bool:
    w = w.lstrip(":")
    if w.lower() in _SHELL_WORDS:
        return False
    first = {b.split()[0] for b in al["blocked"] if b.split()}
    return (w in al["commands"] or w in first or w in ("lua", "load-save", "script", "multicmd", "repeat")
            or re.match(r"^(claude|gui|devel|modtools|fix|internal)/", w) is not None)


def dfhack_line(toks: list[str], dev: bool = False, cwd: str | None = None, al: dict | None = None) -> tuple[bool, str]:
    """Shell-boundary policy for one DFHack command line (DESIGN §11.5)."""
    al = al or fairplay.allowlist()
    raw, toks = toks, [x for t in toks for x in t.split()]      # a quoted arg is judged word by word
    if not toks:
        return True, "dfhack-run without a command"
    head = toks[0].lstrip(":")
    b = fairplay.blocked_match([head] + toks[1:], al)
    if b:
        return False, f"blocked: {b}"
    if head == "lua":
        return False, "inline lua is not allowed (game writes go through the kernel; dev: dfllm selftest --exec)"
    if head == "claude" or head.startswith("claude/"):
        return False, "v1 claude/* scripts are retired in v2"
    if head == "dfllm":
        sub = toks[1] if len(toks) > 1 else ""
        if sub and sub not in DFLLM_SUBS:
            return False, f"dfllm {sub}: unknown in-game subcommand (allowed: {', '.join(sorted(DFLLM_SUBS))})"
        if "--exec" in toks:
            if not dev:
                return False, "dfllm selftest --exec needs DFLLM_DEV=1"
            k = raw.index("--exec") if "--exec" in raw else -1
            if k < 0 or k + 1 >= len(raw):
                return False, "dfllm selftest --exec: no file"
            f = Path(raw[k + 1])
            f = f if f.is_absolute() or not cwd else Path(cwd) / f
            if not f.is_file():
                return False, f"dfllm selftest --exec: no such file {f}"
            bad = lua([f], allowlist=al, exempt=False)
            if bad:
                x = bad[0]
                return False, f"dfllm selftest --exec: lint {x['rule']} at line {x['line']}: {x['msg']}"
            return True, "dev exec (linted; kern refuses it while the acceptance flag is set)"
        return True, "dfllm in-game command"
    if head == "load-save":
        return (len(toks) >= 2), ("load-save" if len(toks) >= 2 else "load-save needs a save folder")
    o = fairplay.owned_match([head] + toks[1:])
    if o:
        return False, (f"{o[0]}: owned by {o[1]} in the kernel (DESIGN §3); ask through an inbox verb "
                       "('python -m df_llm_helper cmd ...'), also with DFLLM_DEV=1")
    ok, why = fairplay.check_run(head, toks[1:], al)
    if not ok:
        return False, why
    if fairplay.is_read_only(head, al):
        return True, f"read-only: {head}"
    if dev:
        return True, f"dev write (DFLLM_DEV=1): {head}"
    return False, (f"{head}: game writes go through the kernel (act.run, 'python -m df_llm_helper cmd ...'); "
                   "DFLLM_DEV=1 allows allowlisted dev commands")


# ---------------------------------------------------------------- trust rules (CONTRACTS §13, R6)
# `by` in an inbox file is only a label, so the LLM must not claim another origin: `dfllm cmd` only with
# --by llm|cli, never `dfllm cmd audit` (follow sends audits), no hand-written inbox JSON with "by".
TRUST_BY = frozenset({"llm", "cli"})
_RUNTIME = re.compile(r"dfllm-runtime[\\/]", re.I)
_PY = ("python", "python3", "py", "pythonw")


def _dfllm_cmd_rest(words: list[str]) -> list[str] | None:
    """Words after `cmd` of `dfllm [opts] cmd ...` / `python -m df_llm_helper [opts] cmd ...`, else None."""
    lw = [w.lower() for w in words]
    i = None
    if lw and _base(lw[0]) == "dfllm":
        i = 1
    elif lw and _base(lw[0]) in _PY and "-m" in lw[:3]:
        j = lw.index("-m")
        if j + 1 < len(lw) and lw[j + 1] in ("df_llm_helper", "df_llm_helper.cli", "df_llm_helper.__main__"):
            i = j + 2
    if i is None:
        return None
    while i < len(lw) and lw[i].startswith("--"):          # global options: --runtime X --save X --df X
        i += 1 if "=" in lw[i] else 2
    return words[i + 1:] if i < len(lw) and lw[i] == "cmd" else None


def _trust_segs(segs: list, depth: int = 0) -> str | None:
    for g in segs:
        if depth < _MAX_DEPTH:
            for sub in g.subs:
                why = _trust_segs(sub, depth + 1)
                if why:
                    return why
        words = [t for t, _ in g.toks]
        k, _pure = _head(g, None)
        head = _base(words[k]) if k < len(words) else ""
        if head in _MENTION:                                # echo, grep, git commit -m "...": text only
            continue
        if depth < _MAX_DEPTH:                              # bash -c "...", python -c "...": nested code
            for t, quoted in g.toks:
                if quoted and ("dfllm" in t or "df_llm_helper" in t) and " " in t:
                    why = _trust_segs(_lex(t)[0], depth + 1)
                    if why:
                        return why
        rest = _dfllm_cmd_rest(words[k:])
        if rest is None:
            continue
        for i, w in enumerate(rest):
            by = rest[i + 1] if w == "--by" and i + 1 < len(rest) else (w[5:] if w.startswith("--by=") else None)
            if by is not None and by not in TRUST_BY:
                return f"dfllm cmd --by {by}: the LLM path sends only --by llm or cli (CONTRACTS §13)"
        verb = next((w for w in rest if not w.startswith("-")), None)
        if verb in schema.VERB_BY:
            return f"dfllm cmd {verb}: sent only by {'/'.join(schema.VERB_BY[verb])} (dfllm follow runs the audit)"
    return None


def trust_violation(text: str) -> str | None:
    """The first CONTRACTS §13 trust rule the shell text breaks, or None."""
    try:
        why = _trust_segs(_lex(text)[0])
    except (ValueError, RecursionError):
        why = None
    if why:
        return why
    if _RUNTIME.search(text) and re.search(r"inbox", text, re.I) and re.search(r"[\"']by[\"']\s*:", text):
        return "inbox JSON with \"by\" written by hand: use dfllm cmd (CONTRACTS §13)"
    return None


def file_write_violation(path: str) -> str | None:
    """Write/Edit tools: nothing under dfllm-runtime/ and no config/decisions.yaml (CONTRACTS §13)."""
    p = str(path or "").replace("\\", "/")
    parts = [x.lower() for x in p.split("/") if x]
    if "dfllm-runtime" in parts:
        return "files under dfllm-runtime/ are written by dfllm commands and the kernel, never by hand"
    if len(parts) >= 2 and parts[-2:] == ["config", "decisions.yaml"]:
        return "config/decisions.yaml holds Gordon's answers; only Gordon edits it"
    return None


def cmd(text: str, dev: bool | None = None, cwd: str | None = None, shell: bool | None = None,
        al: dict | None = None) -> tuple[bool, str]:
    """(allowed, reason) for shell text (shell=True: only dfhack-run calls matter) or, with shell=None
    and no dfhack-run call, for the text as a DFHack command line when it starts with a DFHack word.
    The CONTRACTS §13 trust rules (trust_violation) apply first."""
    why = trust_violation(text)
    if why:
        return False, why
    al = al or fairplay.allowlist()
    dev = os.environ.get("DFLLM_DEV") == "1" if dev is None else dev
    try:
        invs = shell_invocations(text, al)
        segs = _lex(text)[0] if not invs and not shell else []
    except (ValueError, RecursionError) as e:                    # pathological nesting: fail closed
        if "dfhack" in text.lower():
            return False, f"unparsable shell text ({type(e).__name__})"
        invs, segs = [], []
    if not invs and not shell:
        toks = [t for t, _ in segs[0].toks] if segs else []
        if toks and _dfhack_word(toks[0], al):
            invs = [(toks, "ok")]
    if not invs:
        return True, "no DF command"
    reasons = []
    for toks, kind in invs:
        if kind == "unparsable":
            return False, "unparsable dfhack-run call (use: dfhack-run <command> <args>)"
        if kind == "unrecognised":
            return False, "unrecognised dfhack-run use (call it directly: dfhack-run <command> <args>)"
        ok, why = dfhack_line(toks, dev=dev, cwd=cwd, al=al)
        if not ok:
            return False, why
        reasons.append(why)
    return True, "; ".join(reasons)


# ================================================================ CLI
def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--cmd" in argv:
        k = argv.index("--cmd")
        if k + 1 >= len(argv):
            print("--cmd needs a command line")
            return 2
        ok, why = cmd(argv[k + 1])
        print(("allowed: " if ok else "BLOCKED: ") + why)
        return 0 if ok else 1
    if argv[:1] == ["--config"]:
        errs = fairplay.decision_errors()
        try:
            fairplay.allowlist()
        except Exception as e:                               # noqa: BLE001 - report any invalid file
            errs.append(f"config/allowlist.json: {e}")
        print("\n".join(errs) or "config ok")
        return 1 if errs else 0
    as_json = "--json" in argv
    paths = [a for a in argv if a != "--json"] or [str(fairplay.REPO / "lua" / "dfllm")]
    if any(a.startswith("-") for a in paths):
        print(__doc__)
        return 2
    found = lua(paths)
    if as_json:
        print(json.dumps(found, indent=1))
    else:
        for f in found:
            print(f"{f['file']}:{f['line']}: {f['rule']} {f['msg']}")
        print(f"{len(found)} finding(s)")
    return 1 if found else 0


def __getattr__(name: str):
    """v1 compatibility: names of the archived v1 linter (RULES, lint_paths, gate_command, ...)."""
    if name.startswith("__"):
        raise AttributeError(name)
    from ._v1 import lint as _v1
    try:
        return getattr(_v1, name)
    except AttributeError:
        raise AttributeError(f"module {__name__!r} has no attribute {name!r}") from None


if __name__ == "__main__":
    sys.exit(main())
