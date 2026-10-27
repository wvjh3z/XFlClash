"""Synthetic aapt values for parser tests; real AAPT fixture checked separately."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from check_android_release_contract import CRISP_CONTRACT


def resource_dump(package):
    lines=[]
    for i,(resource,name) in enumerate(CRISP_CONTRACT['resources'].items()):
        kind=resource.split('/')[0]
        value='<bag>' if kind=='style' else 't=0x12 d=0x00000000 (s=0x0008 r=0x00)'
        lines.append(f'        resource 0x{0x7f010001+i:08x} {package}:{kind}/{name}: {value}')
    return '\n'.join(lines)
