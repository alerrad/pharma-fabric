#!/usr/bin/env python3
"""Краткий вывод партии из JSON (stdin): status, holder и др."""
import json, sys
try:
    b = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = b if isinstance(b, list) else [b]
for x in items:
    extra = f" releasedBy={x['releasedBy'].split(',')[0]}" if x.get("releasedBy") else ""
    print(f"{x['id']}: status={x['status']} holder={x['holderMSP']}{extra}")
