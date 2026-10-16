"""Address picker fixtures; no project build, upload or event submission."""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
import pick_sentry_symbolication_probe as picker
import sentry_macos_generation_test as generation


def pe_fixture():
    data = bytearray(2048)
    data[:2] = b'MZ'
    struct.pack_into('<I', data, 0x3c, 0x80)
    data[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<H', data, 0x86, 1)
    struct.pack_into('<H', data, 0x94, 240)
    optional = 0x98
    struct.pack_into('<H', data, optional, 0x20b)
    struct.pack_into('<Q', data, optional + 24, 0x180000000)
    struct.pack_into('<I', data, optional + 56, 0x2000)
    struct.pack_into('<II', data, optional + 112, 0x1100, 0x100)
    section = optional + 240
    struct.pack_into('<IIII', data, section + 8, 0x1000, 0x1000, 0x600, 0x200)
    struct.pack_into('<I', data, section + 36, 0x60000020)
    table = 0x300
    struct.pack_into('<IIIII', data, table + 20, 1, 1, 0x1140, 0x1144, 0x1148)
    struct.pack_into('<I', data, 0x340, 0x1200)
    struct.pack_into('<I', data, 0x344, 0x1150)
    struct.pack_into('<H', data, 0x348, 0)
    name = b'FlutterInappwebviewWindowsPluginCApiRegisterWithRegistrar\0'
    data[0x350:0x350 + len(name)] = name
    return data


class PickerTest(unittest.TestCase):
    def selection_fixture(self, root):
        records, native = [], []
        for target, source in (('FlClash', 'cmake'), ('crashpad_handler', 'cmake'),
                               ('FlClashCore', 'go'), ('Flutter', 'prebuilt')):
            binary, debug = root / target, root / (target + '.debug')
            binary.write_bytes(('binary-' + target).encode())
            debug.write_bytes(('symbols-' + target).encode())
            records.append(dict(target=target, source=source, architecture='x64',
                                binary=binary.name, debug_file=debug.name))
            fingerprints = [dict(name=path.name, bytes=path.stat().st_size,
                                 sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                            for path in (binary, debug)]
            native.append(dict(target=target, architecture='x64', binary=fingerprints[0],
                               symbols=fingerprints[1],
                               debug_ids=['12345678-1234-1234-1234-123456789abc']))
        manifest = root / 'sentry-native/linux/manifest.json'
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps(dict(schema_version=1, platform='linux', artifacts=records)))
        return dict(status='uploaded_and_processed', platform='linux', native=native)

    def test_select_exact_target_overrides_default_runner_preference(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            evidence = self.selection_fixture(root)
            with patch.object(picker, 'pick_elf', return_value=(0x1234, dict(
                    function='native_function', filename='native.cc', lineno=12))), \
                 patch.object(picker, 'image_layout', return_value=(0, 0x2000)):
                self.assertEqual(picker.select(evidence, root)['module']['target'], 'FlClash')
                selected = picker.select(evidence, root, target='crashpad_handler')
            self.assertEqual(selected['module']['target'], 'crashpad_handler')
            self.assertEqual(selected['module']['binary_path'], 'crashpad_handler')

    def test_select_missing_or_disallowed_target_cannot_fallback(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            evidence = self.selection_fixture(root)
            with patch.object(picker, 'pick_elf') as lookup:
                for target in ('absent', 'FlClashCore', 'Flutter'):
                    with self.subTest(target=target), self.assertRaisesRegex(
                            picker.ProbeError, '^requested_source_built_target_unavailable$'):
                        picker.select(evidence, root, target=target)
            lookup.assert_not_called()

    def test_selected_target_lookup_failure_cannot_select_runner(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            evidence = self.selection_fixture(root)
            with patch.object(picker, 'pick_elf', side_effect=picker.ProbeError(
                    'no_native_instruction_with_source_line')) as lookup:
                with self.assertRaisesRegex(picker.ProbeError, '^no_native_instruction_with_source_line$'):
                    picker.select(evidence, root, target='crashpad_handler')
            lookup.assert_called_once_with(root / 'crashpad_handler', root / 'crashpad_handler.debug')

    def test_windows_explicit_target_still_requires_tutorial_capi(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            manifest = root / 'windows/x64/sentry-symbols/Release/targets.tsv'
            manifest.parent.mkdir(parents=True)
            manifest.write_text('FlClash\tFlClash.exe\tFlClash.pdb\n'
                                'flutter_inappwebview_windows_plugin\tplugin.dll\tplugin.pdb\n')
            evidence = dict(status='uploaded_and_processed', platform='windows', native=[])
            with patch.object(picker, 'pick_pe') as lookup:
                with self.assertRaisesRegex(picker.ProbeError, '^requested_source_built_target_unavailable$'):
                    picker.select(evidence, root, target='FlClash')
            lookup.assert_not_called()

    def test_source_path_is_redacted_and_line_is_not_column(self):
        self.assertEqual(picker.source_location('main', '/private/build/main.cc:28:3'),
                         dict(function='main', filename='main.cc', lineno=28))
        self.assertEqual(picker.source_location('main', r'C:\private\main.cpp:54:9')['lineno'], 54)
        self.assertIsNone(picker.source_location('main', '??:0'))
        self.assertIsNone(picker.source_location('/private/main', 'main.cc:2'))

    def test_exports_return_rva_and_reject_forwarders(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary).resolve() / 'plugin.dll'
            data = pe_fixture()
            binary.write_bytes(data)
            self.assertEqual(picker.pe_exports(binary), [(0x1200, 'FlutterInappwebviewWindowsPluginCApiRegisterWithRegistrar')])
            self.assertEqual(picker.image_layout(binary, 'windows', 'x86_64'), (0x180000000, 0x2000))
            struct.pack_into('<I', data, 0x340, 0x1180)
            binary.write_bytes(data)
            self.assertEqual(picker.pe_exports(binary), [])

    def test_windows_llvm_uses_supported_no_inlines_flag(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary).resolve() / 'plugin.dll'
            binary.write_bytes(pe_fixture())
            with patch.object(picker, 'find_tool', return_value='llvm-symbolizer'), \
                 patch.object(picker, 'run', return_value='RegisterWithRegistrar\nC:\\build\\plugin.cpp:44:2\n') as command:
                address, expected = picker.pick_pe(binary, binary.with_suffix('.pdb'))
            self.assertEqual(address, 0x1200)
            self.assertEqual(expected['lineno'], 44)
            self.assertIn('--no-inlines', command.call_args.args[0])
            self.assertIn('--relative-address', command.call_args.args[0])
            self.assertNotIn('--inlines=false', command.call_args.args[0])

    def test_windows_without_llvm_marks_line_unknown(self):
        with tempfile.TemporaryDirectory() as temporary:
            binary = Path(temporary).resolve() / 'plugin.dll'
            binary.write_bytes(pe_fixture())
            with patch.object(picker, 'find_tool', side_effect=picker.ProbeError('missing')):
                address, expected = picker.pick_pe(binary, binary.with_suffix('.pdb'))
            self.assertEqual(address, 0x1200)
            self.assertEqual(expected['lineno'], 0)
            self.assertEqual(expected['filename'], 'flutter_inappwebview_windows_plugin_c_api.cpp')

    def test_elf_unslid_virtual_address_becomes_relative_address(self):
        with patch.object(picker, 'elf_layout', return_value=(0x400000, [(0x401000, 0x402000)], 0x4000)), \
             patch.object(picker, 'find_tool', side_effect=lambda name, **kwargs: name), \
             patch.object(picker, 'run', side_effect=['0000000000401000 T main\n', 'main\n/private/main.cc:27\n']):
            address, expected = picker.pick_elf(Path('runner'), Path('runner.debug'))
        self.assertEqual(address, 0x1000)
        self.assertEqual(expected['lineno'], 27)

    def test_macho_uses_text_vmaddr_and_relative_result(self):
        variant = dict(architecture='arm64', segments=[dict(name='__TEXT', vmaddr=0x100000000)],
                       sections=[dict(segment='__TEXT', name='__text', flags=0,
                                      addr=0x100001000, size=0x1000)])
        with patch.object(picker, 'inspect_macho', return_value=dict(variants=[variant])), \
             patch.object(picker, 'find_tool', side_effect=lambda name, **kwargs: name), \
             patch.object(picker, 'run', side_effect=['0000000100001234 T _main\n',
                                                    'main (in FlClash) (/private/AppDelegate.swift:12)']) as command:
            address, expected = picker.pick_macho(Path('FlClash'), Path('DWARF'), 'arm64')
        self.assertEqual(address, 0x1234)
        self.assertEqual(expected['filename'], 'AppDelegate.swift')
        self.assertEqual(command.call_args.args[0][-3:], ['-l', '0x100000000', '0x100001234'])

    def macho_variant(self):
        return dict(architecture='arm64', segments=[dict(name='__TEXT', vmaddr=0x100000000)],
                    sections=[dict(segment='__TEXT', name='__text', flags=0,
                                   addr=0x100001000, size=0x1000)])

    def test_runtime_entries_work_without_dsym_conventional_symbol_table(self):
        details = {}
        with patch.object(picker, 'inspect_macho', return_value=dict(variants=[self.macho_variant()])), \
             patch.object(picker, 'find_tool', side_effect=lambda name, **kwargs: name), \
             patch.object(picker, 'run', side_effect=['/private/runtime (for architecture arm64):\n0000000100001234 T _main\n',
                 'main (in Runtime) (/private/source/main.c:2:5)']) as run:
            address, expected = picker.pick_macho(Path('runtime'), Path('dwarf'), 'arm64', diagnostics=details)
        self.assertEqual(address, 0x1234)
        self.assertEqual(expected['lineno'], 2)
        self.assertEqual(run.call_args_list[0].args[0][-1], 'runtime')
        self.assertEqual(run.call_count, 2)
        self.assertEqual(details['selected_candidate_source'], 'runtime')
        self.assertEqual(details['atos_output_shapes'], {'source_location_with_column': 1})
        self.assertNotIn('/private/', json.dumps(details))

    def test_stripped_runtime_can_fallback_to_dsym_actual_entry(self):
        details = {}
        with patch.object(picker, 'inspect_macho', return_value=dict(variants=[self.macho_variant()])), \
             patch.object(picker, 'find_tool', side_effect=lambda name, **kwargs: name), \
             patch.object(picker, 'run', side_effect=['', '0000000100001234 T _main\n',
                 'main (in Runtime) (main.c:2) + 0']):
            _, expected = picker.pick_macho(Path('runtime'), Path('dwarf'), 'arm64', diagnostics=details)
        self.assertEqual(expected['filename'], 'main.c')
        self.assertEqual(details['selected_candidate_source'], 'dsym')

    def test_runtime_nm_nonzero_keeps_failure_and_tries_matched_dsym_once(self):
        details = {}
        with patch.object(picker, 'inspect_macho', return_value=dict(variants=[self.macho_variant()])), \
             patch.object(picker, 'find_tool', side_effect=lambda name, **kwargs: name), \
             patch.object(picker, 'run', side_effect=[picker.ProbeError('native_lookup_tool_failed'),
                 '0000000100001234 T _main\n', 'main (in Runtime) (main.c:2)']) as run:
            _, expected = picker.pick_macho(Path('runtime'), Path('dwarf'), 'arm64', diagnostics=details)
        self.assertEqual(run.call_count, 3)
        self.assertEqual(run.call_args_list[1].args[0][-1], 'dwarf')
        self.assertEqual(details['candidate_sources'][0]['status'], 'failed')
        self.assertEqual(details['selected_candidate_source'], 'dsym')
        self.assertEqual(expected['lineno'], 2)

    def test_macho_total_deadline_stops_further_native_commands(self):
        clock, details = [0.0], {}
        def run(arguments, **kwargs):
            if arguments[0] == 'nm':
                self.assertEqual(kwargs['timeout'], 120)
                clock[0] = 119
                return '0000000100001234 T _main\n0000000100001238 T _next\n'
            self.assertEqual(kwargs['timeout'], 1)
            clock[0] = 120
            return 'main (in Runtime) + 0'
        with patch.object(picker, 'inspect_macho', return_value=dict(variants=[self.macho_variant()])), \
             patch.object(picker.time, 'monotonic', side_effect=lambda: clock[0]), \
             patch.object(picker, 'find_tool', side_effect=lambda name, **kwargs: name), \
             patch.object(picker, 'run', side_effect=run) as command, \
             self.assertRaisesRegex(picker.ProbeError, '^native_lookup_deadline_exhausted$'):
            picker.pick_macho(Path('runtime'), Path('dwarf'), 'arm64', diagnostics=details)
        self.assertEqual(command.call_count, 2)
        self.assertEqual(details['attempts'], 1)
        self.assertTrue(details['deadline_exhausted'])

    def test_runtime_fallback_cannot_swallow_invalid_architecture(self):
        with patch.object(picker, 'inspect_macho', return_value=dict(variants=[])), \
             patch.object(picker, 'run') as command, \
             self.assertRaisesRegex(picker.ProbeError, '^final_macho_architecture_missing$'):
            picker.pick_macho(Path('runtime'), Path('dwarf'), 'arm64')
        command.assert_not_called()

    def test_offset_only_and_stabs_do_not_invent_source_line(self):
        details = {}
        with patch.object(picker, 'inspect_macho', return_value=dict(variants=[self.macho_variant()])), \
             patch.object(picker, 'find_tool', side_effect=lambda name, **kwargs: name), \
             patch.object(picker, 'run', side_effect=['0000000100001234 T _main\n', 'main (in Runtime) + 0',
                 '0000000100001234 - 00 0000 FUN _main\n']), \
             self.assertRaisesRegex(picker.ProbeError, '^no_native_instruction_with_source_line$'):
            picker.pick_macho(Path('runtime'), Path('dwarf'), 'arm64', diagnostics=details)
        self.assertEqual(details['atos_output_shapes'], {'symbol_offset_only': 1})
        self.assertEqual(details['candidate_sources'][1]['output_shapes']['stab_function_rows'], 1)
        self.assertEqual(details['attempts'], 1)

    def test_real_line_pc_diagnostic_never_adds_arbitrary_offsets(self):
        details_output = ('0x0000000100001234 0 0 1 0 0\n'
                          '0x0000000100001238 2 1 1 0 0 is_stmt prologue_end\n'
                          '0x0000000100001240 3 1 1 0 0 end_sequence\n'
                          '0x0000000300000000 9 1 1 0 0 is_stmt\n')
        with patch.object(picker, 'inspect_macho', return_value=dict(variants=[self.macho_variant()])), \
             patch.object(picker, 'find_tool', side_effect=lambda name, **kwargs: name), \
             patch.object(picker, 'run', side_effect=[details_output, '0000000100001234 T _main\n',
                 'main (in Runtime) (/private/main.c:2)']) as run:
            result = picker.diagnose_macho_line_rows(Path('runtime'), Path('dwarf'), 'arm64')
        self.assertEqual(result['in_range_row_count'], 1)
        self.assertEqual(result['runtime_entry_positive_rows'], 0)
        self.assertEqual(result['line_number_matches'], 1)
        self.assertEqual(run.call_args.args[0][-1], '0x100001238')
        self.assertNotIn('/private', json.dumps(result))

    def test_candidate_budget_counts_only_actual_in_range_entries(self):
        details = {}
        with patch.object(picker, 'inspect_macho', return_value=dict(variants=[self.macho_variant()])), \
             patch.object(picker, 'find_tool', side_effect=lambda name, **kwargs: name), \
             patch.object(picker, 'run', side_effect=['0000000000000000 T _outside\n0000000100001234 T _main\n0000000100001238 T _next\n',
                 '0x100001234']) as run, \
             self.assertRaises(picker.ProbeError):
            picker.pick_macho(Path('runtime'), Path('dwarf'), 'arm64', diagnostics=details, candidate_limit=1, lookup_timeout=10)
        self.assertEqual(details['attempts'], 1)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(details['atos_output_shapes'], {'address_only': 1})

    @unittest.skipUnless(os.name == 'posix', 'Native pipe lookups run only on Darwin/POSIX')
    def test_native_tool_stderr_is_bounded_and_safe(self):
        observations = []
        with self.assertRaisesRegex(picker.ProbeError, '^native_lookup_tool_failed$'):
            picker.run([sys.executable, '-c', "import sys; print('/private/token architecture mismatch', file=sys.stderr); sys.exit(7)"],
                       timeout=1, max_output_bytes=32, observations=observations)
        self.assertEqual(observations[0]['exit_code'], 7)
        self.assertEqual(observations[0]['stderr_categories'], ['architecture_mismatch'])
        self.assertNotIn('/private', json.dumps(observations))

    @unittest.skipUnless(os.name == 'posix', 'Native pipe lookups run only on Darwin/POSIX')
    def test_native_timeout_and_capacity_are_fixed_failures(self):
        for source, reason in [("import time; time.sleep(60)", 'native_lookup_timeout'),
                               ("print('private-token' * 100)", 'native_lookup_output_limit')]:
            observations = []
            started = time.monotonic()
            with self.assertRaisesRegex(picker.ProbeError, '^' + reason + '$'):
                picker.run([sys.executable, '-c', source], timeout=.1, max_output_bytes=32, observations=observations)
            self.assertLess(time.monotonic() - started, 3)
            self.assertLessEqual(observations[0]['stdout_bytes'], 32)
            self.assertNotIn('private-token', json.dumps(observations))

    @unittest.skipUnless(os.name == 'posix' and generation.CLANG and generation.LINKER and generation.DSYMUTIL,
                         'Real Mach-O fixture tools unavailable')
    def test_real_dwarf_line_rows_are_compiled_pcs_in_executable_sections(self):
        nm = generation.tool_path('llvm-nm') or generation.shutil.which('nm')
        dwarf_tool = generation.tool_path('llvm-dwarfdump') or generation.shutil.which('dwarfdump')
        if not nm or not dwarf_tool:
            self.skipTest('Native nm/dwarfdump unavailable')
        with tempfile.TemporaryDirectory(prefix='picker-real-line-pc-') as temporary:
            root = Path(temporary).resolve()
            source, obj, binary = root / 'Fixture.c', root / 'Fixture.o', root / 'Fixture'
            dsym = root / 'Fixture.dSYM'
            source.write_text('__attribute__((noinline)) int fixture_probe(void) { return 7; }\n'
                              'int main(void) { return fixture_probe(); }\n')
            for command in ([generation.CLANG, '--target=x86_64-apple-macos11', '-g', '-O0', '-c', str(source), '-o', str(obj)],
                            generation.fixture_link_command(binary, [obj]),
                            [generation.DSYMUTIL, str(binary), '-o', str(dsym)]):
                self.assertEqual(subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode, 0)
            dwarf = dsym / 'Contents/Resources/DWARF/Fixture'
            output = subprocess.run([dwarf_tool, '--debug-line', str(dwarf)], capture_output=True, text=True, check=True).stdout
            rows = picker.dwarf_positive_line_rows(output)
            variant = picker.inspect_macho(binary)['variants'][0]
            ranges = [(section['addr'], section['addr'] + section['size']) for section in variant['sections']
                      if section['segment'] == '__TEXT' and section['name'] == '__text']
            self.assertTrue(rows)
            self.assertTrue(all(line in (1, 2) and picker.in_ranges(address, ranges) for address, line in rows))
            entries = picker.symbols(subprocess.run([nm, '-n', str(binary)], capture_output=True, text=True, check=True).stdout)
            self.assertTrue(any(name == '_main' and picker.in_ranges(address, ranges) for address, name in entries))

    def test_no_upload_evidence_fails_closed(self):
        for evidence in ({'platform': 'linux', 'status': 'audited'},
                         {'platform': 'android', 'status': 'uploaded_and_processed'}):
            with self.assertRaises(picker.ProbeError):
                picker.select(evidence, Path('/unused'))

    def test_universal_mac_selection_uses_requested_slice_and_its_debug_id(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            binary, debug = root / 'runner', root / 'runner.dwarf'
            binary.write_bytes(b'universal-runtime-fixture')
            debug.write_bytes(b'universal-debug-fixture')
            fingerprints = [dict(name=path.name, bytes=path.stat().st_size,
                                 sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                            for path in (binary, debug)]
            architectures = ('arm64', 'x86_64')
            records = [dict(target='runner', source='runner', architecture=arch,
                            binary=binary.name, debug_file=debug.name) for arch in architectures]
            manifest = root / 'sentry-native/macos/manifest.json'
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps(dict(schema_version=1, platform='macos', artifacts=records)))
            ids = ('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')
            evidence = dict(status='uploaded_and_processed', platform='macos', native=[
                dict(target='runner', architecture=arch, binary=fingerprints[0], symbols=fingerprints[1],
                     debug_ids=[identifier]) for arch, identifier in zip(architectures, ids)])
            for arch, identifier in zip(architectures, ids):
                with self.subTest(architecture=arch), \
                     patch.object(picker, 'pick_macho', return_value=(0x120, dict(
                         function='main', filename='AppDelegate.swift', lineno=7))) as lookup, \
                     patch.object(picker, 'image_layout', return_value=(0x100000000, 0x4000)):
                    selected = picker.select(evidence, root, architecture=arch)
                    self.assertEqual(selected['module']['architecture'], arch)
                    self.assertEqual(selected['module']['debug_id'], identifier)
                    lookup.assert_called_once_with(binary, debug, arch)
            with patch.object(picker, 'pick_macho') as lookup, self.assertRaises(picker.ProbeError):
                picker.select(evidence, root, architecture='x64')
            lookup.assert_not_called()

    def test_symbol_candidates_use_instruction_entries_main_first(self):
        self.assertEqual(picker.symbols('00000010 T helper\n00000040 T main\n00000080 D data'),
                         [(0x40, 'main'), (0x10, 'helper')])


if __name__ == '__main__':
    unittest.main()
