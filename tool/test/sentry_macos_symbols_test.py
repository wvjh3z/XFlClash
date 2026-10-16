#!/usr/bin/env python3
"""Offline Mach-O inventory regressions; never compile or upload the client."""

from __future__ import annotations

import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import uuid

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
import upload_sentry_symbols as symbols
from sentry_macho import MachoError, inspect_macho
from sentry_macos_inventory import write_inventory


def macho(identifier, architecture="x86_64", *, debug=False, text=True, filetype=None, oso=False):
    """A bounded, deterministic Mach-O inventory fixture; it is never executed."""
    cpu = 0x01000007 if architecture == "x86_64" else 0x0100000c
    sections = []
    if text:
        sections.append((b"__TEXT", b"__text", b"\x90\x90\xc3\0", 0x80000400))
    if debug:
        sections.extend([(b"__DWARF", b"__debug_info", b"i" * 16, 0),
                         (b"__DWARF", b"__debug_line", b"l" * 16, 0)])
    groups = {segment: [entry for entry in sections if entry[0] == segment]
              for segment in dict.fromkeys(entry[0] for entry in sections)}
    commands_size = 24 + sum(72 + len(entries) * 80 for entries in groups.values()) + (24 if oso else 0)
    offset = 32 + commands_size
    commands = [struct.pack("<II", 0x1b, 24) + uuid.UUID(identifier).bytes]
    content = bytearray()
    for segment, entries in groups.items():
        segment_offset = offset + len(content)
        section_headers = []
        for _, name, payload, flags in entries:
            section_offset = offset + len(content)
            section_headers.append(struct.pack("<16s16sQQIIIIIIII", name, segment,
                                               0x100000000 + section_offset, len(payload), section_offset,
                                               0, 0, 0, flags, 0, 0, 0))
            content.extend(payload)
        size = offset + len(content) - segment_offset
        commands.append(struct.pack("<II16sQQQQiiII", 0x19, 72 + len(entries) * 80, segment,
                                    0x100000000 + segment_offset, size, segment_offset, size,
                                    7, 5, len(entries), 0) + b"".join(section_headers))
    if oso:
        symbol_offset = offset + len(content)
        commands.append(struct.pack("<IIIIII", 2, 24, symbol_offset, 1, symbol_offset + 16, 1))
        content.extend(struct.pack("<IBBHQ", 0, 0x66, 0, 0, 0) + b"\0")
    header = struct.pack("<IiiIIIII", 0xfeedfacf, cpu, 3 if architecture == "x86_64" else 0,
                         filetype if filetype is not None else (10 if debug and not text else 2),
                         len(commands), commands_size, 0, 0)
    return header + b"".join(commands) + content


def universal(slices):
    offset, entries, payload = 8 + len(slices) * 20, [], bytearray()
    for architecture, data in slices:
        cpu = 0x01000007 if architecture == "x86_64" else 0x0100000c
        entries.append(struct.pack(">iiIII", cpu, 3 if architecture == "x86_64" else 0,
                                   offset + len(payload), len(data), 0))
        payload.extend(data)
    return struct.pack(">II", 0xcafebabe, len(slices)) + b"".join(entries) + payload


class MacosSymbolsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sentry-macos-audit-")
        self.addCleanup(self.temporary.cleanup)
        self.root = (Path(self.temporary.name).resolve() / "build").resolve()
        self.products = self.root / "macos/Build/Products/Release"
        self.app = self.products / "Fixture.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Fixture"}))
        self.output = self.root / "sentry-native/macos"
        self.output.mkdir(parents=True)
        self.owned = {"schema_version": 1, "products": [{"target": "rust_api", "product": "rust_api.framework"},
                                                       {"target": "example", "product": "example.framework"}]}
        self.manifest = {"schema_version": 1, "platform": "macos", "app": self.app.relative_to(self.root).as_posix(),
                         "artifacts": [], "required": [], "limitations": []}
        self.paths, self.ids = {}, {}
        self.add_module("runner", self.app / "Contents/MacOS/Fixture", "runner")
        self.add_module("rust_api", self.app / "Contents/Frameworks/rust_api.framework/rust_api", "rust")
        self.add_module("example", self.app / "Contents/Frameworks/example.framework/example", "pods")
        self.app_uuid = str(uuid.uuid5(uuid.NAMESPACE_URL, "fixture-dart"))
        self.app_binary = self.app / "Contents/Frameworks/App.framework/App"
        self.app_binary.parent.mkdir(parents=True)
        self.app_binary.write_bytes(macho(self.app_uuid, filetype=6))
        self.manifest["limitations"].append({"target": "App", "architecture": "x86_64", "source": "dart", "reason": "split_debug_info_managed_separately"})
        self.dart = self.root / "debug-info/app.darwin-x86_64.symbols"
        self.dart.parent.mkdir()
        self.dart.write_bytes(macho(self.app_uuid, debug=True, text=False))
        self.save()
        self.calls = []
        # These synthetic C/Mach-O bytes test UUID/layout rules; they are not
        # actual language DWARF. Dedicated tests below replace this explicit
        # language-evidence mock to exercise the independent Rust audit gate.
        language = mock.patch.object(symbols, "contains_rust_debug", return_value=True)
        tools = mock.patch.object(symbols, "resolve_apple_tool", return_value="fixture-dwarfdump")
        self.rust_language = language.start()
        self.rust_tool = tools.start()
        self.addCleanup(language.stop)
        self.addCleanup(tools.stop)

    def add_module(self, target, binary, source, architecture="x86_64", identifier=None):
        identifier = identifier or str(uuid.uuid5(uuid.NAMESPACE_URL, "fixture-" + target + architecture))
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_bytes(macho(identifier, architecture, filetype=2 if target == "runner" else 6))
        debug = self.output / (target + ".dSYM/Contents/Resources/DWARF") / binary.name
        debug.parent.mkdir(parents=True, exist_ok=True)
        debug.write_bytes(macho(identifier, architecture, debug=True, text=False))
        self.paths[target], self.ids[target] = (binary, debug), identifier
        self.manifest["artifacts"].append({"target": target, "architecture": architecture, "source": source,
                                           "binary": binary.relative_to(self.root).as_posix(),
                                           "debug_file": debug.relative_to(self.root).as_posix()})
        self.manifest["required"].append({"target": target, "architecture": architecture})

    def save(self):
        (self.output / "manifest.json").write_text(json.dumps(self.manifest))
        write_inventory(self.root, self.app, "Release", ["pods"], [
            {**item, "source": "pods"} for item in self.owned["products"]])

    def cli(self, executable, arguments):
        self.calls.append(arguments)
        if arguments == ["--version"]:
            return "sentry-cli 2.58.4\n"
        if arguments[:2] == ["debug-files", "check"]:
            path = Path(arguments[-1])
            if path.suffix == ".symbols":
                variants = inspect_macho(path)["variants"]
                return json.dumps({"type": "dsym", "variants": [{"debug_id": item["uuid"], "arch": item["architecture"]} for item in variants],
                                   "features": "symtab, debug", "is_usable": True})
            variants = inspect_macho(path)["variants"]
            return json.dumps({"type": "dsym", "variants": [{"debug_id": item["uuid"], "arch": item["architecture"]} for item in variants],
                               "features": "symtab, debug" if variants[0]["filetype"] == 10 else "symtab, unwind",
                               "is_usable": True})
        if arguments[:2] == ["debug-files", "upload"]:
            files = [path for path in Path(arguments[-1]).rglob("*") if path.is_file()]
            self.assertEqual(len(files), 4)
            self.assertTrue(all(path.suffix == ".symbols" or inspect_macho(path)["variants"][0]["filetype"] == 10 for path in files))
            self.assertIn("--no-sources", arguments)
            self.assertNotIn("--require-all", arguments)
            self.assertEqual(arguments[arguments.index("--wait-for") + 1], "300")
            self.assertIn("--id", arguments)
            return "> File processing complete:\n"
        self.fail("Unexpected CLI call")

    def audit(self):
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli):
            return symbols.audit_macos("sentry-cli", self.root)

    def make_universal_rust(self):
        entry = next(item for item in self.manifest["artifacts"] if item["target"] == "rust_api")
        binary, debug = self.paths["rust_api"]
        identifier = str(uuid.uuid5(uuid.NAMESPACE_URL, "fixture-rust-arm64"))
        binary.write_bytes(universal([("x86_64", binary.read_bytes()),
                                      ("arm64", macho(identifier, "arm64", filetype=6))]))
        debug.write_bytes(universal([("x86_64", debug.read_bytes()),
                                     ("arm64", macho(identifier, "arm64", debug=True, text=False))]))
        self.manifest["artifacts"].append({**entry, "architecture": "arm64"})
        self.manifest["required"].append({"target": "rust_api", "architecture": "arm64"})
        self.save()

    def run_main(self, token="fixture-token", audit_only=False):
        evidence = self.root / "evidence.json"
        args = ["--platform", "macos", "--flavor", "brand_a", "--build-root", str(self.root), "--evidence", str(evidence)]
        if audit_only:
            args.append("--audit-only")
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli), \
             mock.patch.object(symbols.shutil, "which", return_value="fixture-cli"), \
             mock.patch.dict(os.environ, {"SENTRY_AUTH_TOKEN": token}):
            result = symbols.main(args)
        self.assertNotIn(str(self.root), evidence.read_text())
        self.assertNotIn("fixture-token", evidence.read_text())
        return result, json.loads(evidence.read_text())

    def test_final_runner_plugins_and_rust_have_matching_separate_dsym(self):
        files, evidence, limitations = self.audit()
        self.assertEqual(len(files), 3)
        self.assertEqual({item["target"] for item in evidence}, {"runner", "rust_api", "example"})
        self.assertEqual(len(limitations), 1)
        self.assertEqual(limitations[0]["source"], "dart")

    def test_independent_audit_requires_rust_cu_in_each_actual_universal_slice(self):
        self.make_universal_rust()
        self.rust_language.side_effect = lambda tool, path, *, architecture: architecture == "x86_64"
        with self.assertRaisesRegex(symbols.SymbolError, "^macos_rust_slice_missing_rust_compilation_units$"):
            self.audit()
        self.assertEqual([call.kwargs["architecture"] for call in self.rust_language.call_args_list], ["x86_64", "arm64"])
        self.assertTrue(all(call.args[1] == self.paths["rust_api"][1] for call in self.rust_language.call_args_list))

    def test_independent_audit_checks_both_rust_slices_when_they_have_cus(self):
        self.make_universal_rust()
        artifacts, evidence, _ = self.audit()
        self.assertEqual({item["architecture"] for item in evidence if item["source"] == "rust"}, {"x86_64", "arm64"})
        self.assertEqual({call.kwargs["architecture"] for call in self.rust_language.call_args_list}, {"x86_64", "arm64"})
        self.assertEqual(self.rust_tool.call_count, 1)

    def test_independent_audit_fails_closed_when_rust_tool_is_unavailable(self):
        self.rust_tool.side_effect = OSError("private-token /private/tool")
        with self.assertRaisesRegex(symbols.SymbolError, "^macos_rust_debug_verification_failed$") as failure:
            self.audit()
        self.rust_language.assert_not_called()
        self.assertNotIn("private", str(failure.exception))

    def test_independent_audit_rust_timeout_does_not_leak_tool_output(self):
        self.rust_language.side_effect = subprocess.TimeoutExpired(["private-tool"], 60,
            output="private-token /private/source", stderr="private-stderr")
        with self.assertRaisesRegex(symbols.SymbolError, "^macos_rust_debug_verification_failed$") as failure:
            self.audit()
        self.assertNotIn("private", str(failure.exception))

    def test_upload_entry_rechecks_reused_rust_companion_before_upload(self):
        # uploader consumes an already prepared manifest, independently of the
        # preparation process that created it or any prior language claim.
        self.rust_language.return_value = False
        result, evidence = self.run_main(audit_only=True)
        self.assertEqual(result, 1)
        self.assertEqual(evidence["error"], "macos_rust_slice_missing_rust_compilation_units")
        self.assertFalse(any(arguments[:2] == ["debug-files", "upload"] for arguments in self.calls))

    @unittest.skipIf(os.name == "nt", "Directory symlink alias fixture is POSIX-only")
    def test_build_root_alias_matches_canonical_app_and_dart_inventory(self):
        alias = self.root.parent / "build-alias"
        alias.symlink_to(self.root, target_is_directory=True)
        with mock.patch.object(symbols, "run_cli", side_effect=self.cli):
            artifacts, native, _ = symbols.audit_macos("sentry-cli", alias)
            companions, dart = symbols.collect_companions("sentry-cli", alias, "macos")
        self.assertEqual(len(artifacts), 3)
        self.assertEqual(len(native), 3)
        self.assertEqual(companions, [self.dart])
        self.assertEqual(dart[0]["binaries"][0], symbols.fingerprint(self.app_binary))

    def test_unicode_brand_executable_is_supported_without_becoming_a_target_label(self):
        binary, _ = self.paths["runner"]
        renamed = binary.with_name("中文客户端")
        binary.rename(renamed)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": renamed.name}))
        self.manifest["artifacts"][0]["binary"] = renamed.relative_to(self.root).as_posix()
        self.save()
        self.assertEqual(self.audit()[1][0]["target"], "runner")

    def test_mismatching_uuid_fails(self):
        self.paths["example"][1].write_bytes(macho(str(uuid.uuid4()), debug=True, text=False))
        with self.assertRaisesRegex(symbols.SymbolError, "UUID mismatch"):
            self.audit()

    def test_missing_architecture_in_fat_companion_fails(self):
        binary, _ = self.paths["example"]
        binary.write_bytes(universal([("x86_64", binary.read_bytes()), ("arm64", macho(str(uuid.uuid4()), "arm64", filetype=6))]))
        self.manifest["artifacts"].append({**self.manifest["artifacts"][-1], "architecture": "arm64"})
        self.manifest["required"].append({"target": "example", "architecture": "arm64"})
        self.save()
        with self.assertRaisesRegex(symbols.SymbolError, "missing a distributed.*architecture"):
            self.audit()

    def test_missing_dwarf_lines_fails(self):
        binary, debug = self.paths["example"]
        debug.write_bytes(debug.read_bytes().replace(b"__debug_line", b"__no_line___"))
        with self.assertRaisesRegex(symbols.SymbolError, "DWARF line"):
            self.audit()

    def test_renaming_runtime_to_dsym_cannot_upload_executable_code(self):
        binary, debug = self.paths["example"]
        shutil.copyfile(binary, debug)
        with self.assertRaisesRegex(symbols.SymbolError, "runtime Mach-O or executable"):
            self.audit()

    def test_required_and_artifact_double_delete_cannot_hide_local_pod(self):
        self.manifest["artifacts"].pop()
        self.manifest["required"].pop()
        self.save()
        with self.assertRaisesRegex(symbols.SymbolError, "locally compiled"):
            self.audit()

    def test_local_link_map_detects_module_even_after_ownership_record_is_deleted(self):
        binary, _ = self.paths["example"]
        self.manifest["artifacts"].pop()
        self.manifest["required"].pop()
        self.manifest["limitations"].append({"target": "example", "architecture": "x86_64", "source": "prebuilt", "reason": "external_debug_companion_unavailable"})
        self.owned["products"].pop()
        intermediate = self.products / "example/example.framework/example"
        intermediate.parent.mkdir(parents=True)
        intermediate.write_bytes(macho(self.ids["example"], filetype=6, oso=True))
        self.save()
        with self.assertRaisesRegex(symbols.SymbolError, "locally compiled"):
            self.audit()

    def test_unlisted_prebuilt_module_requires_explicit_limitation(self):
        path = self.app / "Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS"
        path.parent.mkdir(parents=True)
        path.write_bytes(macho(str(uuid.uuid4()), filetype=6))
        self.save()
        with self.assertRaisesRegex(symbols.SymbolError, "explicit limitation"):
            self.audit()
        self.manifest["limitations"].append({"target": "FlutterMacOS", "architecture": "x86_64", "source": "prebuilt", "reason": "external_debug_companion_unavailable"})
        self.save()
        self.assertEqual(len(self.audit()[2]), 2)

    def test_unrelated_scopes_cannot_hide_a_missing_prebuilt_runtime_companion(self):
        path = self.app / "Contents/Frameworks/FlutterMacOS.framework/FlutterMacOS"
        path.parent.mkdir(parents=True)
        path.write_bytes(macho(str(uuid.uuid4()), filetype=6))
        original = list(self.manifest["limitations"])
        for source, reason in (("go", "separate_process_no_sentry_sdk"),
                               ("dart", "split_debug_info_managed_separately"),
                               ("prebuilt", "static_binary_package_debug_coverage_unverified"),
                               ("prebuilt", "unverified")):
            with self.subTest(reason=reason):
                self.manifest["limitations"] = original + [dict(target="FlutterMacOS", architecture="x86_64",
                                                               source=source, reason=reason)]
                self.save()
                with self.assertRaisesRegex(symbols.SymbolError, "Invalid macOS .* coverage limitation"):
                    self.audit()

    def test_missing_dart_split_information_fails_even_with_native_dsyms(self):
        self.dart.unlink()
        result, evidence = self.run_main()
        self.assertEqual(result, 1)
        self.assertIn("Dart split", evidence["error"])

    def test_universal_app_requires_dart_split_info_for_both_runner_architectures(self):
        for entry in list(self.manifest["artifacts"]):
            target = entry["target"]
            binary, debug = self.paths[target]
            identifier = str(uuid.uuid5(uuid.NAMESPACE_URL, "arm64-" + target))
            binary.write_bytes(universal([("x86_64", binary.read_bytes()),
                                          ("arm64", macho(identifier, "arm64", filetype=2 if target == "runner" else 6))]))
            debug.write_bytes(universal([("x86_64", debug.read_bytes()),
                                         ("arm64", macho(identifier, "arm64", debug=True, text=False))]))
            self.manifest["artifacts"].append({**entry, "architecture": "arm64"})
            self.manifest["required"].append({"target": target, "architecture": "arm64"})
        self.app_binary.write_bytes(universal([("x86_64", self.app_binary.read_bytes()),
                                               ("arm64", macho(str(uuid.uuid4()), "arm64", filetype=6))]))
        self.manifest["limitations"].append({"target": "App", "architecture": "arm64", "source": "dart", "reason": "split_debug_info_managed_separately"})
        self.save()
        result, evidence = self.run_main()
        self.assertEqual(result, 1)
        self.assertIn("missing a distributed architecture", evidence["error"])

    def test_same_architecture_wrong_dart_uuid_cannot_pass(self):
        self.dart.write_bytes(macho(str(uuid.uuid4()), debug=True, text=False))
        result, evidence = self.run_main()
        self.assertEqual(result, 1)
        self.assertIn("do not match final App.framework", evidence["error"])

    def test_complete_aot_macho_renamed_as_dart_symbols_cannot_upload(self):
        shutil.copyfile(self.app_binary, self.dart)
        result, evidence = self.run_main()
        self.assertEqual(result, 1)
        self.assertIn("runtime Mach-O or executable code", evidence["error"])

    def test_legacy_macos_split_without_usable_identifier_fails_with_version_guidance(self):
        original = self.cli
        def legacy_metadata(executable, arguments):
            if arguments[:2] == ["debug-files", "check"] and arguments[-1].endswith(".symbols"):
                return json.dumps({"type": "elf", "variants": [{"debug_id": "00000000-0000-0000-0000-000000000000", "arch": "x86_64"}],
                                   "features": "debug", "is_usable": False})
            return original(executable, arguments)
        self.cli = legacy_metadata
        result, evidence = self.run_main()
        self.assertEqual(result, 1)
        self.assertIn("pinned macOS Flutter Mach-O snapshot", evidence["error"])

    def test_missing_token_fails_release_on_macos(self):
        result, evidence = self.run_main(token="")
        self.assertEqual(result, 1)
        self.assertIn("requires SENTRY_AUTH_TOKEN", evidence["error"])

    def test_dart_split_filename_cannot_hide_a_different_real_architecture(self):
        original = self.cli
        def wrong_architecture(executable, arguments):
            result = original(executable, arguments)
            if arguments[:2] == ["debug-files", "check"] and arguments[-1].endswith(".symbols"):
                return result.replace('"arch": "x86_64"', '"arch": "arm64"')
            return result
        self.cli = wrong_architecture
        result, evidence = self.run_main()
        self.assertEqual(result, 1)
        self.assertIn("filename does not match its architecture", evidence["error"])

    def test_upload_contains_only_dwarf_companions_and_dart_split_info(self):
        result, evidence = self.run_main()
        self.assertEqual(result, 0)
        self.assertEqual(evidence["status"], "uploaded_and_processed")

    def test_audit_only_is_offline_and_does_not_require_token(self):
        result, evidence = self.run_main(token="", audit_only=True)
        self.assertEqual(result, 0)
        self.assertEqual(evidence["status"], "audited")
        self.assertFalse(any(args[:2] == ["debug-files", "upload"] for args in self.calls))

    def test_debug_companion_symlink_cannot_escape_build_root(self):
        _, debug = self.paths["example"]
        external = self.root.parent / "external-debug"
        shutil.copyfile(debug, external)
        debug.unlink()
        try:
            debug.symlink_to(external)
        except OSError as error:
            self.skipTest(f"Symbolic links are unavailable on this host: {type(error).__name__}")
        with self.assertRaisesRegex(symbols.SymbolError, "escaped"):
            self.audit()

    def test_parser_handles_universal_uuid_and_oso_without_exposing_symbols(self):
        path = self.root / "fat-fixture"
        ids = [str(uuid.uuid4()), str(uuid.uuid4())]
        path.write_bytes(universal([("x86_64", macho(ids[0], oso=True)), ("arm64", macho(ids[1], "arm64"))]))
        info = inspect_macho(path)
        self.assertTrue(info["is_fat"])
        self.assertEqual([item["uuid"] for item in info["variants"]], ids)
        self.assertTrue(info["variants"][0]["has_oso_symbols"])
        self.assertFalse(info["variants"][1]["has_oso_symbols"])

    def test_parser_rejects_truncated_command_table(self):
        path = self.root / "broken-fixture"
        path.write_bytes(macho(str(uuid.uuid4()))[:40])
        with self.assertRaises(MachoError):
            inspect_macho(path)


