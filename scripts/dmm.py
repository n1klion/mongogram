"""Tiny builder for Moon Modeler (.dmm, MONGOOSE) files, used by gen-stress.py and to make samples/."""
import json, uuid


def _id(rng=None):
    return str(uuid.UUID(int=rng.getrandbits(128), version=4)) if rng else str(uuid.uuid4())


class Model:
    def __init__(self, name, rng=None):
        self.rng = rng
        self.name = name
        self.tables, self.relations, self.lines, self.order = {}, {}, {}, []
        self.diagrams = []  # (name, {tableId: item})

    def table(self, name, fields, desc="", embeddable=False):
        """fields: list of (name, datatype, flags) where flags is a set of 'pk', 'nn', 'list'
        and datatype may be another table's id (an embedded document)."""
        tid = _id(self.rng)
        cols = []
        for f in fields:
            name_, dt, flags = (f + ("",))[:3] if len(f) == 2 else f
            comment = ""
            if isinstance(flags, tuple):
                flags, comment = flags
            cols.append({"id": _id(self.rng), "name": name_, "datatype": dt, "param": "", "pk": "pk" in flags,
                         "nn": "nn" in flags or "pk" in flags, "list": "list" in flags, "fk": False,
                         "comment": comment, "data": "", "options": "", "estimatedSize": ""})
        keys = []
        if any(c["pk"] for c in cols):
            pk = next(c for c in cols if c["pk"])
            keys = [{"id": _id(self.rng), "name": "Primary", "isPk": True, "cols": [{"id": _id(self.rng), "colid": pk["id"]}]}]
        self.tables[tid] = {"id": tid, "visible": True, "name": name, "desc": desc, "estimatedSize": "", "cols": cols,
                            "relations": [], "lines": [], "keys": keys, "indexes": [], "embeddable": embeddable,
                            "generate": True, "generateCustomCode": True, "customCode": "", "others": ""}
        self.order.append(tid)
        return tid

    def col(self, tid, name):
        return next(c for c in self.tables[tid]["cols"] if c["name"] == name)

    def embed(self, parent, field, child):
        """Points `parent.field` (already typed with child's id) at the embeddable `child`."""
        lid = _id(self.rng)
        self.lines[lid] = {"id": lid, "name": "containment-line", "desc": "", "style": "dotted", "parent": parent, "child": child,
                           "parentTableColId": self.col(parent, field)["id"], "childTableColId": "", "lineColor": "transparent",
                           "markerStart": "none", "markerEnd": "none", "linegraphics": "default", "generate": True, "code": "", "caption": ""}
        self.tables[parent]["lines"].append(lid)
        self.tables[child]["lines"].append(lid)

    def ref(self, fk_table, fk_field, key_table, name=None):
        rid = _id(self.rng)
        fk = self.col(fk_table, fk_field)
        fk["fk"] = True
        key = self.tables[key_table]["keys"][0]
        self.relations[rid] = {"id": rid, "name": name or f"{self.tables[fk_table]['name']}_{self.tables[key_table]['name']}",
                               "type": "identifying", "parent": fk_table, "child": key_table, "parent_key": key["id"],
                               "cols": [{"id": _id(self.rng), "parentcol": fk["id"], "childcol": key["cols"][0]["colid"]}],
                               "c_p": "one", "c_ch": "many", "generate": True}
        self.tables[fk_table]["relations"].append(rid)
        self.tables[key_table]["relations"].append(rid)

    def diagram(self, name, positions, colors=None, width=240):
        """positions: {tableId: (x, y)}"""
        colors = colors or {}
        items = {}
        for tid, (x, y) in positions.items():
            t = self.tables[tid]
            items[tid] = {"referencedItemId": tid, "x": x, "y": y, "gHeight": 27 + 18 * len(t["cols"]), "gWidth": width,
                          "color": "#ffffff", "background": "transparent" if t["embeddable"] else colors.get(tid, "#03a9f4"),
                          "resized": False, "autoExpand": True, "backgroundOpacity": "10", "collapsed": False}
        self.diagrams.append((name, items))

    def dumps(self):
        dids = [_id(self.rng) for _ in self.diagrams]
        diagrams = {}
        for i, (did, (name, items)) in enumerate(zip(dids, self.diagrams)):
            diagrams[did] = {"name": name, "description": "", "id": did, "keysgraphics": True, "linegraphics": "detailed", "zoom": 1,
                             "background": "transparent", "lineColor": "transparent", "isOpen": True, "main": i == 0,
                             "scroll": {"x": 0, "y": 0}, "type": "erd", "diagramItems": items}
        doc = {"tables": self.tables, "relations": self.relations, "notes": {}, "lines": self.lines,
               "model": {"name": self.name, "id": _id(self.rng), "activeDiagram": dids[0] if dids else "", "desc": "", "path": "",
                         "type": "MONGOOSE", "version": 1, "storedin": {"major": 9, "minor": 7, "extra": 0}},
               "otherObjects": {}, "diagrams": diagrams, "diagramsOrder": dids, "order": self.order,
               "collapsedTreeItems": [], "reverseStats": {}}
        return json.dumps(doc, indent=2)
