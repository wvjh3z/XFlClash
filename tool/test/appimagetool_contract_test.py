"""Real pinned AppImageKit argument/runtime contract; no client/native compilation.

Run prepare_appimagetool.py first. APPIMAGETOOL_REQUIRE_REAL=1 makes unavailable
real-tool prerequisites fail (CI/local release gates). No test downloads tools,
executes the synthetic ELF payload, or executes a foreign architecture runtime.
"""
from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("prepare_appimagetool", REPO / "tool/prepare_appimagetool.py")
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)


def synthetic_elf(machine: int) -> bytes:
    header = bytearray(64)
    header[:7] = b"\x7fELF\x02\x01\x01"
    struct.pack_into("<HHI", header, 16, 3, machine, 1)
    struct.pack_into("<H", header, 52, 64)
    return bytes(header)


class PreparationSafetyTest(unittest.TestCase):
    def test_wrong_host_target_fails_before_download_or_output(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(TOOL, "host_arch", return_value="x86_64"), patch.object(TOOL, "fetch_asset") as fetch:
            output = Path(temporary) / "absent"
            with self.assertRaisesRegex(RuntimeError, "does not match target"):
                TOOL.prepare(output, target_arch="arm64")
            fetch.assert_not_called()
            self.assertFalse(output.exists())

    def test_checksum_failure_prevents_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            source = Path(temporary) / "assets"
            source.mkdir()
            for pin in TOOL.PIN["assets"].values():
                (source / pin["name"]).write_bytes(b"changed download")
            with patch.object(TOOL, "host_arch", return_value="x86_64"), patch.object(TOOL.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "checksum mismatch"):
                    TOOL.prepare(Path(temporary) / "output", source)
                run.assert_not_called()

    def test_release_gates_use_same_pinned_tool_and_require_real_probe(self):
        for relative in (".github/workflows/release-package.yml", "scripts/package_desktop_local.sh"):
            with self.subTest(path=relative):
                source = (REPO / relative).read_text()
                self.assertIn("tool/prepare_appimagetool.py", source)
                self.assertIn("--target-arch", source)
                self.assertIn("--print-bin-dir", source)
                if relative.endswith('.yml'):
                    self.assertIn('tool/distributor_preflight.py cold', source)
                    entry = (REPO / 'tool/distributor_preflight.py').read_text(encoding='utf-8')
                else:
                    entry = source
                self.assertIn("APPIMAGETOOL_REQUIRE_REAL", entry)
                self.assertIn("tool.test.appimagetool_contract_test", entry)
                self.assertNotIn("releases/download/continuous/appimagetool", source)
        self.assertIn(".local-build", str(TOOL.OUTPUT))


class RealAppImageToolContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.output = Path(os.environ.get("APPIMAGETOOL_DIRECTORY", str(TOOL.OUTPUT))).resolve()
        cls.binary = cls.output / "bin/appimagetool"
        try:
            cls.arch = TOOL.host_arch()
            if not shutil.which("unsquashfs") or not cls.binary.is_file():
                raise RuntimeError("Prepare the pinned appimagetool and install squashfs-tools before the real probe")
            for arch, pin in TOOL.PIN["assets"].items():
                TOOL.verify_asset(cls.output / "downloads" / pin["name"], arch)
            TOOL.check_version(cls.binary)
            cls.runtime = cls.output / "runtime-aarch64"
            arm = TOOL.verify_asset(cls.output / "downloads" / TOOL.PIN["assets"]["aarch64"]["name"], "aarch64")
            if cls.runtime.read_bytes() != arm[:TOOL.appimage_offset(arm)]:
                raise RuntimeError("Probe ARM runtime differs from the pinned official ARM asset prefix")
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            if os.environ.get("APPIMAGETOOL_REQUIRE_REAL") == "1":
                raise RuntimeError(str(error)) from error
            raise unittest.SkipTest(str(error)) from error

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="xfl-real-appimagetool-")
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)

    def appdir(self, machine=183, decoy=True):
        appdir = self.work / "Contract.AppDir"
        libraries = appdir / "usr/lib"
        libraries.mkdir(parents=True)
        (appdir / "AppRun").write_bytes(synthetic_elf(machine))
        (appdir / "AppRun").chmod(0o755)
        (libraries / "libcontract.so.1").write_bytes(synthetic_elf(machine))
        if decoy:
            # 5735cc5's fallback scanner reads e_machine at byte 18 without
            # validating ELF magic. This is deliberately NOT a foreign ELF.
            text = bytearray(b"plain non ELF data" + bytes(47))
            struct.pack_into("<H", text, 18, 62)
            (libraries / "libtext.so.1").write_bytes(text)
        (appdir / "contract.desktop").write_text(
            "[Desktop Entry]\nType=Application\nName=Contract Probe\nExec=AppRun\nIcon=contract\nCategories=Utility;\n"
        )
        (appdir / "contract.svg").write_text('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="blue"/></svg>\n')
        return appdir

    def invoke(self, appdir, architecture, runtime=None):
        image = self.work / "probe.AppImage"
        args = [str(self.binary), "--no-appstream", "--mksquashfs-opt=-processors", "--mksquashfs-opt=1"]
        if runtime is not None:
            args += ["--runtime-file", str(runtime)]
        args += [str(appdir), str(image)]
        env = dict(os.environ, ARCH=architecture)
        for name in ("APPIMAGE", "APPDIR", "VERSION", "SOURCE_DATE_EPOCH"):
            env.pop(name, None)
        result = subprocess.run(args, cwd=self.work, env=env, capture_output=True, text=True, timeout=60)
        return result, image

    def assert_image(self, image, appdir, machine):
        data = image.read_bytes()
        self.assertEqual(TOOL.elf_machine(data), machine)
        offset = TOOL.appimage_offset(data)
        # Read the SquashFS with a different, real system parser; a matching
        # architecture log/magic or exit 0 alone cannot satisfy this contract.
        result = subprocess.run(["unsquashfs", "-s", "-offset", str(offset), str(image)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        extracted = self.work / "payload"
        result = subprocess.run(["unsquashfs", "-processors", "1", "-offset", str(offset), "-dest", str(extracted), str(image)], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ("AppRun", "contract.desktop", "contract.svg", "usr/lib/libcontract.so.1"):
            self.assertEqual((extracted / name).read_bytes(), (appdir / name).read_bytes())
        self.assertEqual(TOOL.elf_machine((extracted / "AppRun").read_bytes()), TOOL.elf_machine((appdir / "AppRun").read_bytes()))
        self.assertTrue((extracted / ".DirIcon").is_file())

    def test_unrecognized_aarch64_falls_back_and_rejects_non_elf_decoy(self):
        appdir = self.appdir()
        result, image = self.invoke(appdir, "aarch64", self.runtime)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("More than one architectures", result.stderr)
        self.assertFalse(image.exists())

    def test_arm_aarch64_accepts_arm_input_and_genuine_arm_runtime(self):
        appdir = self.appdir()
        result, image = self.invoke(appdir, "arm_aarch64", self.runtime)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Using architecture aarch64", result.stderr)
        self.assert_image(image, appdir, 183)

    def test_arch_text_does_not_select_the_embedded_runtime(self):
        # Exercise the opposite payload on either native runner. Matching ARCH
        # text must not be mistaken for selecting a matching embedded runtime.
        payload_machine = 183 if self.arch == "x86_64" else 62
        requested_arch = "arm_aarch64" if payload_machine == 183 else "x86_64"
        appdir = self.appdir(payload_machine, decoy=False)
        result, image = self.invoke(appdir, requested_arch)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        label = "aarch64" if payload_machine == 183 else "x86_64"
        self.assertIn("Using architecture " + label, result.stderr)
        self.assertNotEqual(payload_machine, TOOL.PIN["assets"][self.arch]["elf_machine"])
        self.assert_image(image, appdir, TOOL.PIN["assets"][self.arch]["elf_machine"])

    def test_native_host_default_runtime_and_payload_agree(self):
        machine = TOOL.PIN["assets"][self.arch]["elf_machine"]
        appdir = self.appdir(machine, decoy=False)
        result, image = self.invoke(appdir, "x86_64" if self.arch == "x86_64" else "arm_aarch64")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assert_image(image, appdir, machine)


if __name__ == "__main__":
    unittest.main()
