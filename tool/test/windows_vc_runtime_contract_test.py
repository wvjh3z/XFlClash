"""Installer/CI wiring guards; no ISCC or client compilation is performed."""
import json
from pathlib import Path
import re
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT / "tool"))
from checkout_distributor import RELATIVE as DISTRIBUTOR_SOURCE


def assert_prepare_order(template):
    """Keep prerequisite rejection ahead of the current brand's stop operation."""
    matches = re.findall(
        r"function\s+PrepareToInstall\([^;]+;\s*begin\b(.*?)\bend\s*;",
        template, re.S | re.I,
    )
    assert len(matches) == 1, "Expected one PrepareToInstall body"
    entry = matches[0]
    actions = [
        r"Result\s*:=\s*XbPrepareVCRuntime\(NeedsRestart\)\s*;",
        r"if\s+Result\s*<>\s*''\s+then\s+exit\s*;",
        r"UnregisterHelperService\s*;",
        r"KillProcesses\s*;",
        r"Result\s*:=\s*''\s*;",
    ]
    positions = []
    for action in actions:
        found = list(re.finditer(action, entry, re.I))
        assert len(found) == 1, "Required installer action missing or duplicated"
        positions.append(found[0].start())
    assert positions == sorted(positions), "Stop must follow prerequisite success"


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

    def test_installer_uses_actual_release_inputs_and_no_pubspec_fallback(self):
        template = self.read("windows/packaging/exe/inno_setup.iss")
        self.assertNotIn("AppVersion={{APP_VERSION}}", template)
        self.assertIn('#error "Run inject_desktop_brand', template)
        workflow = self.read(".github/workflows/release-package.yml")
        self.assertIn('--build-number "$BUILD_NUMBER"', workflow.split('- name: Inject desktop branding', 1)[1].split('- name:', 1)[0])
        local = self.read("scripts/package_desktop_local.sh")
        self.assertIn('--platform "${PLATFORM}" --build-number "${BUILD_NUMBER}"', local)
        self.assertIn('python3 tool/release_pipeline.py package', local)
        self.assertIn('python tool/release_pipeline.py package', workflow)

    def test_maker_source_path_contract(self):
        maker = self.read(str(DISTRIBUTOR_SOURCE / "packages/flutter_app_packager/lib/src/makers/exe/inno_setup/inno_setup_script.dart"))
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
        self.assertIn("function XbPrepareVCRuntime", source)
        template = self.read("windows/packaging/exe/inno_setup.iss")
        self.assertEqual(template.count("function PrepareToInstall("), 1)
        assert_prepare_order(template)
        self.assertIn("ExecAndCaptureOutput(PowerShellPath,", source)
        self.assertIn("{sysnative}\\WindowsPowerShell", source)
        self.assertIn("Params, ExpandConstant('{tmp}'), SW_HIDE", source)
        self.assertNotIn("ExecWithNativeSysDir", source)
        self.assertIn("finally\n    XbVcPage.Hide", source)
        self.assertNotIn("NeedsRestart := True", source)

    def test_prepare_order_accepts_checkout_newlines_and_spacing(self):
        template = self.read("windows/packaging/exe/inno_setup.iss")
        assert_prepare_order(template.replace("\n", "\r\n"))
        assert_prepare_order(template.replace("if Result <> '' then exit;", "if  Result<>''  then\n exit ;"))

    def test_prepare_order_rejects_early_stop_and_missing_failure_guard(self):
        template = self.read("windows/packaging/exe/inno_setup.iss")
        stop = "  UnregisterHelperService;\n  KillProcesses;\n  Result := '';"
        self.assertEqual(template.count(stop), 1)
        moved = template.replace(stop, "").replace("  Result := XbPrepareVCRuntime(NeedsRestart);", stop + "\n  Result := XbPrepareVCRuntime(NeedsRestart);")
        with self.assertRaises(AssertionError):
            assert_prepare_order(moved)
        with self.assertRaises(AssertionError):
            assert_prepare_order(template.replace("if Result <> '' then exit;", ""))
        with self.assertRaises(AssertionError):
            assert_prepare_order(template.replace("  KillProcesses;", ""))

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
        for kind, code, key in (("redist-launch", 4007, "Launch"), ("checker", 4008, "Check")):
            self.assertIn(f"(XbVcKind = '{kind}') and (Code = {code}) then Hint := CustomMessage('XbVc{key}')", installer)
        self.assertIn("if (XbVcLocalFailureCode <> 0) and (XbVcLocalFailureCode = Code)", installer)
        self.assertIn("if Code = 4009 then Result := CustomMessage('XbVcPrepare')", installer)
        self.assertIn("tool/test/windows_vc_runtime_process_test.ps1",
                      self.read(".github/workflows/release-package.yml"))

    def test_capture_keeps_stdout_stderr_and_raw_process_code(self):
        source = self.read('windows/packaging/exe/vc_runtime.iss')
        self.assertIn('Output: TExecOutput', source)
        self.assertIn("XbVcRawCode := Code", source)
        self.assertIn("XbVcHasRawCode := True", source)
        self.assertIn("'.stdout.txt', Output.StdOut", source)
        self.assertIn("'.stderr.txt', Output.StdErr", source)
        self.assertIn('XbVcCaptureError := Output.Error', source)
        self.assertNotIn('Exec(PowerShellPath,', source)
        self.assertIn('exit $LASTEXITCODE', source)
        self.assertIn('Write-Error -ErrorRecord $_ -ErrorAction Continue; exit 1', source)

    def test_protocol_is_diagnostic_not_a_success_gate(self):
        source = self.read('windows/packaging/exe/vc_runtime.iss')
        prepare = source.split('function XbPrepareVCRuntime(', 1)[1]
        self.assertIn('if Code <> 0 then begin', prepare)
        self.assertNotIn('Code := XbVcReportedCode', prepare)
        self.assertNotIn('Code := XbVcRedistCode', prepare)
        self.assertIn('if not XbVcHasReport or (XbVcReportedCode <> Code) then exit;', source)
        self.assertIn("Result := CustomMessage('XbVcUnclassified')", source)
        self.assertIn("(XbVcKind = 'redist-exit')", source)
        self.assertIn('(XbVcRedistCode = Code)', source)
        self.assertIn("Hint := CustomMessage('XbVcRedist')", source)

    def test_protocol_prefix_offsets_match_the_wire_format(self):
        source = self.read('windows/packaging/exe/vc_runtime.iss')
        expected = {'STAGE': 12, 'KIND': 11, 'RESULT': 13,
                    'REDIST_EXIT': 18, 'ERROR': 12, 'HOST': 11}
        for name, offset in expected.items():
            marker = f'XBVC_{name}='
            self.assertEqual(offset, len(marker) + 1)
            block = source.split(f"Pos('{marker}', Line) = 1", 1)[1]
            block = block.split('end else if', 1)[0].split('else if Pos', 1)[0]
            self.assertRegex(block, rf'Copy\(Line, {offset}, Length\(Line\)\)')

    def test_utf8_bootstrap_precedes_script_loading_and_quotes_paths(self):
        source = self.read('windows/packaging/exe/vc_runtime.iss')
        command = source.split('function XbVcCommand(', 1)[1].split('\nend;', 1)[0]
        self.assertLess(command.index('[Console]::OutputEncoding'), command.index("'try { & '"))
        for argument in ['ScriptPath', 'ConfigPath', 'PayloadPath', 'LogPath']:
            self.assertIn('XbVcPsQuote(' + argument + ')', command)
        self.assertIn("StringChangeEx(Value, '''', '''''', True);", source)
        self.assertIn(' -Command "', source)

    def test_copy_is_user_initiated_and_failures_cannot_replace_install_result(self):
        source = self.read('windows/packaging/exe/vc_runtime.iss')
        self.assertIn('if WizardSilent then exit;', source)
        self.assertIn('XbVcCopyButton.OnClick := @XbVcCopyDiagnostics', source)
        self.assertIn('XbVcCopyMemo.SelectAll', source)
        self.assertNotIn('XbVcCopyMemo.CopyToClipboard', source)
        self.assertIn('SendMessage(XbVcCopyMemo.Handle, $0301, 0, 0)', source)
        self.assertIn('if XbVcClipboardSequence = BeforeCopy then', source)
        self.assertIn("CustomMessage('XbVcCopyFailed')", source)
        error = source.split('function XbVcError(', 1)[1].split('function XbPrepareVCRuntime', 1)[0]
        self.assertRegex(error, r'try\s+XbVcBuildDiagnostic\(Code\);\s+except')
        self.assertRegex(error, r'try\s+XbVcShowCopyButton;\s+except')

    def test_script_protocol_cannot_pollute_return_pipeline(self):
        source = self.read('tool/windows/vc_runtime.ps1')
        protocol = source.split('function Write-XbRuntimeProtocol', 1)[1].split('\nfunction ', 1)[0]
        self.assertIn('[Console]::Out.WriteLine', protocol)
        self.assertNotRegex(protocol, r'(?m)^\s*Write-Output\b')
        self.assertIn('Write-XbRuntimeCompletion $code', source)
        self.assertIn('Write-XbRuntimeCompletion 4008', source)
        self.assertIn('$script:XbRuntimeRedistExit = $process.ExitCode', source)

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
        self.assertIn("VC\\Runtimes\\' + $script:XbRuntimeArchitecture", source)

    def test_ci_preflight_and_mandatory_packaging_validation(self):
        source = self.read(".github/workflows/release-package.yml")
        preflight = source.index("Check distributor cold-start entrypoint")
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
