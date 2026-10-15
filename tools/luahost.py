"""Run Lua 5.3 files offline on DFHack's own lua53.dll (via ctypes).

lua53.dll exports C++-mangled names (``?lua_pcallk@@YAHPEAUlua_State@@HHH_JP6AH0H1@Z@Z``),
so the export table is parsed here and mapped to plain names. Every run gets a fresh
lua_State. ``print``/``io.write`` are captured, ``os.exit`` ends the chunk (not the
Python process) and a CPU-time hook aborts runaway scripts.

    python tools/luahost.py [--timeout S] [--path DIR]... file.lua [args...]
    python tools/luahost.py --tests tests/lua          # run all test_*.lua

Env: DFLLM_LUA53 = path to lua53.dll, else <DFLLM_DF>/hack/lua53.dll, else the author's Steam
DF install below. Native helpers for tests (global table ``luahost``): listdir, isdir, isfile,
mkdir_recursive, mtime, now_ms.

Without lua53.dll (Linux, CI) the same chunk runs in a Lua 5.3 interpreter (``DFLLM_LUA_BIN`` or ``lua5.3`` on PATH)
as a subprocess; the helpers are then plain Lua over POSIX tools (ls, test, mkdir -p, stat, /proc/uptime).
"""
from __future__ import annotations

