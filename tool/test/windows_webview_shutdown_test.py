#!/usr/bin/env python3
"""Offline CMake + real C++ child-process checks for the pinned ownership patch.

Compiles the actual upstream manager header after the production CMake overlay,
with COM/Flutter stand-ins. This is not a Windows COM or GUI acceptance test.
Run on Linux/macOS with CMake+C++, or Windows with Visual Studio+CMake.
"""
from __future__ import annotations

from pathlib import Path
import shutil
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import io
import ast

try:
    from .windows_loader_install_test import find_cmake, write_file
except ImportError:
    from windows_loader_install_test import find_cmake, write_file

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
FIXTURE = Path(__file__).parent / 'fixtures/inappwebview_windows_0_6_0'
HELPER = ROOT / 'windows/xboard_webview_shutdown.cmake'

API = r'''
#pragma once
#include <cstdlib>
#include <cstdio>
#include <cstdint>
#include <memory>
#include <string>
#include <map>
namespace probe {
inline bool shutdown = false;
inline int made = 0, destroyed = 0, views = 0, limit = 4;
struct Resource {
  Resource() { ++made; }
  ~Resource() {
    if (shutdown) { std::fputs("late COM teardown\n", stderr); std::_Exit(73); }
    ++destroyed;
  }
};
}
namespace rx { struct RoHelper : probe::Resource {}; }
namespace ABI { namespace Windows {
namespace System { struct IDispatcherQueueController : probe::Resource {}; }
namespace UI { namespace Composition { struct ICompositor : probe::Resource {}; } }
} }
namespace winrt {
template<class T> struct com_ptr {
  std::shared_ptr<T> value;
  com_ptr() = default;
  com_ptr(std::nullptr_t) {}
  T* get() const { return value.get(); }
  void attach(T* raw) { value.reset(raw); }
};
}
namespace flutter {
struct EncodableValue {};
using EncodableMap = std::map<int, int>;
template<class T> struct MethodCall {};
template<class T> struct MethodResult {};
}
struct WNDCLASS { const wchar_t* lpszClassName = nullptr; void* hInstance = nullptr; };
inline void UnregisterClass(const wchar_t*, void*) {}
inline void debugLog(const char*) {}
namespace flutter_inappwebview_plugin {
struct GraphicsContext : probe::Resource {};
struct FlutterInappwebviewWindowsPlugin {};
struct ChannelDelegate {};
struct CustomPlatformView {
  CustomPlatformView() { ++probe::views; }
  ~CustomPlatformView() { --probe::views; }
};
struct NewWindowRequestedArgs {};
}
'''

MAIN = r'''
#include "in_app_webview/in_app_webview_manager.h"
using namespace flutter_inappwebview_plugin;
extern bool other_translation_unit(InAppWebViewManager& manager);
InAppWebViewManager::InAppWebViewManager(const FlutterInappwebviewWindowsPlugin* p)
  : plugin(p) {
  if (!rohelper_) {
    if (probe::limit >= 1) rohelper_ = std::make_shared<rx::RoHelper>();
    if (probe::limit >= 2) dispatcher_queue_controller_.attach(
      new ABI::Windows::System::IDispatcherQueueController());
    if (probe::limit >= 3) graphics_context_ = std::make_unique<GraphicsContext>();
    if (probe::limit >= 4) compositor_.attach(new ABI::Windows::UI::Composition::ICompositor());
  }
}
// The unchanged real manager destructor is appended here by the fixture.
'''

END_MAIN = r'''
int main(int argc, char** argv) {
  probe::limit = argc > 1 ? std::atoi(argv[1]) : 4;
  const bool direct_exit = argc > 2;
  if (probe::limit > 0) {
    // Repeated views/managers must not allocate another set of shared owners.
    for (int i = 0; i < 100; ++i) {
      InAppWebViewManager a(nullptr), b(nullptr);
      if (!other_translation_unit(a)) return 11;
      if (a.rohelper() != b.rohelper()) return 12;
      a.webViews.emplace(1, std::make_unique<CustomPlatformView>());
      a.keepAliveWebViews.emplace("held", std::make_unique<CustomPlatformView>());
      a.windowWebViews.emplace(1, std::make_unique<NewWindowRequestedArgs>());
      if (probe::made != probe::limit || probe::destroyed) return 13;
      auto borrowed = a.compositor(); // local copies must still release normally
      if (direct_exit && i == 99) {
        probe::shutdown = true;
        std::exit(0); // model Dart exit(0), with no manager destructor
      }
    }
    if (probe::views || probe::made != probe::limit || probe::destroyed) return 14;
  }
  probe::shutdown = true; // model WinRT unavailability before DLL static teardown
  return 0;
}
'''

