"""Installer/CI wiring guards; no ISCC or client compilation is performed."""
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class RuntimeContractTest(unittest.TestCase):
    def read(self, name):
        return (ROOT / name).read_text(encoding="utf-8")

    def test_shared_entry_and_windows_floor(self):
        source = self.read("windows/packaging/exe/inno_setup.iss")
        self.assertIn('#define XbBundle "{{SOURCE_DIR}}"', source)
        self.assertIn('#include "..\\windows\\packaging\\exe\\vc_runtime.iss"', source)
        self.assertIn("MinVersion=10.0", source)
        for brand in ("brand_a", "brand_b"):
            self.assertTrue((ROOT / f"flavors/{brand}/windows_installer.yaml").is_file())
        config = self.read("windows/packaging/exe/make_config.yaml")
        self.assertIn("script_template: inno_setup.iss", config)
        self.assertIn("privileges_required: admin", config)

    def test_maker_source_path_contract(self):
        maker = self.read("plugins/flutter_distributor/packages/flutter_app_packager/lib/src/makers/exe/inno_setup/inno_setup_script.dart")
        self.assertIn("'SOURCE_DIR': makeConfig.sourceDir", maker)
        self.assertIn("File('${makeConfig.packagingDirectory.path}.iss')", maker)
        source = self.read("windows/packaging/exe/vc_runtime.iss")
        # Includes aren't processed by Liquid: do not leave template variables there.
        self.assertNotIn("{{", source)
        self.assertIn('AddBackslash(SourcePath) + XbBundle', source)
        self.assertNotIn('ExpandFileName', source)
        self.assertIn('ExtractFileDir(RemoveBackslashUnlessRoot(SourcePath))', source)
        self.assertIn('#error "VC runtime preparation failed', source)

    def test_prerequisites_are_embedded_not_installed_as_app_files(self):
        source = self.read("windows/packaging/exe/vc_runtime.iss")
        entries = [line for line in source.splitlines() if line.startswith("Source:")]
        self.assertEqual(len(entries), 3)
        self.assertTrue(all("dontcopy" in line and "DestDir:" not in line for line in entries))
        self.assertIn("nocompression", entries[0])
        self.assertNotIn("[UninstallRun]", source)
        self.assertNotIn("[Run]", source)
        self.assertIn("function PrepareToInstall", source)
        self.assertIn("Exec(PowerShellPath,", source)
        self.assertIn("{sysnative}\\WindowsPowerShell", source)
        self.assertIn("Params, ExpandConstant('{tmp}'), SW_HIDE", source)
        self.assertNotIn("ExecWithNativeSysDir", source)
        self.assertIn("finally\n    XbVcPage.Hide", source)
        self.assertNotIn("NeedsRestart := True", source)

    def test_errors_localized_and_reentry_does_not_launch_another_installer(self):
        source = self.read("windows/packaging/exe/vc_runtime.iss")
        zh = set(re.findall(r"^chineseSimplified\.(XbVc\w+)=", source, re.M))
        en = set(re.findall(r"^english\.(XbVc\w+)=", source, re.M))
        self.assertEqual(zh, en)
        self.assertTrue(set(re.findall(r"CustomMessage\('(XbVc\w+)'\)", source)) <= zh)
        self.assertLess(source.index("if XbVcStopCode <> 0"), source.index("ExtractTemporaryFile"))
        self.assertIn("XbVcStopCode := Code", source)

    def test_process_diagnostics_and_launch_boundary(self):
        source = self.read("tool/windows/vc_runtime.ps1")
        self.assertIn("$start.WorkingDirectory = [IO.Path]::GetDirectoryName", source)
        self.assertIn("return 4007", source)
        self.assertIn("exit 4008", source)
        self.assertNotIn("exit 4005", source)
        for field in ("nativeError=", "readiness-before", "readiness-after",
                      "registryReady=", "filesReady=", "dll=$name", "registry=$view"):
            self.assertIn(field, source)
        installer = self.read("windows/packaging/exe/vc_runtime.iss")
        for code, key in ((4007, "Launch"), (4008, "Check"), (4009, "Prepare")):
            self.assertIn(f"{code}: Hint := CustomMessage('XbVc{key}')", installer)
        self.assertIn("tool/test/windows_vc_runtime_process_test.ps1",
                      self.read(".github/workflows/release-package.yml"))

    def test_default_config_has_separate_supported_minimum(self):
        config = json.loads(self.read("tool/windows/vc_runtime.json"))
        self.assertEqual(config["architecture"], "x64")
        self.assertLess(tuple(map(int, config["minimumVersion"].split('.'))),
                        tuple(map(int, config["bundledVersion"].split('.'))))
        self.assertRegex(config["sha256"], r"^[a-f0-9]{64}$")
        self.assertNotIn("aka.ms", config["url"])

    def test_host_side_security_and_no_runtime_download(self):
        source = self.read("tool/windows/vc_runtime.ps1")
        self.assertNotIn("Invoke-WebRequest", source)
        self.assertNotIn("/uninstall", source)
        self.assertIn("/quiet /norestart", source)
        self.assertIn("WaitForExit(600000)", source)
        self.assertNotIn(".Kill(", source)
        self.assertIn("RegistryView]::Registry64", source)
        self.assertIn("RegistryView]::Registry32", source)
        self.assertIn("VC\\Runtimes\\x64", source)

    def test_ci_preflight_and_mandatory_packaging_validation(self):
        source = self.read(".github/workflows/release-package.yml")
        preflight = source.index("Preflight both Windows installers with real ISCC")
        self.assertLess(source.index("Activate flutter_distributor"), preflight)
        self.assertLess(preflight, source.index("Package (flutter_distributor)"))
        self.assertIn("build/windows-iscc-preflight.json", source)
        self.assertLess(source.index("Fetch verified offline VC runtime"), source.index("Package (flutter_distributor)"))
        self.assertIn("tool/test/windows_vc_runtime_test.ps1", source)
        self.assertIn("tool/test/windows_vc_runtime_contract_test.py", source)
        for name in ("Check Windows runtime prerequisite rules", "Fetch verified offline VC runtime"):
            block = source.split("- name: " + name, 1)[1].split("- name:", 1)[0]
            self.assertIn("if: matrix.platform == 'windows'", block)
            self.assertIn("shell: powershell", block)
        prepare = self.read("tool/windows/prepare_vc_runtime.ps1")
        self.assertIn("Get-AuthenticodeSignature", prepare)
        self.assertIn("Test-XbCompilerPolicy", prepare)
        self.assertIn("Test-XbBundleArchitecture", prepare)
        self.assertIn("Assert-XbToolchainRuntime", prepare)


if __name__ == "__main__":
    unittest.main()
