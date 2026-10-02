"""Minimal pytest stand-in (only what the df-llm-helper tests use): fixture, mark.parametrize, mark.skipif, raises, approx, skip."""
import math


class _Skip(Exception):
    pass


def skip(reason=""):
    raise _Skip(reason)


def fixture(*a, **kw):
    def deco(fn):
        fn._is_fixture = True
        fn._fixture_scope = kw.get("scope", "function")
        return fn
    if a and callable(a[0]) and not kw:
        return deco(a[0])
    return deco


class _Mark:
    @staticmethod
    def parametrize(names, values, **kw):
        def deco(fn):
            fn.__dict__.setdefault("_params", []).append((names, list(values)))
            return fn
        return deco

    @staticmethod
    def skipif(cond, reason=""):
        def deco(fn):
            if cond:
                fn._skip = reason
            return fn
        return deco


mark = _Mark()


class raises:
    def __init__(self, exc, match=None):
        self.exc, self.match = exc, match
        self.value = None

    def __enter__(self):
        return self

    def __exit__(self, t, v, tb):
        if t is None:
            raise AssertionError(f"DID NOT RAISE {self.exc}")
        if not issubclass(t, self.exc):
            return False
        if self.match:
            import re
            if not re.search(self.match, str(v)):
                raise AssertionError(f"exception text {str(v)!r} does not match {self.match!r}")
        self.value = v
        return True


class approx:
    def __init__(self, expected, rel=None, abs=None):
        self.e, self.rel, self.abs = expected, rel, abs

    def __eq__(self, other):
        tol = self.abs if self.abs is not None else abs(self.e) * (self.rel if self.rel is not None else 1e-6)
        if self.abs is None and self.rel is None:
            tol = max(abs(self.e) * 1e-6, 1e-12)
        return math.isclose(other, self.e, abs_tol=tol, rel_tol=0)

    def __repr__(self):
        return f"approx({self.e})"