import ctypes
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_DLL = Path(r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress\hack\lua53.dll")
TIMEOUT_EXIT = 124
SUMMARY = re.compile(r"^# passed (\d+), failed (\d+)\s*$", re.M)     # testlib T.done()


def dll_path() -> Path:
    if os.environ.get("DFLLM_LUA53"):
        return Path(os.environ["DFLLM_LUA53"])
    if os.environ.get("DFLLM_DF"):                       # the DF folder the rest of the tools use
        return Path(os.environ["DFLLM_DF"]) / "hack" / "lua53.dll"
    return DEFAULT_DLL


def pe_exports(path: Path) -> list[str]:
    """Names in the export table of a PE (x86/x64) DLL."""
    b = Path(path).read_bytes()
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    if b[pe:pe + 4] != b"PE\0\0":
        raise ValueError(f"not a PE file: {path}")
    nsec, = struct.unpack_from("<H", b, pe + 6)
    optsz, = struct.unpack_from("<H", b, pe + 20)
    opt = pe + 24
    magic, = struct.unpack_from("<H", b, opt)
    exp_rva, _ = struct.unpack_from("<II", b, opt + (112 if magic == 0x20B else 96))
    secs = [struct.unpack_from("<8sIIII", b, opt + optsz + 40 * i)[1:5] for i in range(nsec)]

    def off(rva: int) -> int:
        for vsz, va, rsz, raw in secs:
            if va <= rva < va + max(vsz, rsz):
                return rva - va + raw
        raise ValueError(f"rva {rva:#x} outside sections")

    e = off(exp_rva)
    nnames, = struct.unpack_from("<I", b, e + 24)
    anames, = struct.unpack_from("<I", b, e + 32)
    out = []
    for i in range(nnames):
        o = off(struct.unpack_from("<I", b, off(anames) + 4 * i)[0])
        out.append(b[o:b.index(b"\0", o)].decode("ascii"))
    return out


def demangle(name: str) -> str:
    """'?lua_settop@@YAXPEAUlua_State@@H@Z' -> 'lua_settop'; plain names unchanged."""
    if name.startswith("?") and "@@" in name:
        return name[1:name.index("@@")]
    return name


_P = ctypes.c_void_p
_I = ctypes.c_int
_SZ = ctypes.c_size_t
_CFUNC = ctypes.CFUNCTYPE(_I, _P)
# plain name -> (restype, argtypes)
_PROTOS = {
    "luaL_newstate": (_P, []),
    "luaL_openlibs": (None, [_P]),
    "luaL_loadbufferx": (_I, [_P, ctypes.c_char_p, _SZ, ctypes.c_char_p, ctypes.c_char_p]),
    "lua_pcallk": (_I, [_P, _I, _I, _I, ctypes.c_int64, _P]),
    "lua_pushlstring": (_P, [_P, ctypes.c_char_p, _SZ]),
    "lua_pushinteger": (None, [_P, ctypes.c_int64]),
    "lua_pushnil": (None, [_P]),
    "lua_pushboolean": (None, [_P, _I]),
    "lua_pushcclosure": (None, [_P, _CFUNC, _I]),
    "lua_createtable": (None, [_P, _I, _I]),
    "lua_setfield": (None, [_P, _I, ctypes.c_char_p]),
    "lua_setglobal": (None, [_P, ctypes.c_char_p]),
    "lua_rawseti": (None, [_P, _I, ctypes.c_int64]),
    "lua_tolstring": (_P, [_P, _I, ctypes.POINTER(_SZ)]),
    "lua_tointegerx": (ctypes.c_int64, [_P, _I, ctypes.POINTER(_I)]),
    "lua_type": (_I, [_P, _I]),
    "lua_gettop": (_I, [_P]),
    "lua_settop": (None, [_P, _I]),
    "lua_close": (None, [_P]),
}


class Lua:
    """Thin ctypes binding of the functions luahost needs."""

    def __init__(self, path: Path | None = None):
        path = Path(path or dll_path())
        if not path.is_file():
            raise FileNotFoundError(f"lua53.dll not found: {path} (set DFLLM_LUA53)")
        for d in (path.parent, path.parent.parent):
            if hasattr(os, "add_dll_directory") and d.is_dir():
                os.add_dll_directory(str(d))
        self.path = path
        self.lib = ctypes.CDLL(str(path))
        names = {demangle(n): n for n in pe_exports(path)}
        for plain, (res, args) in _PROTOS.items():
            if plain not in names:
                raise RuntimeError(f"{path.name} lacks export {plain}")
            f = self.lib[names[plain]]
            f.restype, f.argtypes = res, args
            setattr(self, plain, f)

    def tostr(self, L, idx: int) -> bytes | None:
        n = _SZ(0)
        p = self.lua_tolstring(L, idx, ctypes.byref(n))
        return None if not p else ctypes.string_at(p, n.value)

    def push(self, L, s: str | bytes) -> None:
        b = s.encode("utf-8") if isinstance(s, str) else s
        self.lua_pushlstring(L, b, len(b))


_lua: Lua | None = None


def get_lua() -> Lua:
    global _lua
    if _lua is None:
        _lua = Lua()
    return _lua


def _dll_ok() -> bool:
    try:
        get_lua()
        return True
    except (OSError, RuntimeError, ValueError):
        return False


def lua_binary() -> str | None:
    """A Lua 5.3 interpreter for hosts without lua53.dll: DFLLM_LUA_BIN, else lua5.3 on PATH."""
    b = os.environ.get("DFLLM_LUA_BIN")
    if b:
        return b if (os.path.isfile(b) or shutil.which(b)) else None
    return shutil.which("lua5.3")


def available() -> bool:
    return _dll_ok() or lua_binary() is not None


@dataclass
class Result:
    code: int
    out: str
    err: str

    @property
    def ok(self) -> bool:
        return self.code == 0


# Runs inside the fresh state: (script, timeout_s, path_prefix, args...) -> code, out, err
_BOOT = r"""
local script, timeout_s, prefix = ...
local argv = table.pack(select(4, ...))
package.path = prefix .. package.path
package.cpath = ''
local out, n = {}, 0
local function put(s) n = n + 1; out[n] = s end
function print(...)
  local t = table.pack(...)
  for i = 1, t.n do t[i] = tostring(t[i]) end
  put(table.concat(t, '\t', 1, t.n) .. '\n')
end
io.write = function(...)
  local t = table.pack(...)
  for i = 1, t.n do put(tostring(t[i])) end
  return io.stdout
end
local EXIT = {}
os.exit = function(code)
  if code == nil or code == true then code = 0 elseif code == false then code = 1 end
  error(setmetatable({code = math.tointeger(code) or 1}, EXIT), 0)
end
arg = {[0] = script}
for i = 1, argv.n do arg[i] = argv[i] end
local chunk, lerr = loadfile(script)
if not chunk then return 2, table.concat(out), tostring(lerr) end
local limit = tonumber(timeout_s) or 0
if limit > 0 then
  local deadline = os.clock() + limit
  debug.sethook(function()
    if os.clock() > deadline then debug.sethook(); error('luahost: timeout after ' .. limit .. ' s', 2) end
  end, '', 100000)
end
local function handler(e)
  if getmetatable(e) == EXIT then return e end
  return debug.traceback(tostring(e), 2)
end
local ok, err = xpcall(chunk, handler, table.unpack(argv, 1, argv.n))
debug.sethook()
if ok then return 0, table.concat(out), '' end
if getmetatable(err) == EXIT then return err.code, table.concat(out), '' end
local code = tostring(err):find('luahost: timeout', 1, true) and 124 or 1
return code, table.concat(out), tostring(err)
"""


def _natives(lua: Lua):
    """C callbacks for the global 'luahost' table. They never raise into Lua."""

    def arg_str(L, i=1):
        b = lua.tostr(L, i)
        return None if b is None else b.decode("utf-8", "replace")

    def wrap(fn):
        def cb(L):
            try:
                return fn(L)
            except Exception:  # noqa: BLE001 - must not propagate into C
                lua.lua_pushnil(L)
                return 1
        return _CFUNC(cb)

    def listdir(L):
        p = arg_str(L)
        names = sorted(os.listdir(p)) if p and os.path.isdir(p) else []
        lua.lua_createtable(L, len(names), 0)
        for i, nm in enumerate(names, 1):
            lua.push(L, nm)
            lua.lua_rawseti(L, -2, i)
        return 1

    def boolfn(pred):
        def f(L):
            p = arg_str(L)
            lua.lua_pushboolean(L, 1 if p and pred(p) else 0)
            return 1
        return f

    def mkdirs(p):
        os.makedirs(p, exist_ok=True)
        return True

    def mtime(L):
        p = arg_str(L)
        lua.lua_pushinteger(L, int(os.path.getmtime(p)) if p and os.path.exists(p) else -1)
        return 1

    def now_ms(L):
        lua.lua_pushinteger(L, int(time.monotonic() * 1000))
        return 1

    return {
        "listdir": wrap(listdir),
        "isdir": wrap(boolfn(os.path.isdir)),
        "isfile": wrap(boolfn(os.path.isfile)),
        "mkdir_recursive": wrap(boolfn(mkdirs)),
        "mtime": wrap(mtime),
        "now_ms": wrap(now_ms),
    }


def lua_path_prefix(extra: list[str | Path] | None = None) -> str:
    dirs = [Path(d) for d in (extra or [])] + [REPO / "lua"]
    return "".join(f"{d.as_posix()}/?.lua;{d.as_posix()}/?/init.lua;" for d in dirs)


# pure-Lua 'luahost' helpers for the interpreter fallback (same results as the C callbacks in _natives)
_NATIVES_LUA = r"""
local function q(s) return "'" .. (tostring(s):gsub("'", "'\\''")) .. "'" end
local function sh(cmd) local r = os.execute(cmd) return r == true or r == 0 end
luahost = {}
function luahost.listdir(p)
  local t = {}
  if type(p) ~= 'string' or not sh('test -d ' .. q(p)) then return t end
  local f = io.popen('ls -1A ' .. q(p) .. ' 2>/dev/null')
  if f then for l in f:lines() do t[#t + 1] = l end f:close() end
  table.sort(t)
  return t
end
function luahost.isdir(p) return type(p) == 'string' and sh('test -d ' .. q(p)) end
function luahost.isfile(p) return type(p) == 'string' and sh('test -f ' .. q(p)) end
function luahost.mkdir_recursive(p) return type(p) == 'string' and sh('mkdir -p ' .. q(p)) end
function luahost.mtime(p)
  if type(p) ~= 'string' then return -1 end
  local f = io.popen('stat -c %Y ' .. q(p) .. ' 2>/dev/null')
  local v = f and f:read('n')
  if f then f:close() end
  return math.tointeger(v) or -1
end
function luahost.now_ms()
  local f = io.open('/proc/uptime')
  local v = f and f:read('n')
  if f then f:close() end
  return math.floor((v or os.clock()) * 1000)
end
"""

_runner_file: Path | None = None


def _runner() -> Path:
    """The interpreter-side bootstrap: helpers + _BOOT; prints the captured output and exits with its code."""
    global _runner_file
    if _runner_file is None or not _runner_file.is_file():
        assert "]==]" not in _BOOT
        src = (_NATIVES_LUA + "local real_out, real_err, real_exit = io.stdout, io.stderr, os.exit\n"
               + "local boot = assert(load([==[" + _BOOT + "]==], '=luahost', 't'))\n"
               + "local code, out, err = boot(table.unpack(arg, 1, #arg))\n"
               + "real_out:write(out or '') real_err:write(err or '') real_out:flush() real_err:flush()\n"
               + "real_exit(math.tointeger(code) or 1, true)\n")
        fd, name = tempfile.mkstemp(prefix="luahost_", suffix=".lua")
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(src)
        _runner_file = Path(name)
    return _runner_file


def _run_binary(binary: str, path: str | Path, args, timeout: float, paths) -> Result:
    script = Path(path).resolve().as_posix()
    argv = [binary, str(_runner()), script, str(timeout), lua_path_prefix(paths)] + [str(a) for a in args]
    try:
        p = subprocess.run(argv, capture_output=True, timeout=(timeout + 15) if timeout > 0 else None)
    except subprocess.TimeoutExpired:
        return Result(TIMEOUT_EXIT, "", f"luahost: timeout after {timeout} s")
    return Result(p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"))


def run_file(path: str | Path, args: list[str] | tuple = (), *, timeout: float = 30.0,
             paths: list[str | Path] | None = None) -> Result:
    """Run one Lua file in a fresh state. package.path = paths + <repo>/lua."""
    if not _dll_ok():
        binary = lua_binary()
        if binary is None:
            get_lua()                                    # raises the lua53.dll error
        return _run_binary(binary, path, args, timeout, paths)
    lua = get_lua()
    L = lua.luaL_newstate()
    if not L:
        raise MemoryError("luaL_newstate failed")
    try:
        lua.luaL_openlibs(L)
        natives = _natives(lua)
        lua.lua_createtable(L, 0, len(natives))
        for name, cb in natives.items():
            lua.lua_pushcclosure(L, cb, 0)
            lua.lua_setfield(L, -2, name.encode())
        lua.lua_setglobal(L, b"luahost")
        boot = _BOOT.encode()
        if lua.luaL_loadbufferx(L, boot, len(boot), b"=luahost", b"t") != 0:
            raise RuntimeError("luahost bootstrap failed to load: " + (lua.tostr(L, -1) or b"").decode())
        script = Path(path).resolve().as_posix()
        pushed = [script, str(timeout), lua_path_prefix(paths)] + [str(a) for a in args]
        for s in pushed:
            lua.push(L, s)
        status = lua.lua_pcallk(L, len(pushed), 3, 0, 0, None)
        if status != 0:  # only bootstrap failures land here
            return Result(3, "", (lua.tostr(L, -1) or b"?").decode("utf-8", "replace"))
        isnum = _I(0)
        code = lua.lua_tointegerx(L, -3, ctypes.byref(isnum))
        out = (lua.tostr(L, -2) or b"").decode("utf-8", "replace")
        err = (lua.tostr(L, -1) or b"").decode("utf-8", "replace")
        return Result(int(code) if isnum.value else 1, out, err)
    finally:
        lua.lua_close(L)


def run_tests(test_dir: str | Path, timeout: float = 60.0) -> int:
    """Run every test_*.lua in test_dir (with test_dir on package.path). Returns failed suites.
    The last line sums the suites and testlib's `# passed N, failed M` lines."""
    test_dir = Path(test_dir)
    suites, failures, passed, failed = 0, 0, 0, 0
    for f in sorted(test_dir.glob("test_*.lua")):
        r = run_file(f, timeout=timeout, paths=[test_dir])
        suites += 1
        for p, n in SUMMARY.findall(r.out):
            passed, failed = passed + int(p), failed + int(n)
        status = "ok" if r.ok else f"FAIL({r.code})"
        print(f"{status:9} {f.name}")
        if not r.ok:
            failures += 1
            sys.stdout.write(r.out)
            if r.err:
                print(r.err)
    print(f"{suites} suites ({failures} failed): {passed} passed, {failed} failed")
    return failures


def main(argv: list[str] | None = None) -> int:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--timeout", type=float, default=30.0)
    ap.add_argument("--path", action="append", default=[], help="extra package.path dir (repeatable)")
    ap.add_argument("--tests", metavar="DIR", help="run all test_*.lua in DIR")
    ap.add_argument("file", nargs="?")
    ap.add_argument("args", nargs=argparse.REMAINDER)
    a = ap.parse_args(argv)
    if a.tests:
        return 1 if run_tests(a.tests, a.timeout) else 0
    if not a.file:
        ap.error("file or --tests required")
    r = run_file(a.file, a.args, timeout=a.timeout, paths=a.path)
    sys.stdout.write(r.out)
    if r.err:
        sys.stderr.write(r.err + "\n")
    return r.code


if __name__ == "__main__":
    sys.exit(main())
