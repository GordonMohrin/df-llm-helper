"""Shared test helpers: snapshot/context from synthetic responses."""
from pathlib import Path

from dfpilot.anomaly import CancelLoop
from dfpilot.client import MAX_REPORT_ID_CMD, SERVICES_CMD, MockClient
from dfpilot.config import DEFAULTS
from dfpilot.rules import build_context
from dfpilot.snapshot import collect
from dfpilot.toolsfs import FlagInfo
from make_fixtures import responses

CMDS = list(DEFAULTS["collect"]["commands"]) + [MAX_REPORT_ID_CMD, SERVICES_CMD]


def snap_for(**kw):
    m = MockClient(responses(**kw))
    return collect(m, CMDS)


def ctx_for(*, cancels=None, flags=None, guard=None, files=None, **kw):
    s = snap_for(**kw)
    fl = {}
    for name, spec in (flags or {}).items():
        fl[name] = FlagInfo(name, True, spec.get("age_min", 1), spec.get("text", ""))
    cl = [CancelLoop(*c) if not isinstance(c, CancelLoop) else c for c in (cancels or [])]
    ctx = build_context(s, flags=fl, guard=guard or {"slowed": False, "target_fps": 250}, cfg=DEFAULTS, cancels=cl,
                        files=files or {"last_report_id": 4990, "heartbeat_age_min": 1, "events_age_min": 1})
    return ctx, s


ROOT = Path(__file__).resolve().parent.parent
