#!/usr/bin/env python3
"""Offline Maven/ZIP fixtures with real C ELF files; no client build or upload."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import warnings
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sentry_android_prefab as prefab  # noqa: E402
from sentry_elf import ElfError, inspect_elf  # noqa: E402


@unittest.skipUnless(sys.platform == "linux" and shutil.which("cc") and shutil.which("objcopy"),
                     "Linux C/ELF fixture tools unavailable")
class PrefabTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory(prefix="sentry-prefab-elf-")
        cls.addClassCleanup(cls.fixtures.cleanup)
        cls.fixture_root = Path(cls.fixtures.name).resolve()
        source = cls.fixture_root / "fixture.c"
        source.write_text('const char message[] = "fixture constant";\n'
                          'int fixture(int x) { return x + message[0] + 42; }\n')
        cls.elf = cls.fixture_root / "fixture.so"
        subprocess.run(["cc", "-g", "-shared", "-fPIC", "-Wl,--build-id=sha1",
                        str(source), "-o", str(cls.elf)], check=True, capture_output=True)
        cls.arch = inspect_elf(cls.elf)["architecture"]
        if cls.arch not in {"x86_64", "aarch64"}:
            raise unittest.SkipTest("Unsupported host ELF fixture architecture")
        cls.abi = {"x86_64": "x86_64", "aarch64": "arm64-v8a"}[cls.arch]

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sentry-prefab-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.gradle = self.root / "gradle"
        self.coordinate = self.gradle / "caches/modules-2/files-2.1/io.sentry/sentry-native-ndk"
        self.output = self.root / "output"
        self.output.mkdir()
        self.runtime = self.root / "runtime.so"
        subprocess.run(["objcopy", "--strip-debug", str(self.elf), str(self.runtime)],
                       check=True, capture_output=True)

    def member(self, target="libsentry.so", abi=None):
        module = {"libsentry.so": "sentry", "libsentry-android.so": "sentry-android"}[target]
        return f"prefab/modules/{module}/libs/android.{abi or self.abi}/{target}"

    def aar(self, entries=None, version="0.16.6", digest="a", target="libsentry.so"):
        path = self.coordinate / version / digest / "sentry-native-ndk.aar"
        path.parent.mkdir(parents=True, exist_ok=True)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
                for name, data in (entries if entries is not None else
                                   [(self.member(target), self.elf.read_bytes())]):
                    archive.writestr(name, data)
        return path

    def candidates(self, target="libsentry.so", **kwargs):
        return prefab.prefab_candidates(self.runtime, self.abi, target, self.output,
                                        kwargs.pop("gradle_user_home", self.gradle), **kwargs)

    def variant(self, name, *arguments):
        path = self.root / (name + ".so")
        subprocess.run(["objcopy", *arguments, str(self.elf), str(path)],
                       check=True, capture_output=True)
        return path

    def changed_section(self, section):
        data = self.root / "section.bin"
        subprocess.run(["objcopy", "--dump-section", f"{section}={data}", str(self.elf)],
                       check=True, capture_output=True)
        content = bytearray(data.read_bytes())
        content[0] ^= 1
        data.write_bytes(content)
        return self.variant(section, "--update-section", f"{section}={data}")

    def test_correct_prefab_targets_and_only_allowlisted_extraction(self):
        self.aar([(self.member(target), self.elf.read_bytes())
                  for target in sorted(prefab.SENTRY_ANDROID_TARGETS)] +
                 [("jni/" + self.abi + "/libsentry.so", b"not an ELF"),
                  ("classes.jar", b"unrelated"), ("assets/secret.txt", b"private")])
        for target in sorted(prefab.SENTRY_ANDROID_TARGETS):
            result = self.candidates(target)
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0].name, target)
            self.assertTrue(result[0].is_relative_to(self.output))
            self.assertEqual(result[0].read_bytes(), self.elf.read_bytes())
            self.assertTrue(inspect_elf(result[0])["has_debug_info"])
        self.assertEqual(sorted(path.name for path in self.output.rglob("*") if path.is_file()),
                         sorted(prefab.SENTRY_ANDROID_TARGETS))

    def test_custom_gradle_cache_does_not_require_home_directory(self):
        self.aar()
        for explicit in (False, True):
            with self.subTest(explicit=explicit), \
                 mock.patch.dict(os.environ, {"GRADLE_USER_HOME": str(self.gradle)}, clear=True), \
                 mock.patch.object(prefab.Path, "home", side_effect=RuntimeError("home directory unavailable")) as home:
                result = prefab.prefab_candidates(self.runtime, self.abi, "libsentry.so", self.output,
                    gradle_user_home=self.gradle if explicit else None)
                self.assertEqual(len(result), 1)
                self.assertEqual(result[0].read_bytes(), self.elf.read_bytes())
                home.assert_not_called()

    def test_mixed_versions_and_abis_select_by_content_not_newest(self):
        wrong = self.changed_section(".text")
        self.aar(version="0.14.2")
        self.aar([(self.member(), wrong.read_bytes())], version="99.0.0")
        self.aar([(self.member(abi="armeabi-v7a"), self.elf.read_bytes())], version="100.0.0")
        result = self.candidates()
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0].read_bytes(), self.elf.read_bytes())

    def test_same_build_id_different_text_or_rodata_never_matches(self):
        original = inspect_elf(self.elf)
        for index, section in enumerate((".text", ".rodata")):
            with self.subTest(section=section):
                changed = self.changed_section(section)
                info = inspect_elf(changed)
                self.assertEqual(original["build_id"], info["build_id"])
                self.assertNotEqual(original["code_sections"], info["code_sections"])
                self.aar([(self.member(), changed.read_bytes())], digest=str(index))
        self.assertEqual(self.candidates(), [])
        self.assertEqual(list(self.output.iterdir()), [])

    def test_different_build_id_never_matches(self):
        data = self.root / "build-id.note"
        data.write_bytes(struct.pack("<III", 4, 20, 3) + b"GNU\0" + b"\xaa" * 20)
        changed = self.variant("id", "--update-section", f".note.gnu.build-id={data}")
        self.aar([(self.member(), changed.read_bytes())])
        self.assertEqual(self.candidates(), [])

    def test_wrong_elf_architecture_never_matches(self):
        data = bytearray(self.elf.read_bytes())
        struct.pack_into("<H", data, 18, 183 if self.arch == "x86_64" else 62)
        self.aar([(self.member(), data)])
        self.assertEqual(self.candidates(), [])

    def test_missing_dwarf_info_line_or_code_section_never_matches(self):
        for index, section in enumerate((".debug_info", ".debug_line", ".text", ".rodata")):
            changed = self.variant(str(index), "--remove-section", section)
            self.aar([(self.member(), changed.read_bytes())], digest=str(index))
        self.assertEqual(self.candidates(), [])

    def test_empty_cache_missing_member_and_wrong_coordinate_yield_empty(self):
        self.assertEqual(self.candidates(), [])
        self.aar([("jni/" + self.abi + "/libsentry.so", self.elf.read_bytes())])
        outside = self.gradle / "caches/transforms-4/ignored/prefab.so"
        outside.parent.mkdir(parents=True)
        outside.write_bytes(self.elf.read_bytes())
        self.assertEqual(self.candidates(), [])
        self.assertEqual(list(self.output.iterdir()), [])

    def test_explicit_home_environment_and_default_home_precedence(self):
        self.aar()
        with mock.patch.dict(os.environ, {"GRADLE_USER_HOME": str(self.root / "missing")}):
            self.assertEqual(len(self.candidates()), 1)
            self.assertEqual(self.candidates(gradle_user_home=None), [])
        with mock.patch.dict(os.environ, {"GRADLE_USER_HOME": str(self.gradle)}):
            self.assertEqual(len(self.candidates(gradle_user_home=None)), 1)
        default_home = self.root / "home"
        default_home.mkdir()
        shutil.move(str(self.gradle), str(default_home / ".gradle"))
        with mock.patch.dict(os.environ, {"GRADLE_USER_HOME": ""}), \
                mock.patch.object(Path, "home", return_value=default_home):
            self.assertEqual(len(self.candidates(gradle_user_home=None)), 1)

    def test_invalid_abi_target_or_runtime_fail_with_stable_codes(self):
        for abi, target in (("x86", "libsentry.so"), (self.abi, "libother.so")):
            with self.assertRaisesRegex(prefab.PrefabError, "^prefab_invalid_request$"):
                prefab.prefab_candidates(self.runtime, abi, target, self.output, self.gradle)
        for flags in (("--remove-section", ".note.gnu.build-id"),
                      ("--remove-section", ".text"), ("--remove-section", ".rodata")):
            self.runtime = self.variant("runtime", *flags)
            with self.assertRaisesRegex(prefab.PrefabError, "^prefab_invalid_runtime$"):
                self.candidates()

    def test_duplicate_zip_member_fails_and_cleans_prior_matches(self):
        self.aar(version="0")
        self.aar([(self.member(), self.elf.read_bytes())] * 2, version="1")
        with self.assertRaisesRegex(prefab.PrefabError, "^prefab_zip_duplicate_member$"):
            self.candidates()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_unsafe_zip_paths_symlink_and_special_members_are_rejected(self):
        members = ["../escape", "/escape", "a/../escape", "a//escape", "a/./escape",
                   "a\\escape", "C:/escape"]
        for kind in (stat.S_IFLNK, stat.S_IFIFO):
            entry = zipfile.ZipInfo("unrelated")
            entry.create_system = 3
            entry.external_attr = (kind | 0o777) << 16
            members.append(entry)
        for member in members:
            with self.subTest(member=str(member)):
                self.aar([(self.member(), self.elf.read_bytes()), (member, b"unsafe")])
                with self.assertRaisesRegex(prefab.PrefabError, "^prefab_zip_unsafe_member$"):
                    self.candidates()
                self.assertEqual(list(self.output.iterdir()), [])

    def test_embedded_nul_zip_member_is_rejected(self):
        archive = self.aar([(self.member(), self.elf.read_bytes()), ("a_hidden", b"unsafe")])
        # ZipFile's writer sanitizes NULs, so mutate both on-disk name records.
        archive.write_bytes(archive.read_bytes().replace(b"a_hidden", b"a\0hidden"))
        with self.assertRaisesRegex(prefab.PrefabError, "^prefab_zip_unsafe_member$"):
            self.candidates()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_symlink_cache_parent_archive_and_temporary_root_are_rejected(self):
        archive = self.aar()
        for path in (archive, archive.parent, self.gradle, self.output):
            with self.subTest(path=path.name):
                moved = path.with_name(path.name + "-real")
                path.rename(moved)
                path.symlink_to(moved, target_is_directory=moved.is_dir())
                try:
                    with self.assertRaisesRegex(prefab.PrefabError, "^prefab_unsafe_path$"):
                        self.candidates()
                finally:
                    path.unlink()
                    moved.rename(path)

    def test_corrupt_archive_or_elf_never_falls_back_to_valid_version(self):
        self.aar(version="0")
        corrupt = self.aar(version="1")
        corrupt.write_bytes(b"bad ZIP private source path")
        with self.assertRaisesRegex(prefab.PrefabError, "^prefab_source_invalid$"):
            self.candidates()
        self.assertEqual(list(self.output.iterdir()), [])
        self.aar([(self.member(), b"not ELF")], version="1")
        with self.assertRaisesRegex(prefab.PrefabError, "^prefab_invalid_elf$"):
            self.candidates()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_windows_reparse_directory_attribute_is_rejected(self):
        self.aar()
        real_lstat = Path.lstat

        def metadata(path, *args, **kwargs):
            if path == self.gradle:
                return SimpleNamespace(st_mode=stat.S_IFDIR | 0o700, st_file_attributes=0x400)
            return real_lstat(path, *args, **kwargs)

        with mock.patch.object(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400, create=True), \
                mock.patch.object(Path, "lstat", metadata):
            with self.assertRaisesRegex(prefab.PrefabError, "^prefab_unsafe_path$"):
                self.candidates()

    def test_symlink_before_parent_traversal_cannot_hide_in_home_path(self):
        self.aar()
        link = self.root / "link"
        link.symlink_to(self.output, target_is_directory=True)
        with self.assertRaisesRegex(prefab.PrefabError, "^prefab_unsafe_path$"):
            self.candidates(gradle_user_home=link / ".." / "gradle")

    def test_zip_crc_damage_is_not_silently_ignored(self):
        archive = self.aar()
        with zipfile.ZipFile(archive) as source:
            entry = source.getinfo(self.member())
            header = entry.header_offset
        data = bytearray(archive.read_bytes())
        name_size, extra_size = struct.unpack_from("<HH", data, header + 26)
        data[header + 30 + name_size + extra_size + 1] ^= 0xff
        archive.write_bytes(data)
        with self.assertRaisesRegex(prefab.PrefabError, "^prefab_source_invalid$"):
            self.candidates()
        self.assertEqual(list(self.output.iterdir()), [])

    def test_archive_member_and_aggregate_limits(self):
        self.aar()
        for constant, value, code in (("_MAX_ARCHIVE_BYTES", 1, "prefab_archive_limit"),
                                      ("_MAX_MEMBER_BYTES", 1, "prefab_member_limit"),
                                      ("_MAX_EXTRACTED_BYTES", 1, "prefab_member_limit"),
                                      ("_MAX_ZIP_ENTRIES", 0, "prefab_zip_limit"),
                                      ("_MAX_CANDIDATES", 0, "prefab_cache_limit"),
                                      ("_MAX_DIRECTORY_ENTRIES", 0, "prefab_cache_limit")):
            with self.subTest(constant=constant), mock.patch.object(prefab, constant, value):
                with self.assertRaisesRegex(prefab.PrefabError, f"^{code}$"):
                    self.candidates()
                self.assertEqual(list(self.output.iterdir()), [])

    def test_encrypted_archive_member_is_rejected(self):
        archive = self.aar()
        data = bytearray(archive.read_bytes())
        central = data.index(b"PK\x01\x02")
        flags = struct.unpack_from("<H", data, central + 8)[0]
        struct.pack_into("<H", data, central + 8, flags | 1)
        archive.write_bytes(data)
        with self.assertRaisesRegex(prefab.PrefabError, "^prefab_zip_encrypted$"):
            self.candidates()

    def test_elf_code_sections_use_real_bytes_sizes_addresses_and_ignore_nobits(self):
        info = inspect_elf(self.elf)
        self.assertEqual(set(info["code_sections"]), {".text", ".rodata"})
        for section, facts in info["code_sections"].items():
            data = self.root / "dump.bin"
            subprocess.run(["objcopy", "--dump-section", f"{section}={data}", str(self.elf)],
                           check=True, capture_output=True)
            self.assertEqual(facts["sha256"], hashlib.sha256(data.read_bytes()).hexdigest())
            self.assertEqual(facts["size"], data.stat().st_size)
            self.assertGreater(facts["address"], 0)
        absent = self.variant("no-rodata", "--remove-section", ".rodata")
        self.assertEqual(set(inspect_elf(absent)["code_sections"]), {".text"})
        data = bytearray(self.elf.read_bytes())
        offset = struct.unpack_from("<Q", data, 40)[0]
        width, count, names_index = struct.unpack_from("<HHH", data, 58)
        names_header = offset + width * names_index
        names_start, names_size = struct.unpack_from("<QQ", data, names_header + 24)
        names = data[names_start:names_start + names_size]
        for index in range(count):
            record = offset + width * index
            name = struct.unpack_from("<I", data, record)[0]
            if names[name:names.find(0, name)] == b".text":
                struct.pack_into("<I", data, record + 4, 8)
        no_text = self.root / "nobits.so"
        no_text.write_bytes(data)
        self.assertNotIn(".text", inspect_elf(no_text)["code_sections"])

    def test_duplicate_elf_code_section_is_rejected(self):
        data = bytearray(self.elf.read_bytes())
        offset = struct.unpack_from("<Q", data, 40)[0]
        width, count, names_index = struct.unpack_from("<HHH", data, 58)
        names_header = offset + width * names_index
        names_start, names_size = struct.unpack_from("<QQ", data, names_header + 24)
        names = data[names_start:names_start + names_size]
        for index in range(count):
            record = offset + width * index
            name = struct.unpack_from("<I", data, record)[0]
            if names[name:names.find(0, name)] == b".rodata":
                struct.pack_into("<I", data, record, names.index(b".text\0"))
        duplicate = self.root / "duplicate.so"
        duplicate.write_bytes(data)
        with self.assertRaisesRegex(ElfError, "^Duplicate ELF code section$"):
            inspect_elf(duplicate)


if __name__ == "__main__":
    unittest.main()
