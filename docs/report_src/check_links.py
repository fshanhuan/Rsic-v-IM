# -*- coding: utf-8 -*-
"""Verify every relative markdown link in the workspace resolves."""
import io
import os
import re
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
bad, total = [], 0
for dp, dn, fn in os.walk(ROOT):
    dn[:] = [d for d in dn if d not in (".git", "_gh", "__pycache__")]
    for f in fn:
        if not f.endswith(".md"):
            continue
        p = os.path.join(dp, f)
        with io.open(p, encoding="utf-8", errors="replace") as fh:
            t = fh.read()
        for m in LINK.finditer(t):
            tgt = m.group(1).strip()
            if tgt.startswith(("http://", "https://", "mailto:", "#")):
                continue
            tgt = tgt.split("#")[0]
            if not tgt:
                continue
            total += 1
            q = os.path.normpath(os.path.join(dp, tgt))
            if not os.path.exists(q):
                bad.append("%s -> %s" % (os.path.relpath(p, ROOT), tgt))

print("checked %d relative links, broken: %d" % (total, len(bad)))
for b in bad:
    print("  BROKEN", b)
sys.exit(1 if bad else 0)
