"""0.4.0 native metadata contracts; no client compilation, network or upload."""
from pathlib import Path
import hashlib, shutil, subprocess, tempfile, unittest, zipfile
ROOT = Path(__file__).resolve().parents[2]
FIXTURE = ROOT / 'tool/test/fixtures/desktop_webview_window_0_4_0'

class NativeMetadataTests(unittest.TestCase):
    def test_registration_and_required_platform_dependencies(self):
        spec = (FIXTURE/'pubspec.yaml').read_text(encoding='utf-8')
        for platform, file, needle in [
            ('windows','windows/flutter/generated_plugin_registrant.cc','DesktopWebviewWindowPlugin'),
            ('linux','linux/flutter/generated_plugin_registrant.cc','desktop_webview_window_plugin_register_with_registrar'),
            ('macos','macos/Flutter/GeneratedPluginRegistrant.swift','DesktopWebviewWindowPlugin')]:
            with self.subTest(platform=platform):
                self.assertIn('pluginClass: DesktopWebviewWindowPlugin',spec)
                content = (ROOT/file).read_text(encoding='utf-8')
                self.assertIn('desktop_webview_window',content)
                self.assertIn(needle,content)
                self.assertNotIn('crisp_chat',content)  # Desktop Crisp is Dart-only.
        windows = (FIXTURE/'windows/CMakeLists.txt').read_text(encoding='utf-8')
        self.assertIn('add_library(dww_webview2 STATIC IMPORTED)',windows)
        self.assertIn('dart_bridge_api.c',windows)
        linux = (FIXTURE/'linux/CMakeLists.txt').read_text(encoding='utf-8')
        self.assertIn('webkit2gtk-4.1',linux)
        self.assertIn('libsoup-3.0',linux)
        workflow = (ROOT/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        self.assertIn('libwebkit2gtk-4.1-dev',workflow)
        self.assertIn('libsoup-3.0-dev',workflow)
        self.assertIn("platform :osx, '12.0'",(ROOT/'macos/Podfile').read_text(encoding='utf-8'))
        self.assertIn('.macOS("10.15")',(FIXTURE/'macos/desktop_webview_window/Package.swift').read_text(encoding='utf-8'))

    def test_fixture_version_is_bound_to_the_enforced_lockfile(self):
        lock = (ROOT/'pubspec.lock').read_text(encoding='utf-8')
        block = lock.split('  desktop_webview_window:', 1)[1].split('  device_info_plus:', 1)[0]
        self.assertIn('faeb95926f046a93a2b8325445a7f889d4b7772ff01b4b63b47c7c891bf9ac5b', block)
        self.assertIn('version: "0.4.0"', block)
        workflow = (ROOT/'.github/workflows/release-package.yml').read_text(encoding='utf-8')
        self.assertIn('--enforce-lockfile', workflow)

    def test_pods_compiles_cpp_composer_and_requests_debug_info(self):
        spec = (FIXTURE/'macos/desktop_webview_window.podspec').read_text(encoding='utf-8')
        self.assertIn('**/*.{h,cc,swift}',spec)
        self.assertIn("s.libraries = 'c++'",spec)
        podfile = (ROOT/'macos/Podfile').read_text(encoding='utf-8')
        self.assertIn("'dwarf-with-dsym'",podfile)
        self.assertIn('pod_target.build_as_dynamic?',podfile)

@unittest.skipUnless(shutil.which('cmake'),'CMake interpreter unavailable')
class WebviewSdkContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='crisp-sdk-中文-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.helper = FIXTURE/'windows/webview2_sdk.cmake'

    def test_target_architecture_not_host_and_unsupported_rejected(self):
        for vs,msvc,expected in [('x64','ARM64','x64'),('ARM64','x64','arm64'),('','X64','x64'),('Win32','x64',None)]:
            with self.subTest(vs=vs,msvc=msvc):
                script = self.root/'arch.cmake'
                script.write_text(f'include("{self.helper.as_posix()}")\nset(CMAKE_VS_PLATFORM_NAME "{vs}")\nset(MSVC_CXX_ARCHITECTURE_ID "{msvc}")\ndww_webview2_arch(selected)\nmessage(STATUS "SELECTED=${{selected}}")\n',encoding='utf-8')
                result = subprocess.run(['cmake','-P',str(script)],capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=20)
                if expected:
                    self.assertEqual(result.returncode,0,result.stderr)
                    self.assertIn('SELECTED='+expected,result.stdout)
                else:
                    self.assertNotEqual(result.returncode,0)
                    self.assertIn('Unsupported WebView2 target architecture',result.stderr)

    def sdk_fetch(self,name,*,corrupt_hash=False,missing=None):
        sdk = self.root/(name+'.zip')
        entries = ['include/WebView2.h','include/WebView2EnvironmentOptions.h','x64/WebView2LoaderStatic.lib','arm64/WebView2LoaderStatic.lib']
        with zipfile.ZipFile(sdk,'w') as archive:
            archive.writestr('[Content_Types].xml', '<Types/>')  # NuGet has root metadata, not a single wrapper directory.
            for item in entries:
                if item != missing:archive.writestr('build/native/'+item,b'fixture-only')
        digest = '0'*64 if corrupt_hash else hashlib.sha256(sdk.read_bytes()).hexdigest()
        source = self.root/name;source.mkdir()
        (source/'CMakeLists.txt').write_text(f'''cmake_minimum_required(VERSION 3.14)
project(SdkMetadataTest LANGUAGES NONE)
include("{self.helper.as_posix()}")
dww_fetch_webview2_sdk(selected "1.0.4258.31" "{digest}" "{sdk.as_posix()}")
file(WRITE "${{CMAKE_BINARY_DIR}}/resolved.txt" "${{selected}}")
''',encoding='utf-8')
        # Configure only; LANGUAGES NONE deliberately needs no compiler.
        return subprocess.run(['cmake','-S',str(source),'-B',str(source/'output')],capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=45)

    def test_real_fetch_helper_accepts_complete_zip(self):
        result = self.sdk_fetch('complete')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertTrue((self.root/'complete/output/resolved.txt').is_file())

    def test_real_fetch_helper_rejects_wrong_digest(self):
        result = self.sdk_fetch('corrupt',corrupt_hash=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('hash',(result.stdout+result.stderr).lower())

    def test_real_fetch_helper_rejects_incomplete_archive(self):
        result = self.sdk_fetch('incomplete',missing='arm64/WebView2LoaderStatic.lib')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('is incomplete',result.stdout+result.stderr)

if __name__ == '__main__':unittest.main(verbosity=2)
