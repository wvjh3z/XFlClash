#!/usr/bin/env python3
"""Configure a tiny CMake graph; do not build a Windows client or Rust crate."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[2] / "windows/xboard_sentry_symbols.cmake"


@unittest.skipUnless(shutil.which("cmake") and (os.name == "nt" or shutil.which("c++")),
                     "CMake fixture compiler unavailable")
class RustManifestTests(unittest.TestCase):
    def configure(self, mode="Release", rust=True, outputs=1):
        temporary = tempfile.TemporaryDirectory(prefix="sentry-rust-pdb-")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name).resolve()
        (root / "fixture.cpp").write_text("int main() { return 0; }\n")
        # Exercise the real generator expressions and manifest construction on
        # Linux too. This is a configuration test, not an MSVC compilation claim.
        project = ["cmake_minimum_required(VERSION 3.20)", "project(Fixture CXX)",
                   "if(CMAKE_CONFIGURATION_TYPES)",
                   'set(CMAKE_CONFIGURATION_TYPES "Release;Profile" CACHE STRING "" FORCE)',
                   "endif()",
                   'set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")',
                   'set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")',
                   'set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")',
                   'set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")',
                   f"set(CMAKE_BUILD_TYPE {mode})", "set(MSVC TRUE)",
                   "set(CMAKE_CXX_COMPILER_ID MSVC)", "set(CMAKE_CXX_LINKER_SUPPORTS_PDB TRUE)",
                   "add_executable(FlClash fixture.cpp)",
                   "add_library(flutter_inappwebview_windows_plugin SHARED fixture.cpp)"]
        if rust:
            project.append("add_custom_target(rust_api_cargokit)")
            binaries = [f'"${{CMAKE_BINARY_DIR}}/rust{index}/$<CONFIG>/rust_api.dll"'
                        for index in range(outputs)]
            project.append("set(rust_api_bundled_libraries " + " ".join(binaries) + ")")
        project.append('include("' + HELPER.as_posix() + '")')
        (root / "CMakeLists.txt").write_text("\n".join(project) + "\n")
        result = subprocess.run(["cmake", "-S", str(root), "-B", str(root / "build")],
                                capture_output=True, text=True)
        return root, result

    def test_local_rust_dll_is_paired_with_its_pdb_for_both_configs(self):
        for mode in ("Release", "Profile"):
            with self.subTest(mode=mode):
                root, result = self.configure(mode=mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                rows = (root / f"build/sentry-symbols/{mode}/targets.tsv").read_text().splitlines()
                rust = [row.split("\t") for row in rows if row.startswith("rust_api\t")]
                self.assertEqual(len(rust), 1)
                self.assertEqual(Path(rust[0][1]), root / f"build/rust0/{mode}/rust_api.dll")
                self.assertEqual(Path(rust[0][2]), root / f"build/rust0/{mode}/rust_api.pdb")

    def test_missing_rust_output_is_a_configuration_failure(self):
        _, result = self.configure(outputs=0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires one matching DLL/PDB", result.stderr)

    def test_ambiguous_rust_outputs_are_a_configuration_failure(self):
        _, result = self.configure(outputs=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires one matching DLL/PDB", result.stderr)

    def test_graph_without_rust_has_no_phantom_rust_requirement(self):
        root, result = self.configure(rust=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("rust_api", (root / "build/sentry-symbols/Release/targets.tsv").read_text())


if __name__ == "__main__":
    unittest.main()
