"""Public inputs for the real Android package entry, without signing or SDK data."""
from pathlib import Path
import json
import shutil
import sys
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))
from verify_brand_identity import identity_fields
try:
    from .release_pipeline_test import context
except ImportError:
    from release_pipeline_test import context


def prepare_android_package_fixture(root, flavor):
    root = Path(root)
    tool = root / 'tool'
    (tool / 'identity').mkdir(parents=True, exist_ok=True)
    for name in ('release_pipeline.py', 'verify_brand_identity.py', 'identity/brands.json'):
        shutil.copyfile(ROOT / 'tool' / name, tool / name)
    identity = json.loads((tool / 'identity/brands.json').read_text(encoding='utf-8'))[flavor]
    (root / 'env.json').write_text(json.dumps(identity_fields(identity)), encoding='utf-8')
    (root / 'build').mkdir(exist_ok=True)
    (root / 'build/release-context.json').write_text(json.dumps(context(
        'android', '', base_version='0.0.0', build_number=101, flavor=flavor)), encoding='utf-8')
