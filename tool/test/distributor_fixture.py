"""Use the exact prepared/activated tool graph; never silently use submodule caches."""
import json
from pathlib import Path
from urllib.parse import urljoin

ROOT = Path(__file__).resolve().parents[2]
PREPARED = ROOT / 'build/packaging-tools/flutter_distributor/packages'
PACKAGES = PREPARED / 'flutter_distributor/.dart_tool/package_config.json'


def resolved_packages(config_path=PACKAGES, *, prepared=PREPARED):
    if not config_path.is_file():
        raise RuntimeError('Prepared distributor graph missing; prepare and activate before this check')
    config = json.loads(config_path.read_text(encoding='utf-8'))
    packages = {p['name']: {**p, 'rootUri': urljoin(config_path.resolve().as_uri(), p['rootUri'])}
                for p in config['packages']}
    for name in ('flutter_distributor', 'flutter_app_builder', 'flutter_app_packager',
                 'flutter_app_publisher', 'parse_app_package', 'shell_executor'):
        root = prepared / name
        item = packages.get(name, {})
        if (not (root / 'pubspec.yaml').is_file()
                or item.get('rootUri', '').rstrip('/') != root.resolve().as_uri()
                or item.get('packageUri') != 'lib/'):
            raise RuntimeError(f'Distributor graph does not use prepared source: {name}')
    return packages
