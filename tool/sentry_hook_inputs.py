"""Discover captured Native Assets inputs; never trust arbitrary manifest paths."""
import json
from pathlib import Path


def rust_inputs(build_root: Path, platform: str):
    root = build_root.resolve()
    parent = root / 'sentry-hook-inputs' / platform
    records = []
    for manifest in sorted(parent.glob('*/manifest.json')):
        if manifest.is_symlink() or not manifest.resolve().is_relative_to(root):
            raise ValueError('unsafe_hook_manifest')
        data = json.loads(manifest.read_text(encoding='utf-8'))
        if data.get('schema_version') != 1 or data.get('platform') != platform or data.get('architecture') != manifest.parent.name:
            raise ValueError('invalid_hook_manifest_identity')
        if data['architecture'] not in {'arm', 'arm64', 'x64'}:
            raise ValueError('invalid_hook_architecture')
        files = []
        for name in [data.get('binary'), *data.get('companions', [])]:
            if not isinstance(name, str) or not name or Path(name).name != name or '/' in name or '\\' in name or name in {'.','..'}:
                raise ValueError('unsafe_hook_input_name')
            path = manifest.parent / name
            if path.is_symlink() or not path.exists() or not path.resolve().is_relative_to(root):
                raise ValueError('missing_or_unsafe_hook_input')
            files.append(path)
        records.append({'architecture':data['architecture'], 'binary':files[0], 'companions':files[1:]})
    return records
