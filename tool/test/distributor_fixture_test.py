"""Cold graph and stale local/global caches must behave like the formal entrypoint."""
import json
from pathlib import Path
import tempfile
import unittest

try:
    from . import distributor_fixture as fixture
    from . import windows_iscc_preflight as iscc
except ImportError:
    import distributor_fixture as fixture
    import windows_iscc_preflight as iscc

NAMES = ('flutter_distributor', 'flutter_app_builder', 'flutter_app_packager', 'flutter_app_publisher', 'parse_app_package', 'shell_executor')


def graph_fixture(root):
    prepared = root / 'build/packaging-tools/flutter_distributor/packages'
    config = prepared / 'flutter_distributor/.dart_tool/package_config.json'
    config.parent.mkdir(parents=True)
    for name in NAMES:
        path = prepared / name; path.mkdir(exist_ok=True)
        (path / 'pubspec.yaml').write_text('name: ' + name, encoding='utf-8')
    rows = [{'name': name, 'rootUri': '../../' + name, 'packageUri': 'lib/'} for name in NAMES]
    rows.append({'name': 'shell_uikit', 'rootUri': (root/'hosted/shell_uikit').as_uri(), 'packageUri': 'lib/'})
    config.write_text(json.dumps({'packages': rows}), encoding='utf-8')
    return prepared, config, rows


class DistributorGraphTests(unittest.TestCase):
    def test_cold_prepared_graph_with_or_without_poisoned_submodule_and_global_cache(self):
        with tempfile.TemporaryDirectory(prefix='graph 中文 ') as temporary:
            root = Path(temporary)
            prepared, config, rows = graph_fixture(root)
            for poison in (False, True):
                if poison:
                    for relative in ('plugins/flutter_distributor/packages/flutter_distributor/.dart_tool/package_config.json',
                                     'cache/global_packages/flutter_distributor/.dart_tool/package_config.json'):
                        path = root / relative; path.parent.mkdir(parents=True)
                        path.write_text('not valid JSON', encoding='utf-8')
                actual = fixture.resolved_packages(config, prepared=prepared)
                self.assertEqual(actual['shell_executor']['rootUri'], (prepared/'shell_executor').as_uri())
                self.assertEqual(actual['shell_uikit']['rootUri'], (root/'hosted/shell_uikit').as_uri())
                self.assertEqual(iscc.find_packages(root), config)
            config.unlink()
            with self.assertRaisesRegex(RuntimeError, 'missing'): iscc.find_packages(root)

    def test_stale_mixed_graph_and_missing_prepared_source_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); prepared, config, rows = graph_fixture(root)
            for name in NAMES:
                broken = [dict(row) for row in rows]
                next(row for row in broken if row['name'] == name)['rootUri'] = (root/'plugins'/name).as_uri()
                config.write_text(json.dumps({'packages': broken}), encoding='utf-8')
                with self.assertRaisesRegex(RuntimeError, name): iscc.find_packages(root)
            config.write_text(json.dumps({'packages': rows}), encoding='utf-8')
            (prepared/'shell_executor/pubspec.yaml').unlink()
            with self.assertRaisesRegex(RuntimeError, 'shell_executor'): iscc.find_packages(root)


if __name__ == '__main__': unittest.main()
