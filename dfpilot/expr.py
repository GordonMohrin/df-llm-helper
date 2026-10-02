"""Safe expression evaluation for rules/runbooks (no eval).

Allowed: comparisons, and/or/not, + - * / // %, constants, names, attribute/index access,
lists/tuples, function calls ONLY on functions from the context or the whitelist,
generator/list expressions with one `for` (e.g. `any(c.hunger > 40000 for c in citizens)`).
Missing values -> None; comparisons with None are False (except == / != / is).
"""
from __future__ import annotations

import ast
import operator
from dataclasses import is_dataclass
from typing import Any, Callable

__all__ = ["ExprError", "compile_expr", "evaluate", "names_used"]


class ExprError(ValueError):
    pass


_BIN = {ast.Add: operator.add, ast.Sub: operator.sub, ast.Mult: operator.mul, ast.Div: operator.truediv,
        ast.FloorDiv: operator.floordiv, ast.Mod: operator.mod}
_CMP = {ast.Lt: operator.lt, ast.LtE: operator.le, ast.Gt: operator.gt, ast.GtE: operator.ge}

_SAFE_FUNCS: dict[str, Callable] = {
    "len": lambda x: len(x) if x is not None else 0,
    "min": lambda *a: min((v for v in (a[0] if len(a) == 1 else a) if v is not None), default=None),
    "max": lambda *a: max((v for v in (a[0] if len(a) == 1 else a) if v is not None), default=None),
    "sum": lambda x: sum(v for v in x if v is not None) if x is not None else 0,
    "any": lambda x: any(x) if x is not None else False,
    "all": lambda x: all(x) if x is not None else False,
    "abs": lambda x: abs(x) if x is not None else None,
    "count": lambda x: sum(1 for v in x if v) if x is not None else 0,
    "lower": lambda s: str(s).lower() if s is not None else "",
    "contains": lambda hay, needle: (needle in hay) if hay is not None else False,
    "default": lambda x, d: d if x is None else x,
    "join": lambda xs, sep=", ": sep.join(str(x) for x in xs) if xs is not None else "",
    "str": lambda x: "" if x is None else str(x),
}

_ALLOWED = (ast.Expression, ast.BoolOp, ast.And, ast.Or, ast.UnaryOp, ast.Not, ast.USub, ast.UAdd,
            ast.BinOp, ast.Compare, ast.Eq, ast.NotEq, ast.Lt, ast.LtE, ast.Gt, ast.GtE, ast.In, ast.NotIn,
            ast.Is, ast.IsNot, ast.Constant, ast.Name, ast.Load, ast.Attribute, ast.Subscript, ast.List,
            ast.Tuple, ast.Slice, ast.Call, ast.GeneratorExp, ast.ListComp, ast.comprehension, ast.Store, ast.IfExp,
            *_BIN.keys())

_CACHE: dict[str, ast.Expression] = {}


def compile_expr(src: str) -> ast.Expression:
    if not isinstance(src, str) or not src.strip():
        raise ExprError("empty expression")
    if src in _CACHE:
        return _CACHE[src]
    try:
        tree = ast.parse(src.strip(), mode="eval")
    except SyntaxError as e:
        raise ExprError(f"syntax error in expression {src!r}: {e.msg}") from None
    for node in ast.walk(tree):
        if not isinstance(node, _ALLOWED):
            raise ExprError(f"element not allowed {type(node).__name__} in {src!r}")
        if isinstance(node, ast.Attribute) and node.attr.startswith("_"):
            raise ExprError(f"private attribute {node.attr!r} in {src!r}")
        if isinstance(node, ast.Call) and not isinstance(node.func, ast.Name):
            raise ExprError(f"only direct function calls allowed in {src!r}")
        if isinstance(node, ast.comprehension) and (node.is_async or not isinstance(node.target, ast.Name)):
            raise ExprError(f"only simple loops 'for x in y' allowed in {src!r}")
    _CACHE[src] = tree
    return tree


def names_used(src: str) -> set[str]:
    tree = compile_expr(src)
    bound = {g.target.id for n in ast.walk(tree) if isinstance(n, (ast.GeneratorExp, ast.ListComp))
             for g in n.generators}
    return {n.id for n in ast.walk(tree) if isinstance(n, ast.Name)} - bound - set(_SAFE_FUNCS)


