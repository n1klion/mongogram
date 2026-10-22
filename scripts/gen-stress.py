#!/usr/bin/env python3
"""Generates a large synthetic Moon Modeler model for performance testing.
Usage: scripts/gen-stress.py [collections] [refs] > stress.dmm"""
import os, random, sys
sys.path.insert(0, os.path.dirname(__file__))
from dmm import Model

n = int(sys.argv[1]) if len(sys.argv) > 1 else 800
refs = int(sys.argv[2]) if len(sys.argv) > 2 else 1200
rng = random.Random(7)
types = ["String", "Number", "Boolean", "Date", "ObjectId"]
m = Model("stress", rng)
ids, positions = [], {}
for i in range(n):
    fields = [("_id", "ObjectId", {"pk"})] + [(f"field{c}", rng.choice(types), {"nn"} if rng.random() < 0.6 else set())
                                              for c in range(rng.randint(6, 18))]
    fields.append(("ownerId", "ObjectId", {"nn"}))
    emb = None
    if rng.random() < 0.5:
        emb = m.table(f"c{i:04d}_meta", [(f"k{c}", rng.choice(types)) for c in range(rng.randint(2, 6))], "embedded", embeddable=True)
        fields.append(("meta", emb, {"list"} if rng.random() < 0.3 else set()))
    tid = m.table(f"c{i:04d}_{rng.choice(['users', 'orders', 'items', 'events', 'stats', 'offers'])}", fields, f"collection {i}")
    if emb:
        m.embed(tid, "meta", emb)
    ids.append((tid, emb))
cols = int(n ** 0.5)
for i, (tid, emb) in enumerate(ids):
    x, y = (i % cols) * 620, (i // cols) * 460
    positions[tid] = (x, y)
    if emb:
        positions[emb] = (x + 300, y)
for _ in range(refs):
    a = rng.randrange(1, n)
    m.ref(ids[a][0], "ownerId", ids[rng.randrange(0, a)][0]) if not m.col(ids[a][0], "ownerId")["fk"] else None
m.diagram("All", positions, width=270)
print(m.dumps())
