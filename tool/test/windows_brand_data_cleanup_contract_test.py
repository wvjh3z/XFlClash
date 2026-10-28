"""Installer cleanup wiring guards; never execute an installer or delete data."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CleanupWiringTests(unittest.TestCase):
    def text(self, name):
        return (ROOT / name).read_text(encoding='utf-8')

    def test_only_confirmed_interactive_uninstall_calls_cleanup(self):
        source = self.text('windows/packaging/exe/inno_setup.iss')
        self.assertNotIn('DelTree(', source)
        self.assertNotIn('RemoveDir(', source)
        self.assertNotIn('com.follow', source)
        self.assertEqual(len(re.findall(r'^\s+RemoveUserData;', source, re.M)), 1)
        entry = source.split('procedure CurUninstallStepChanged', 1)[1].split('[Languages]', 1)[0]
        self.assertIn('(CurUninstallStep = usUninstall) and not UninstallSilent', entry)
        self.assertIn('MB_YESNO or MB_DEFBUTTON2', entry)
        self.assertIn('= IDYES then', entry)
        install = source.split('function PrepareToInstall', 1)[1].split('function InitializeUninstall', 1)[0]
        self.assertNotIn('RemoveUserData', install)

    def test_installed_helpers_survive_until_cleanup_entry(self):
        source = self.text('windows/packaging/exe/inno_setup.iss')
        for name in ('remove_brand_user_data.ps1',):
            self.assertIn(f'Source: "{{#XbRoot}}tool\\windows\\{name}"; DestDir: "{{app}}\\maintenance"; Flags: ignoreversion', source)
            self.assertIn(f"{{app}}\\maintenance\\{name}", source)
        self.assertIn('ResultCode = 10', source)
        self.assertIn('XbDataIncomplete', source)

    def test_brand_slug_is_injected_from_shared_identity(self):
        source = self.text('tool/brand_identity.dart')
        self.assertIn('#define XbDataSlug "${id[\'slug\']}"', source)
        installer = self.text('windows/packaging/exe/inno_setup.iss')
        self.assertIn('-Brand "{#XbDataSlug}"', installer)
        self.assertNotRegex(installer, r'-Brand "(?:omofly|daishu)"')

    def test_native_tests_are_on_formal_windows_entry(self):
        workflow = self.text('.github/workflows/release-package.yml')
        self.assertIn('& tool/test/windows_brand_data_cleanup_test.ps1\n          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }', workflow)
        self.assertIn('python tool/test/windows_brand_data_cleanup_contract_test.py', workflow)
        self.assertLess(workflow.index('windows_brand_data_cleanup_test.ps1'), workflow.index('- name: Package (flutter_distributor)'))
        native = self.text('tool/test/windows_brand_data_cleanup_test.ps1')
        self.assertIn("'windows_brand_data_cleanup_race_test.ps1'", native)
        self.assertIn('if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }', native)


if __name__ == '__main__':
    unittest.main()
