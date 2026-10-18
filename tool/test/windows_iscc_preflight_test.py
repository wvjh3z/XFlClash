"""Offline guards for fixture scope; real ISCC tests run via the separate CLI."""
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
import windows_iscc_preflight as preflight


class PreflightTests(unittest.TestCase):
    def test_only_temporary_exec_boundary_changes_for_positive(self):
        path = preflight.ROOT / 'windows/packaging/exe/vc_runtime.iss'
        source = path.read_text(encoding='utf-8-sig')
        value = preflight.variant(source, 'positive')
        self.assertEqual(value.replace('#if XbPreflightExec(', '#if Exec(', 1), source)
        self.assertNotIn('XbPreflightExec', source)
        self.assertEqual(value.split('[Code]', 1)[1], source.split('[Code]', 1)[1])

    def test_both_old_errors_and_pascal_negative_are_independent(self):
        source = (preflight.ROOT / 'windows/packaging/exe/vc_runtime.iss').read_text(encoding='utf-8-sig')
        for case in ('old_root', 'old_bundle'):
            value = preflight.variant(source, case)
            self.assertEqual(value.count('ExpandFileName'), 1)
        self.assertIn('XbMissingPascalFunction;', preflight.variant(source, 'bad_pascal'))
        with self.assertRaises(RuntimeError):
            preflight.variant(source.replace('#if Exec(', '#if ChangedExec('), 'positive')

    def test_paths_are_checked_using_independent_manifest_and_quotes(self):
        with tempfile.TemporaryDirectory(prefix='iscc 中文 space ') as temporary:
            root = Path(temporary)
            header = preflight.fixture_header({'root': str(root), 'bundle': str(root/'dist/bundle space')}, True, 73)
            self.assertIn('中文 space', header)
            self.assertIn('Wait == 1 && Show == 0', header)
            self.assertIn('? 73 : 99', header)
            self.assertIn('-Bundle ""Z:', header)
            self.assertNotIn('ExtractFileDir', header)

    def test_real_compiler_call_disables_output_and_is_bounded(self):
        with mock.patch.object(preflight.subprocess, 'run', return_value=mock.Mock(returncode=0, stdout='ok', stderr='')) as run:
            self.assertEqual(preflight.compile_case(['ISCC.exe'], Path('fixture.iss'), False), (0, 'ok'))
        self.assertIn('/O-', run.call_args.args[0])
        self.assertEqual(run.call_args.kwargs['timeout'], 60)
        self.assertNotIn('shell', run.call_args.kwargs)

    def test_distributor_local_and_global_package_config_discovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            local = root/'plugins/flutter_distributor/packages/flutter_distributor/.dart_tool/package_config.json'
            global_config = root/'cache/global_packages/flutter_distributor/.dart_tool/package_config.json'
            data = json.dumps({'packages': [{'name': n} for n in ['flutter_app_packager','liquid_engine','args','yaml']]})
            with mock.patch.dict(os.environ, {'PUB_CACHE': str(root/'cache'), 'LOCALAPPDATA': str(root/'missing')}), \
                 mock.patch.object(Path, 'home', return_value=root/'missing'):
                with self.assertRaises(RuntimeError):
                    preflight.find_packages(root)
                global_config.parent.mkdir(parents=True);global_config.write_text(data)
                self.assertEqual(preflight.find_packages(root), global_config)
                local.parent.mkdir(parents=True);local.write_text(data)
                self.assertEqual(preflight.find_packages(root), global_config)
                global_config.unlink()
                self.assertEqual(preflight.find_packages(root), local)


if __name__ == '__main__':
    unittest.main()