def _get(obj: Any, key: Any) -> Any:
    if obj is None:
        return None
    if isinstance(obj, dict):
        return obj.get(key)
    if isinstance(obj, (list, tuple, str)):
        if isinstance(key, int) and -len(obj) <= key < len(obj):
            return obj[key]
        return None
    if isinstance(key, str) and not key.startswith("_"):
        val = getattr(obj, key, None)
        if callable(val) and not is_dataclass(val):
            return None
        return val
    return None


def evaluate(src: str, ctx: dict[str, Any]) -> Any:
    tree = compile_expr(src)
    return _Eval(ctx).visit(tree.body)


class _Eval:
    def __init__(self, ctx: dict[str, Any]):
        self.scopes = [ctx]

    def lookup(self, name: str) -> Any:
        for s in reversed(self.scopes):
            if name in s:
                return s[name]
        if name in _SAFE_FUNCS:
            return _SAFE_FUNCS[name]
        if name in ("True", "False", "None"):
            return {"True": True, "False": False, "None": None}[name]
        return None

    def visit(self, node: ast.AST) -> Any:
        m = getattr(self, "v_" + type(node).__name__, None)
        if m is None:
            raise ExprError(f"not supported: {type(node).__name__}")
        return m(node)

    def v_Constant(self, n):
        return n.value

    def v_Name(self, n):
        return self.lookup(n.id)

    def v_Attribute(self, n):
        return _get(self.visit(n.value), n.attr)

    def v_Subscript(self, n):
        base = self.visit(n.value)
        if isinstance(n.slice, ast.Slice):
            if not isinstance(base, (list, tuple, str)):
                return None
            lo, hi, st = (self.visit(x) if x is not None else None for x in (n.slice.lower, n.slice.upper, n.slice.step))
            return base[lo:hi:st]
        return _get(base, self.visit(n.slice))

    def v_List(self, n):
        return [self.visit(e) for e in n.elts]

    v_Tuple = v_List

    def v_IfExp(self, n):
        return self.visit(n.body) if self.visit(n.test) else self.visit(n.orelse)

    def v_BoolOp(self, n):
        if isinstance(n.op, ast.And):
            val = True
            for v in n.values:
                val = self.visit(v)
                if not val:
                    return val
            return val
        val = False
        for v in n.values:
            val = self.visit(v)
            if val:
                return val
        return val

    def v_UnaryOp(self, n):
        v = self.visit(n.operand)
        if isinstance(n.op, ast.Not):
            return not v
        if v is None:
            return None
        return -v if isinstance(n.op, ast.USub) else +v

    def v_BinOp(self, n):
        a, b = self.visit(n.left), self.visit(n.right)
        if a is None or b is None:
            return None
        try:
            return _BIN[type(n.op)](a, b)
        except ZeroDivisionError:
            return None
        except TypeError as e:
            raise ExprError(f"type error: {e}") from None

    def v_Compare(self, n):
        left = self.visit(n.left)
        for op, comp in zip(n.ops, n.comparators):
            right = self.visit(comp)
            if isinstance(op, (ast.Eq, ast.Is)):
                ok = left == right
            elif isinstance(op, (ast.NotEq, ast.IsNot)):
                ok = left != right
            elif isinstance(op, (ast.In, ast.NotIn)):
                ok = (left in right) if right is not None else False
                if isinstance(op, ast.NotIn):
                    ok = (not ok) if right is not None else True
            else:
                if left is None or right is None:
                    return False
                try:
                    ok = _CMP[type(op)](left, right)
                except TypeError:
                    return False
            if not ok:
                return False
            left = right
        return True

    def v_Call(self, n):
        fn = self.lookup(n.func.id)
        if not callable(fn):
            raise ExprError(f"unknown function {n.func.id!r}")
        args = [self.visit(a) for a in n.args]
        if n.keywords:
            raise ExprError("keyword arguments not allowed")
        return fn(*args)

    def _comp(self, n):
        gen = n.generators[0]
        if len(n.generators) != 1:
            raise ExprError("only one 'for' allowed")
        it = self.visit(gen.iter) or []
        out = []
        for item in it:
            self.scopes.append({gen.target.id: item})
            try:
                if all(self.visit(c) for c in gen.ifs):
                    out.append(self.visit(n.elt))
            finally:
                self.scopes.pop()
        return out

    v_GeneratorExp = _comp
    v_ListComp = _comp