class RealMachOFixtureTest(unittest.TestCase):
    def test_clang_linked_native_runner_and_real_dsym_have_matching_uuid_and_lines(self):
        # Cross-link only a tiny standalone C fixture on Linux. No project build.
        clang = shutil.which("clang")
        lld = os.environ.get("SENTRY_TEST_LD64") or shutil.which("ld64.lld")
        dsym = os.environ.get("SENTRY_TEST_DSYMUTIL") or shutil.which("dsymutil")
        cli = shutil.which("sentry-cli")
        if not all((clang, lld, dsym, cli)):
            self.skipTest("Offline Mach-O fixture tools were not supplied")
        with tempfile.TemporaryDirectory(prefix="sentry-real-macho-") as temporary:
            root = Path(temporary).resolve()
            source = root / "fixture.c"
            source.write_text("int sum(int n) { return n+11; } int main(void) { return sum(5); }\n")
            commands = [[clang, "--target=x86_64-apple-macos11", "-g", "-O2", "-c", str(source), "-o", str(root / "fixture.o")],
                        [lld, "-arch", "x86_64", "-platform_version", "macos", "11.0", "14.0", "-e", "_main", "-o", str(root / "runner"), str(root / "fixture.o")],
                        [dsym, str(root / "runner"), "-o", str(root / "runner.dSYM")]]
            for command in commands:
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
            binary = root / "runner"
            debug = root / "runner.dSYM/Contents/Resources/DWARF/runner"
            first, second = (inspect_macho(path)["variants"][0] for path in (binary, debug))
            self.assertEqual(first["uuid"], second["uuid"])
            self.assertTrue(second["has_debug_info"] and second["has_debug_line"])
            self.assertFalse(second["has_executable_text"])
            binary_info = symbols.check_symbol(cli, binary, "dsym", require_usable=False)
            debug_info = symbols.check_symbol(cli, debug, "dsym")
            self.assertEqual(binary_info["debug_ids"], debug_info["debug_ids"])
            self.assertIn("debug", debug_info["features"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
