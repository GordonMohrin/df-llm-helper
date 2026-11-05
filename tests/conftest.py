"""Shared test setup."""
import pytest


@pytest.fixture(autouse=True)
def _no_automatic_snapshot(monkeypatch):
    """BUG-369: `bp sites`, `plan` and `cmd bp.place` ask the kernel for a new snapshot when the cached one predates a finished
    stage and the heartbeat is fresh. The fixture runtimes have both and no kernel that answers: the request would wait for
    its timeout in every test that ranks. test_bug368_370_depot_fresh_walk.py switches it on again."""
    from dfpilot import cmd
    monkeypatch.setattr(cmd, "AUTO_SNAP", False)


@pytest.fixture(autouse=True)
def _no_orphan_sweep(request, monkeypatch):
    """BUG-442: follow's sweep and `plan apply` ask the kernel about old bp files (`inspect persist key=bp.<id>`); the fixture runtimes
    keep old bp files and no kernel answers, so their inbox would hold an extra `inspect`. Tests marked `orphans` get the real thing."""
    if request.node.get_closest_marker("orphans"):
        return
    from dfpilot import cmd
    monkeypatch.setattr(cmd, "orphan_candidates", lambda *a, **k: [])
