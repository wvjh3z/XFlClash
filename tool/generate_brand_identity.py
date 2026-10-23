#!/usr/bin/env python3
"""Generate the portable Dart view of the public brand identity catalog."""
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parent

def rendered():
    values=json.loads((ROOT/'identity/brands.json').read_text(encoding='utf-8'))
    return '// Generated from brands.json; run python3 tool/generate_brand_identity.py.\nconst brandIdentities = <String, Map<String, Object>>'+json.dumps(values,indent=2)+';\n'

if __name__=='__main__':
    output=ROOT/'identity/brands.dart'
    if '--check' in sys.argv:
        if output.read_text(encoding='utf-8') != rendered(): raise SystemExit('Generated brand catalog drift')
    else: output.write_text(rendered(),encoding='utf-8')
