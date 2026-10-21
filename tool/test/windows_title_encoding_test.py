#!/usr/bin/env python3
"""Compile actual injected runner titles: MSVC on Windows, GNU on Linux.

Only tiny console fixtures are compiled; no Flutter application or installer.
The GNU control explicitly uses Windows-width wchar_t and UTF-16LE output.
"""
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from windows_loader_install_test import find_cmake

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))
from pub_get_retry import execute


def run(command, *, cwd=ROOT, timeout=120):
    lines = []
    code, _ = execute(list(map(str, command)), cwd, os.environ, attempts=1,
                      attempt_timeout=timeout, total_timeout=timeout, emit=lines.append)
    if code:
        raise AssertionError('\n'.join(lines))
    prefix = '[pub-get output] '
    return '\n'.join(line[len(prefix):] for line in lines if line.startswith(prefix))


def dart_executable():
    suffix = '.exe' if os.name == 'nt' else ''
    flutter = os.environ.get('FLUTTER_ROOT')
    if flutter:
        native = Path(flutter) / ('bin/cache/dart-sdk/bin/dart' + suffix)
        if native.is_file():
            return native
    wrapper = shutil.which('dart')
    if wrapper:
        bundled = Path(wrapper).resolve().parent / ('cache/dart-sdk/bin/dart' + suffix)
        if bundled.is_file():
            return bundled
        if Path(wrapper).suffix.lower() not in {'.bat', '.cmd'}:
            return Path(wrapper)
    raise RuntimeError('Native Dart is required; prepare Flutter dependencies first')


class CompiledTitleTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='window-title-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.root = Path(cls.temporary.name).resolve()
        cls.build = cls.root / 'build'
        cls.report = ROOT / 'build/windows-title-preflight.json'
        cls.report.parent.mkdir(parents=True, exist_ok=True)
        cls.report.write_text('{"passed":false}\n', encoding='utf-8')
        run([dart_executable(), 'tool/test/windows_title_fixture.dart', cls.root])
        cls.cases = json.loads((cls.root / 'manifest.json').read_text(encoding='utf-8'))
        cls.codepages = {'utf8': ('utf-8', 'UTF-8'),
                        'cp1252': ('.1252', 'CP1252'),
                        'cp936': ('.936', 'GBK')}
        cls.results = {}
        cmake = ['cmake_minimum_required(VERSION 3.14)',
                 'project(title_fixture LANGUAGES CXX)',
                 'set(CMAKE_CXX_STANDARD 17)',
                 'if(WIN32 AND NOT MSVC)',
                 '  message(FATAL_ERROR "Windows title preflight requires native MSVC")',
                 'endif()']
        for config in ('', '_DEBUG', '_RELEASE', '_RELWITHDEBINFO', '_MINSIZEREL'):
            cmake.append('set(CMAKE_RUNTIME_OUTPUT_DIRECTORY' + config +
                         ' [==[' + (cls.build / 'bin').as_posix() + ']==])')
        targets = [(case['id'], codec) for case in cls.cases for codec in cls.codepages]
        targets += [('legacy', 'utf8'), ('legacy', 'cp1252')]
        for case, codec in targets:
            target = case + '_' + codec
            msvc, gnu = cls.codepages[codec]
            cmake += [
                f'add_executable({target} {case}.cpp)',
                'if(MSVC)',
                f'  target_compile_options({target} PRIVATE /W4 /WX /source-charset:{msvc} /execution-charset:utf-8)',
                'elseif(CMAKE_CXX_COMPILER_ID STREQUAL "GNU")',
                f'  target_compile_options({target} PRIVATE -Wall -Werror -fshort-wchar -fwide-exec-charset=UTF-16LE -finput-charset={gnu})',
                'else()',
                '  message(FATAL_ERROR "Title codepage regression requires MSVC or GNU")',
                'endif()',
            ]
        (cls.root / 'CMakeLists.txt').write_bytes(('\n'.join(cmake) + '\n').encode('utf-8'))
        configure = [find_cmake(), '-S', cls.root, '-B', cls.build]
        if os.name != 'nt':
            compiler = shutil.which('g++')
            if not compiler:
                raise RuntimeError('GNU g++ is required for the local Windows-width control')
            configure.append('-DCMAKE_CXX_COMPILER=' + compiler)
        run(configure)
        run([find_cmake(), '--build', cls.build, '--config', 'Release', '--parallel', '2'],
            timeout=180)
        for case, codec in targets:
            name = case + '_' + codec
            executable = cls.build / 'bin' / (name + ('.exe' if os.name == 'nt' else ''))
            cls.results[name] = [int(unit, 16) for unit in run([executable], timeout=15).split()]

    def test_all_injected_titles_have_exact_utf16_in_every_codepage(self):
        for case in self.cases:
            for codec in self.codepages:
                with self.subTest(case=case['id'], codepage=codec):
                    self.assertEqual(self.results[case['id'] + '_' + codec], case['utf16'])
                    self.assertTrue((self.root / (case['id'] + '.cpp')).read_bytes().isascii())

    def test_legacy_utf8_title_reproduces_the_reported_cp1252_mojibake(self):
        expected = next(case['utf16'] for case in self.cases if case['id'] == 'brand_b')
        self.assertEqual(self.results['legacy_utf8'], expected)
        wrong = '袋鼠加速'.encode('utf-8').decode('cp1252')
        self.assertEqual(self.results['legacy_cp1252'], [ord(c) for c in wrong])
        self.assertNotEqual(self.results['legacy_cp1252'], expected)


if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(
        unittest.defaultTestLoader.loadTestsFromTestCase(CompiledTitleTests))
    passed = result.wasSuccessful() and result.testsRun == 2 and not result.skipped
    report = ROOT / 'build/windows-title-preflight.json'
    report.parent.mkdir(parents=True, exist_ok=True)
    report.write_text(json.dumps({
        'passed': passed, 'host': sys.platform,
        'native_windows': os.name == 'nt', 'client_build': False,
        'tests': result.testsRun, 'codepages': ['utf8', 'cp1252', 'cp936'],
        'compiled_utf16': getattr(CompiledTitleTests, 'results', {}),
    }, indent=2) + '\n', encoding='utf-8')
    raise SystemExit(0 if passed else 1)
