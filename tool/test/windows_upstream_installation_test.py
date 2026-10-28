"""Upstream lifecycle contracts and Windows native proxy policy fixture.

Never runs an installer or modifies registry/services/processes. The Windows
fixture compiles actual release/listening functions with controlled OS queries.
"""
import os
from pathlib import Path
import re
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def body(source, name):
    match = re.search(r'(?:function|procedure)\s+' + name + r'\b[^\n]*\nbegin\n(.*?)\nend;', source, re.S)
    assert match, name
    return re.sub(r'//[^\n]*\n\s*', '', match[1].strip())


def check_order(source):
    assert body(source, 'PrepareToInstall') == """Result := XbPrepareVCRuntime(NeedsRestart);
  if Result <> '' then exit;
  UnregisterHelperService;
  KillProcesses;
  Result := '';"""
    assert body(source, 'CurStepChanged') == 'if CurStep = ssPostInstall then\n    ClearStaleProxy;'
    assert body(source, 'InitializeUninstall') == 'UnregisterHelperService;\n  KillProcesses;\n  ClearStaleProxy;\n  Result := True;'
    for retired in ('RunOwnedInstallationPhase', 'XbFinalizeInstall', 'BeforeInstall:', 'DeinitializeSetup', 'stop_brand_installation.ps1'):
        assert retired not in source, retired


class InstallerTests(unittest.TestCase):
    def test_order_and_negative_controls(self):
        source = (ROOT / 'windows/packaging/exe/inno_setup.iss').read_text(encoding='utf-8')
        check_order(source)
        for old, new in [
            ('  UnregisterHelperService;\n  KillProcesses;', '  KillProcesses;\n  UnregisterHelperService;'),
            ('ssPostInstall', 'ssInstall'),
            ("  if Result <> '' then exit;", ''),
            ('  ClearStaleProxy;', ''),
        ]:
            with self.subTest(mutation=old), self.assertRaises(AssertionError):
                check_order(source.replace(old, new))

    def test_identity_and_upstream_launch_contract(self):
        source = (ROOT / 'windows/packaging/exe/inno_setup.iss').read_text(encoding='utf-8')
        self.assertIn("Exec('taskkill', '/f /im ' + Processes[i], '', SW_HIDE, ewWaitUntilTerminated, ResultCode)", source)
        self.assertIn("ChangeFileExt('{{EXECUTABLE_NAME}}', '') + 'Core.exe', '{#XbServiceName}.exe'", source)
        self.assertIn("Exec(HelperPath, 'uninstall', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)", source)
        self.assertIn("Exec(AppPath, '--clear-stale-proxy', '', SW_HIDE, ewWaitUntilTerminated, ResultCode)", source)
        self.assertNotIn('FlClash.exe', source)
        self.assertNotIn('FlClashHelperService', source)
        native = (ROOT / 'windows/runner/main.cpp').read_text(encoding='utf-8')
        self.assertLess(native.index('--clear-stale-proxy'), native.index('FlutterWindow'))
        self.assertIn('ProxyPluginClearStaleProxy()', native)

    def test_retired_script_and_formal_entry(self):
        self.assertFalse((ROOT / 'tool/windows/stop_brand_installation.ps1').exists())
        workflow = (ROOT / '.github/workflows/release-package.yml').read_text(encoding='utf-8')
        self.assertIn('python tool/test/windows_upstream_installation_test.py\n          if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }', workflow)

    @unittest.skipUnless(os.name == 'nt', 'Native MSVC fixture runs on Windows')
    def test_actual_native_proxy_policy_and_negative_control(self):
        from windows_loader_install_test import find_cmake
        from windows_title_encoding_test import run
        source = (ROOT / 'plugins/proxy/windows/proxy_plugin.cpp').read_text(encoding='utf-8')
        functions = source[source.index('bool IsPortListening('):source.index('bool ClearStaleProxyForConnection(')]
        self.assertIn('.value_or(true)', functions)
        prefix = '''#include <optional>
#include <initializer_list>
using ULONG = unsigned long;
constexpr int AF_INET = 2, AF_INET6 = 23;
std::optional<bool> v4, v6;
int sleeps = 0;
std::optional<bool> HasTcpListener(ULONG family, int) { return family == AF_INET ? v4 : v6; }
void Sleep(int) { ++sleeps; }
'''
        main = '''
int main() {
  for (int port : {17890, 27890}) {
    v4 = false; v6 = false; sleeps = 0;
    if (!IsPortReleased(port) || sleeps != 0) return 1;
    for (int scenario : {0, 1, 2, 3}) {
      v4 = scenario == 0 ? std::optional<bool>{} : std::optional<bool>{scenario == 2};
      v6 = scenario == 1 ? std::optional<bool>{} : std::optional<bool>{scenario == 3};
      sleeps = 0;
      if (IsPortReleased(port) || sleeps != 20) return 2;
    }
  }
  return 0;
}
'''
        with tempfile.TemporaryDirectory(prefix='xb-proxy-policy-') as name:
            root = Path(name)
            for target, code in [('current', functions), ('unsafe', functions.replace('.value_or(true)', '.value_or(false)'))]:
                (root / f'{target}.cpp').write_text(prefix + code + main, encoding='utf-8')
            (root / 'CMakeLists.txt').write_text('cmake_minimum_required(VERSION 3.14)\nproject(proxy_policy LANGUAGES CXX)\nset(CMAKE_CXX_STANDARD 17)\nif(NOT MSVC)\nmessage(FATAL_ERROR "MSVC required")\nendif()\nadd_executable(current current.cpp)\nadd_executable(unsafe unsafe.cpp)\n', encoding='utf-8')
            run([find_cmake(), '-S', root, '-B', root / 'build'])
            run([find_cmake(), '--build', root / 'build', '--config', 'Release', '--parallel', '2'])
            run([root / 'build/Release/current.exe'])
            with self.assertRaises(AssertionError):
                run([root / 'build/Release/unsafe.exe'])


if __name__ == '__main__':
    unittest.main()
