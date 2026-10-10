"""Blueprint templates, validators, emitter, topo audit and site finder (WP3; CONTRACTS §9.8, §9.10, §15).

    from df_llm_helper import bp
    sites = bp.rank(snap, "bedrooms", {"n": 20}, manifest) # top 3 on revealed tiles (rooms need the manifest)
    doc = bp.emit("bedrooms", {"n": 20}, sites[0])        # §9.8 document without id
    bp.validate(doc)                                      # [] when the template passes the doctrine checks
    res = bp.audit(snap, manifest)                        # = `audit` verb args minus `snap`
    print(bp.preview("fortcore", {"stage": 3}))

Pure Python, no DF calls. Coordinates are absolute map tiles; see primitives.py for the local frame.
"""
from .emit import TEMPLATES, check_params, emit, emit_all, list_templates
from .render import as_built, ascii, preview
from .rooms import MOODABLE_TYPES
from .sites import rank
from .topo import audit
from .validate import Finding, check_doc, check_world, errors, validate

__all__ = ["TEMPLATES", "MOODABLE_TYPES", "Finding", "as_built", "ascii", "audit", "check_doc",
           "check_params", "check_world", "emit", "emit_all", "errors", "list_templates", "preview", "rank",
           "validate"]
