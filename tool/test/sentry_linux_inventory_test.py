#!/usr/bin/env python3
"""Offline C/ELF inventory fixtures; never build or execute the client."""

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
from sentry_elf import inspect_elf  # noqa: E402
from sentry_linux_inventory import collect_linux_inventory, LinuxInventoryError  # noqa: E402


@unittest.skipUnless(sys.platform == "linux" and shutil.which("cc") and shutil.which("objcopy"),
                     "Linux C/ELF fixture tools unavailable")
class LinuxInventoryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.fixtures.cleanup)
        directory = Path(cls.fixtures.name).resolve()
        code = directory / "fixture.c"
        code.write_text('const char* label(void) { return "inventory"; }\n'
                        'int fixture(int x) { return x + 42; }\n'
                        'int main(void) { return fixture(1); }\n')
        cls.full = directory / "full"
        subprocess.run(["cc", "-g", "-Wl,--build-id=sha1", str(code), "-o", str(cls.full)], check=True)
        facts = inspect_elf(cls.full)
        if facts["architecture"] not in {"x86_64", "aarch64"}:
            raise unittest.SkipTest("Unsupported Linux fixture architecture")
        cls.architecture = {"x86_64": "x64", "aarch64": "arm64"}[facts["architecture"]]
        cls.stripped = directory / "stripped"
        shutil.copyfile(cls.full, cls.stripped)
        subprocess.run(["objcopy", "--strip-debug", str(cls.stripped)], check=True)
        # Keep the identifier deliberately equal while changing actual code.
        # The inventory must compare code as well as the embedded identifier.
        code.write_text(code.read_text().replace("x + 42", "x + 43"))
        cls.changed = directory / "changed"
        subprocess.run(["cc", "-g", "-Wl,--build-id=0x" + facts["build_id"],
                        str(code), "-o", str(cls.changed)], check=True)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.build = Path(self.temp.name).resolve() / "build"
        self.native = self.build / "linux" / self.architecture / "release"
        self.bundle = self.native / "bundle"
        self.manifest = self.native / "sentry-native-Release.tsv"
        self.rows = []
        self.runtime("FlClash")
        self.runtime("lib/librust_api.so")
        self.runtime("FlClashCore")
        self.source("runner/FlClash", "runner_target")

    def runtime(self, relative, original=None):
        path = self.bundle / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original or self.stripped, path)
        return path

    def source(self, relative, target="source_target"):
        path = self.native / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.full, path)
        self.rows.append(f"{target}\t{path}")
        self.write_manifest()
        return path

    def write_manifest(self):
        self.manifest.write_text("\n".join(self.rows) + "\n")

    def collect(self):
        return collect_linux_inventory(self.build, self.architecture, "release")

    def test_extensionless_handler_and_versioned_so_are_required_with_target_name_difference(self):
        self.runtime("lib/crashpad_handler")
        handler = self.source("_deps/sentry-native-build/crashpad_build/handler/crashpad_handler",
                              "handler_cmake_target")
        self.runtime("lib/libversioned.so.2")
        versioned = self.source("plugins/versioned/libversioned.so.2", "versioned_plugin")
        result = self.collect()
        self.assertEqual(result["native"], self.native)
        self.assertEqual(result["bundle"], self.bundle)
        self.assertEqual(result["required"],
                         {"FlClash", "FlClashCore", "librust_api.so", "crashpad_handler", "libversioned.so.2"})
        self.assertEqual(result["sources"]["crashpad_handler"], [handler])
        self.assertEqual(result["sources"]["libversioned.so.2"], [versioned])

    def test_same_basename_cmake_sources_are_retained_and_uninstalled_sources_need_not_exist(self):
        self.runtime("lib/crashpad_handler")
        first = self.source("_deps/one/crashpad_handler", "handler_one")
        second = self.source("_deps/two/crashpad_handler", "handler_two")
        self.rows.append(f"unused_target\t{self.native / '_deps/unused/not_installed'}")
        self.write_manifest()
        self.assertEqual(self.collect()["sources"]["crashpad_handler"], [first, second])

    def test_root_lib_and_bin_runtime_copies_share_symbols_despite_strip_differences(self):
        paths = [self.runtime("crashpad_handler"), self.runtime("lib/crashpad_handler"),
                 self.runtime("bin/crashpad_handler", self.full)]
        self.source("_deps/crashpad/crashpad_handler")
        self.assertNotEqual(paths[0].read_bytes(), paths[2].read_bytes())
        self.assertEqual(set(self.collect()["modules"]["crashpad_handler"]), set(paths))

    def test_conflicting_runtime_code_cannot_share_a_build_identifier(self):
        self.runtime("lib/crashpad_handler")
        self.runtime("bin/crashpad_handler", self.changed)
        self.source("_deps/crashpad/crashpad_handler")
        self.assertEqual(inspect_elf(self.full)["build_id"], inspect_elf(self.changed)["build_id"])
        with self.assertRaisesRegex(LinuxInventoryError, "^conflicting_bundle_native_modules$"):
            self.collect()

    def test_conflicting_runtime_unwind_requirements_cannot_share_a_companion(self):
        self.runtime("lib/crashpad_handler")
        other = self.runtime("bin/crashpad_handler")
        self.source("_deps/crashpad/crashpad_handler")
        subprocess.run(["objcopy", "--remove-section", ".eh_frame", "--remove-section", ".eh_frame_hdr",
                        str(other)], check=True, capture_output=True)
        with self.assertRaisesRegex(LinuxInventoryError, "^conflicting_bundle_native_modules$"):
            self.collect()

    def test_internal_file_and_directory_symlink_aliases_are_deduplicated(self):
        handler = self.runtime("lib/crashpad_handler")
        self.source("_deps/crashpad/crashpad_handler")
        (self.bundle / "handler_alias").symlink_to("lib/crashpad_handler")
        (self.bundle / "lib_alias").symlink_to("lib", target_is_directory=True)
        result = self.collect()
        self.assertEqual(result["modules"]["crashpad_handler"], [handler])
        self.assertNotIn("handler_alias", result["modules"])

    def test_internal_source_symlink_uses_resolved_basename(self):
        self.runtime("lib/crashpad_handler")
        handler = self.source("_deps/crashpad/crashpad_handler")
        alias = self.native / "source_alias"
        alias.symlink_to(handler)
        self.rows[-1] = f"handler_alias_target\t{alias}"
        self.write_manifest()
        self.assertEqual(self.collect()["sources"]["crashpad_handler"], [handler])

    def test_missing_manifest_and_runner_mapping_have_stable_errors(self):
        self.manifest.unlink()
        with self.assertRaisesRegex(LinuxInventoryError, "^cmake_source_manifest_missing$"):
            self.collect()
        self.manifest.write_text("")
        with self.assertRaisesRegex(LinuxInventoryError, "^runner_source_manifest_missing$"):
            self.collect()

    def test_missing_mandatory_runtime_has_stable_errors(self):
        for relative, reason in [("FlClash", "required_bundle_native_module_missing"),
                                 ("lib/librust_api.so", "required_bundle_native_module_missing")]:
            with self.subTest(relative=relative):
                (self.bundle / relative).unlink()
                with self.assertRaisesRegex(LinuxInventoryError, "^" + reason + "$"):
                    self.collect()
                self.runtime(relative)

    def test_missing_go_core_is_left_to_production_preparation_policy(self):
        (self.bundle / "FlClashCore").unlink()
        result = self.collect()
        self.assertNotIn("FlClashCore", result["modules"])
        self.assertNotIn("FlClashCore", result["required"])

    def test_distributed_handler_requires_cmake_source_declaration(self):
        self.runtime("lib/crashpad_handler")
        with self.assertRaisesRegex(LinuxInventoryError, "^crashpad_source_manifest_missing$"):
            self.collect()

    def test_truncated_tsv_cannot_hide_a_local_deps_executable(self):
        self.runtime("bin/local_helper")
        self.source("_deps/package-build/local_helper")
        self.rows.pop()
        self.write_manifest()
        with self.assertRaisesRegex(LinuxInventoryError, "^local_plugin_source_manifest_missing$"):
            self.collect()

    def test_prebuilt_module_and_non_elf_resources_are_not_required(self):
        self.runtime("lib/libprebuilt.so.1")
        (self.bundle / "lib/not_native.so").write_text("a resource, despite its suffix")
        (self.bundle / "resource").write_bytes(b"plain text")
        result = self.collect()
        self.assertIn("libprebuilt.so.1", result["modules"])
        self.assertNotIn("libprebuilt.so.1", result["required"])
        self.assertNotIn("not_native.so", result["modules"])
        self.assertNotIn("resource", result["modules"])

    def test_external_local_symlink_is_not_opened_as_a_candidate(self):
        self.runtime("lib/libprebuilt.so.1")
        directory = self.native / "_deps/external"
        directory.mkdir(parents=True)
        (directory / "libprebuilt.so.1").symlink_to(self.full)
        (self.native / "_deps/external_directory").symlink_to(self.full.parent, target_is_directory=True)
        self.assertNotIn("libprebuilt.so.1", self.collect()["required"])

    def test_tsv_path_or_symlink_cannot_escape_native_build(self):
        alias = self.native / "foreign_source"
        alias.symlink_to(self.full)
        for source in [self.full, alias]:
            with self.subTest(source=source):
                self.manifest.write_text(f"runner_target\t{source}\n")
                with self.assertRaisesRegex(LinuxInventoryError, "^unsafe_cmake_source_path$"):
                    self.collect()

    def test_bundle_file_or_directory_symlink_cannot_escape_before_opening(self):
        for name, destination in [("foreign", self.full), ("foreign_directory", self.full.parent)]:
            alias = self.bundle / name
            alias.symlink_to(destination, target_is_directory=destination.is_dir())
            with self.subTest(name=name), mock.patch("sentry_linux_inventory._is_elf") as is_elf:
                with self.assertRaisesRegex(LinuxInventoryError, "^unsafe_bundle_native_path$"):
                    self.collect()
                is_elf.assert_not_called()
            alias.unlink()

    def test_invalid_target_or_tsv_column_count_is_rejected(self):
        for row in [f"bad target\t{self.native / 'runner/FlClash'}", "target\tpath\textra"]:
            self.manifest.write_text(row + "\n")
            with self.assertRaisesRegex(LinuxInventoryError, "^invalid_cmake_source_manifest$"):
                self.collect()


if __name__ == "__main__":
    unittest.main()
