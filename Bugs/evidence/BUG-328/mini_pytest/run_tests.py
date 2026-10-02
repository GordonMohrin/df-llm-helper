"""Mini test runner for tests/ without pytest. Usage: python run_tests.py <repo_copy> [test_file_filter ...]"""
import importlib.util, inspect, io, itertools, os, re, shutil, sys, tempfile, traceback, time, contextlib
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))            # fake pytest first
repo = Path(sys.argv[1]).resolve()
filters = sys.argv[2:]
sys.path.insert(1, str(repo))
sys.path.insert(1, str(repo / "tests"))
sys.path.insert(1, str(repo / "tools"))
os.chdir(repo)
import pytest  # fake

TMP = Path(tempfile.mkdtemp(prefix="pt_", dir=os.environ.get("MINI_PYTEST_TMP") or None))   # set MINI_PYTEST_TMP=<folder with a space> to reproduce the path-with-space failures


class Capsys:
    def __init__(self):
        self.o, self.e = io.StringIO(), io.StringIO()
        self._so, self._se = sys.stdout, sys.stderr
        sys.stdout, sys.stderr = self.o, self.e
        self.pos_o = self.pos_e = 0

    def readouterr(self):
        a, b = self.o.getvalue()[self.pos_o:], self.e.getvalue()[self.pos_e:]
        self.pos_o, self.pos_e = len(self.o.getvalue()), len(self.e.getvalue())
        return type("R", (), {"out": a, "err": b})()

    def close(self):
        sys.stdout, sys.stderr = self._so, self._se


class Monkeypatch:
    def __init__(self):
        self.undo = []

    def setattr(self, target, name=None, value=None, raising=True):
        if isinstance(target, str):
            mod, attr = target.rsplit(".", 1)
            obj = importlib.import_module(mod)
            value, name = name, attr
            target = obj
        old = getattr(target, name, None)
        self.undo.append(("attr", target, name, old, hasattr(target, name)))
        setattr(target, name, value)

    def setenv(self, k, v):
        self.undo.append(("env", k, os.environ.get(k)))
        os.environ[k] = str(v)

    def delenv(self, k, raising=True):
        self.undo.append(("env", k, os.environ.get(k)))
        os.environ.pop(k, None)

    def chdir(self, p):
        self.undo.append(("cwd", os.getcwd()))
        os.chdir(p)

    def syspath_prepend(self, p):
        self.undo.append(("path", list(sys.path)))
        sys.path.insert(0, str(p))

    def setitem(self, d, k, v):
        self.undo.append(("item", d, k, d.get(k), k in d))
        d[k] = v

    def delattr(self, target, name, raising=True):
        self.undo.append(("attr", target, name, getattr(target, name, None), hasattr(target, name)))
        if hasattr(target, name):
            delattr(target, name)

    def close(self):
        for u in reversed(self.undo):
            if u[0] == "attr":
                _, t, n, old, had = u
                setattr(t, n, old) if had else (hasattr(t, n) and delattr(t, n))
            elif u[0] == "env":
                _, k, old = u
                os.environ.pop(k, None) if old is None else os.environ.__setitem__(k, old)
            elif u[0] == "cwd":
                os.chdir(u[1])
            elif u[0] == "path":
                sys.path[:] = u[1]
            elif u[0] == "item":
                _, d, k, old, had = u
                d[k] = old if had else d.pop(k, None)


def load_module(path):
    name = path.stem
    spec = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


conftest = load_module(repo / "tests" / "conftest.py")
counter = itertools.count()
module_cache = {}


def collect_fixtures(*mods):
    fx = {}
    for m in mods:
        for n, v in vars(m).items():
            if callable(v) and getattr(v, "_is_fixture", False):
                fx[n] = v
    return fx


def resolve(name, fixtures, ctx, cache, scope_cache):
    if name in cache:
        return cache[name]
    if name == "tmp_path":
        p = TMP / f"t{next(counter)}"
        p.mkdir(parents=True)
        cache[name] = p
        return p
    if name == "capsys":
        c = Capsys()
        ctx.append(c)
        cache[name] = c
        return c
    if name == "capfd":
        c = Capsys()
        ctx.append(c)
        cache[name] = c
        return c
    if name == "monkeypatch":
        mp = Monkeypatch()
        ctx.append(mp)
        cache[name] = mp
        return mp
    if name not in fixtures:
        raise LookupError(f"fixture {name!r} not found")
    fn = fixtures[name]
    if getattr(fn, "_fixture_scope", "function") == "module" and (id(fn)) in scope_cache:
        cache[name] = scope_cache[id(fn)]
        return cache[name]
    args = {p: resolve(p, fixtures, ctx, cache, scope_cache) for p in inspect.signature(fn).parameters}
    val = fn(**args)
    if inspect.isgenerator(val):
        gen = val
        val = next(gen)
        ctx.append(gen)
    if getattr(fn, "_fixture_scope", "function") == "module":
        scope_cache[id(fn)] = val
    cache[name] = val
    return val


def expand_params(fn):
    sets = [{}]
    for names, values in getattr(fn, "_params", []):
        names_l = [n.strip() for n in names.split(",")] if isinstance(names, str) else list(names)
        new = []
        for s in sets:
            for v in values:
                d = dict(s)
                if len(names_l) == 1:
                    d[names_l[0]] = v
                else:
                    for n, x in zip(names_l, v):
                        d[n] = x
                new.append(d)
        sets = new
    return sets


def main():
    results = {"pass": 0, "fail": 0, "skip": 0}
    failures = []
    t0 = time.time()
    files = sorted((repo / "tests").glob("test_*.py"))
    if filters:
        files = [f for f in files if any(x in f.name for x in filters)]
    for f in files:
        try:
            mod = load_module(f)
        except Exception:
            results["fail"] += 1
            failures.append((f.name, "<import>", traceback.format_exc()))
            print(f"{f.name}: IMPORT ERROR")
            continue
        fixtures = collect_fixtures(conftest, mod)
        scope_cache = {}
        fp = fs = ff = 0
        for name, fn in vars(mod).items():
            if not (name.startswith("test_") and callable(fn)):
                continue
            if hasattr(fn, "_skip"):
                fs += 1
                results["skip"] += 1
                continue
            for params in expand_params(fn):
                ctx, cache = [], dict(params)
                out_cap = None
                try:
                    sig = inspect.signature(fn).parameters
                    args = {p: resolve(p, fixtures, ctx, cache, scope_cache) for p in sig}
                    fn(**args)
                    fp += 1
                    results["pass"] += 1
                except pytest._Skip:
                    fs += 1
                    results["skip"] += 1
                except BaseException:
                    ff += 1
                    results["fail"] += 1
                    tb = traceback.format_exc()
                    failures.append((f.name, name + (f"[{params}]" if params else ""), tb))
                finally:
                    for c in reversed(ctx):
                        try:
                            if hasattr(c, "close"):
                                c.close()
                            elif inspect.isgenerator(c):
                                next(c, None)
                        except Exception:
                            pass
        print(f"{f.name}: pass={fp} fail={ff} skip={fs}")
    print(f"TOTAL pass={results['pass']} fail={results['fail']} skip={results['skip']} in {time.time()-t0:.1f}s")
    for fname, tname, tb in failures:
        print("=" * 70)
        print("FAIL", fname, tname)
        print(tb[-1800:])


if __name__ == '__main__':
    main()