OTHER = r'''
#include "in_app_webview/in_app_webview_manager.h"
using namespace flutter_inappwebview_plugin;
bool other_translation_unit(InAppWebViewManager& manager) {
  InAppWebViewManager second(nullptr);
  return second.rohelper() == manager.rohelper()
      && second.graphics_context() == manager.graphics_context()
      && second.compositor().get() == manager.compositor().get();
}
'''


class WebViewShutdownTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cmake = find_cmake()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='webview shutdown ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source with spaces'
        self.build = self.root / 'build with spaces'

    def run_command(self, argv, expected=0):
        result = subprocess.run(argv, capture_output=True, text=True,
                                encoding='utf-8', errors='replace', timeout=120)
        self.assertEqual(result.returncode, expected,
                         f'{argv!r}\n{result.stdout}\n{result.stderr}')
        return result

    def fixture(self, *, patched=True, crlf=False, brand='brand_a', drift=None):
        plugin = self.source / 'plugin'
        for name in ('in_app_webview_manager.h', 'in_app_webview_manager.cpp'):
            data = (FIXTURE / name).read_text(encoding='utf-8')
            if drift == name:
                data += '\n// upstream changed\n'
            write_file(plugin / 'in_app_webview' / name,
                       data.replace('\n', '\r\n').encode() if crlf else data.encode())
        write_file(plugin / 'fake_api.h', API)
        for name in ('flutter/method_channel.h', 'flutter/standard_message_codec.h',
                     'wil/com.h', 'winrt/base.h',
                     'custom_platform_view/custom_platform_view.h',
                     'custom_platform_view/graphics_context.h',
                     'custom_platform_view/util/rohelper.h',
                     'flutter_inappwebview_windows_plugin.h', 'types/channel_delegate.h',
                     'types/new_window_requested_args.h', 'windows.ui.composition.h'):
            write_file(plugin / name, '#pragma once\n#include <fake_api.h>\n')
        # Reuse the actual unmodified per-view cleanup implementation.
        cpp = (FIXTURE / 'in_app_webview_manager.cpp').read_text(encoding='utf-8')
        destructor = cpp[cpp.index('  InAppWebViewManager::~'):cpp.rfind('\n}')]
        write_file(plugin / 'main.cpp', MAIN + destructor + END_MAIN)
        write_file(plugin / 'other.cpp', OTHER)
        write_file(plugin / 'CMakeLists.txt', '''
add_executable(flutter_inappwebview_windows_plugin main.cpp "${CMAKE_CURRENT_SOURCE_DIR}/other.cpp")
target_compile_features(flutter_inappwebview_windows_plugin PRIVATE cxx_std_17)
# Angle-bracket includes stand in for external Flutter/Windows SDK headers.
target_include_directories(flutter_inappwebview_windows_plugin PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
''')
        helper = f'include("{HELPER.as_posix()}")\n' if patched else ''
        write_file(self.source / 'CMakeLists.txt', f'''
cmake_minimum_required(VERSION 3.14)
project(WebViewShutdown CXX)
set(ENV{{FLAVOR}} {brand})
add_subdirectory(plugin)
{helper}
{helper}
file(GENERATE OUTPUT "${{CMAKE_BINARY_DIR}}/program-$<CONFIG>.txt"
  CONTENT "$<TARGET_FILE:flutter_inappwebview_windows_plugin>")
file(GENERATE OUTPUT "${{CMAKE_BINARY_DIR}}/sources-$<CONFIG>.txt"
  CONTENT "$<JOIN:$<TARGET_PROPERTY:flutter_inappwebview_windows_plugin,SOURCES>,\\n>")
''')
        self.original = {p.relative_to(plugin):p.read_bytes() for p in plugin.rglob('*') if p.is_file()}

    def configure(self, expected=0):
        return self.run_command([self.cmake, '-S', str(self.source), '-B', str(self.build),
                                 '-DCMAKE_BUILD_TYPE=Release'], expected)

    def compile(self):
        self.run_command([self.cmake, '--build', str(self.build), '--config', 'Release'])
        return (self.build / 'program-Release.txt').read_text(encoding='utf-8')

    def assert_source_unchanged(self):
        for relative, data in self.original.items():
            self.assertEqual((self.source / 'plugin' / relative).read_bytes(), data)

    def test_both_brands_all_initialization_states_return_and_direct_exit(self):
        for brand, crlf in (('brand_a', False), ('brand_b', True)):
            with self.subTest(brand=brand, crlf=crlf):
                self.fixture(brand=brand, crlf=crlf)
                self.configure()
                program = self.compile()
                for resources in range(5):
                    for mode in ([], ['direct-exit']):
                        self.run_command([program, str(resources), *mode])
                self.assert_source_unchanged()
                rows = (self.build / 'sources-Release.txt').read_text(encoding='utf-8').splitlines()
                self.assertTrue(rows)
                self.assertTrue(all('xboard_webview_shutdown/' in p.replace('\\', '/') for p in rows))
                shutil.rmtree(self.build)
                shutil.rmtree(self.source)

    def test_original_static_owners_fail_in_real_child_process(self):
        self.fixture(patched=False)
        self.configure()
        program = self.compile()
        self.run_command([program, '0'])
        for resources in range(1, 5):
            for mode in ([], ['direct-exit']):
                result = self.run_command([program, str(resources), *mode], expected=73)
                self.assertIn('late COM teardown', result.stderr)

    def test_dependency_drift_is_a_configuration_failure(self):
        for name in ('in_app_webview_manager.h', 'in_app_webview_manager.cpp'):
            with self.subTest(file=name):
                self.fixture(drift=name)
                result = self.configure(expected=1)
                self.assertIn('source drift', result.stderr)
                self.assertFalse((self.build / 'xboard_webview_shutdown').exists())
                self.assert_source_unchanged()
                shutil.rmtree(self.build)
                shutil.rmtree(self.source)

    def test_missing_target_is_a_noop(self):
        write_file(self.source / 'CMakeLists.txt', f'''
cmake_minimum_required(VERSION 3.14)
project(NoWebView NONE)
include("{HELPER.as_posix()}")
''')
        self.configure()
        self.assertFalse((self.build / 'xboard_webview_shutdown').exists())

    def test_missing_pinned_source_and_outside_source_are_rejected(self):
        self.fixture()
        header = self.source / 'plugin/in_app_webview/in_app_webview_manager.h'
        header.unlink()
        self.assertIn('missing pinned source', self.configure(expected=1).stderr)
        header.write_bytes(self.original[Path('in_app_webview/in_app_webview_manager.h')])
        write_file(self.source / 'outside.cpp', 'int outside() { return 0; }\n')
        cmake = self.source / 'plugin/CMakeLists.txt'
        cmake.write_text(cmake.read_text(encoding='utf-8') + '\ntarget_sources(flutter_inappwebview_windows_plugin PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../outside.cpp")\n', encoding='utf-8')
        self.assertIn('source outside copied tree', self.configure(expected=1).stderr)

    def test_ci_runs_offline_checks_before_matrix_and_windows_compile(self):
        # Semantic command tokens; avoid platform-specific line-ending assertions.
        import shlex
        from tool import check_release_workflow as gate
        from tool.test.sentry_release_workflow_test import step_script, WORKFLOW
        self.assertIn('tool.test.windows_webview_shutdown_test', gate.MODULES)
        name = 'Check Windows WebView shutdown ownership with MSVC'
        self.assertEqual(shlex.split(step_script(name)),
                         ['python', 'tool/test/windows_webview_shutdown_test.py'])
        workflow = WORKFLOW.read_text(encoding='utf-8')
        self.assertLess(workflow.index('name: ' + name), workflow.index('name: Package (flutter_distributor)'))
        section = workflow.split('name: ' + name, 1)[1].split('\n      - ', 1)[0]
        self.assertIn("if: matrix.platform == 'windows'", section)
        self.assertNotIn('continue-on-error', section)

    def test_workflow_check_works_with_windows_cp1252_default(self):
        from tool.test.sentry_release_workflow_test import WORKFLOW
        # Exercise the actual check under a non-UTF-8 default on every host.
        # No environment-wide UTF-8 override that could hide an omitted argument.
        def windows_encoding(encoding, *args):
            return 'cp1252' if encoding is None else encoding
        with mock.patch.object(io, 'text_encoding', side_effect=windows_encoding):
            with self.assertRaises(UnicodeDecodeError):
                WORKFLOW.read_text()  # intentional old-code negative control
            self.test_ci_runs_offline_checks_before_matrix_and_windows_compile()

    def test_fixture_file_io_always_declares_encoding(self):
        source = Path(__file__).read_text(encoding='utf-8')
        tree = ast.parse(source)
        for method in (node for node in ast.walk(tree) if isinstance(node, ast.FunctionDef)):
            if method.name == 'test_workflow_check_works_with_windows_cp1252_default':
                continue  # this one deliberately executes the old bug
            for node in ast.walk(method):
                if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                        and node.func.attr in ('read_text', 'write_text')):
                    self.assertTrue(any(k.arg == 'encoding' and isinstance(k.value, ast.Constant)
                                        and k.value.value == 'utf-8' for k in node.keywords),
                                    f'{method.name}:{node.lineno}: file encoding is implicit')

    def test_incremental_reconfigure_keeps_output_and_does_not_mutate_cache(self):
        self.fixture()
        self.configure()
        program = self.compile()
        header = self.build / 'xboard_webview_shutdown/in_app_webview/in_app_webview_manager.h'
        stamp = header.stat().st_mtime_ns
        self.configure()
        self.assertEqual(header.stat().st_mtime_ns, stamp)
        self.assertEqual(program, self.compile())
        self.run_command([program, '4'])
        self.assert_source_unchanged()

    def test_changed_upstream_blocks_an_incremental_build(self):
        self.fixture()
        self.configure()
        self.compile()
        path = self.source / 'plugin/in_app_webview/in_app_webview_manager.h'
        path.write_text(path.read_text(encoding='utf-8') + '\n// changed after configure\n', encoding='utf-8')
        result = subprocess.run([self.cmake, '--build', str(self.build), '--config', 'Release'],
                                capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('source drift', result.stderr)

    def test_real_upstream_cmake_graph_retargets_every_translation_unit(self):
        # Configure the real pinned plugin build graph, not a handwritten source
        # inventory. No NuGet invocation or actual Windows compilation here.
        upstream = (FIXTURE / 'CMakeLists.txt').read_text(encoding='utf-8')
        for fallback in ('OFF', 'ON'):
            with self.subTest(texture_fallback=fallback):
                plugin = self.source / 'plugin'
                for relative in re.findall(r'"([^"\n]+\.(?:h|cpp|cc))"', upstream):
                    if '$' not in relative:
                        write_file(plugin / relative, '// configure-only fixture\n')
                for name in ('in_app_webview_manager.h', 'in_app_webview_manager.cpp'):
                    write_file(plugin / 'in_app_webview' / name, (FIXTURE / name).read_bytes())
                write_file(plugin / 'CMakeLists.txt', upstream)
                write_file(self.source / 'CMakeLists.txt', f'''
cmake_minimum_required(VERSION 3.14)
project(RealWebViewGraph CXX)
set(include_flutter_inappwebview_windows_tests OFF)
set(FLUTTER_WEBVIEW_WINDOWS_USE_TEXTURE_FALLBACK {fallback})
set(NUGET "${{CMAKE_COMMAND}}")
add_library(flutter INTERFACE)
add_library(flutter_wrapper_plugin INTERFACE)
add_subdirectory(plugin)
get_target_property(original flutter_inappwebview_windows_plugin SOURCES)
include("{HELPER.as_posix()}")
get_target_property(patched flutter_inappwebview_windows_plugin SOURCES)
list(LENGTH original before)
list(LENGTH patched after)
if(NOT before EQUAL after)
  message(FATAL_ERROR "Lost plugin sources")
endif()
file(WRITE "${{CMAKE_BINARY_DIR}}/source_count.txt" "${{after}}")
file(GENERATE OUTPUT "${{CMAKE_BINARY_DIR}}/sources-$<CONFIG>.txt"
  CONTENT "$<JOIN:$<TARGET_PROPERTY:flutter_inappwebview_windows_plugin,SOURCES>,\\n>")
''')
                self.configure()
                self.assertGreater(int((self.build / 'source_count.txt').read_text(encoding='utf-8')), 90)
                rows = (self.build / 'sources-Release.txt').read_text(encoding='utf-8').splitlines()
                self.assertTrue(all('xboard_webview_shutdown/' in p.replace('\\', '/') for p in rows))
                self.assertTrue(any(p.endswith('texture_bridge_fallback.cc' if fallback == 'ON' else 'texture_bridge_gpu.cc') for p in rows))
                shutil.rmtree(self.build)
                shutil.rmtree(self.source)


if __name__ == '__main__':
    unittest.main()
