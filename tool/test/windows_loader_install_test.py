#!/usr/bin/env python3
"""Exercise Windows bundle install and plugin compile rules without Flutter/NuGet.

Run from any directory with Python 3, CMake, and a C++ compiler installed:
    python tool/test/windows_loader_install_test.py

XFLCLASH_TEST_CMAKE may point to a specific CMake executable. The fixture copies
the project's actual windows/CMakeLists.txt and supplies small Flutter/plugin
stubs; the install rule under test is never reproduced in this script.

On non-Windows hosts, one fixture sets the directory-local MSVC condition to
exercise the compatibility branch with the host compiler. This checks CMake
scope and compilation, not behavior with an actual old MSVC runtime.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


WINDOWS_CMAKE = Path(__file__).resolve().parents[2] / "windows" / "CMakeLists.txt"
OLD_LOADER = b"OLD_DLL\n"
NEW_LOADER = b"NEW_DLL\n"
MUTEX_COMPAT_DEFINITION = "_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR"


def find_cmake() -> str:
    override = os.environ.get("XFLCLASH_TEST_CMAKE")
    if override:
        executable = shutil.which(override)
        if executable:
            return executable
        raise RuntimeError(f"XFLCLASH_TEST_CMAKE is not executable: {override}")
    executable = shutil.which("cmake")
    if executable:
        return executable
    if os.name == "nt":
        installer_root = os.environ.get("ProgramFiles(x86)")
        if installer_root:
            vswhere = (
                Path(installer_root)
                / "Microsoft Visual Studio"
                / "Installer"
                / "vswhere.exe"
            )
            if vswhere.is_file():
                result = subprocess.run(
                    [
                        str(vswhere),
                        "-latest",
                        "-products",
                        "*",
                        "-find",
                        "Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe",
                    ],
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    check=True,
                    timeout=30,
                )
                for candidate in result.stdout.splitlines():
                    if Path(candidate).is_file():
                        return candidate
    raise RuntimeError("CMake was not found; install it or set XFLCLASH_TEST_CMAKE")


def write_file(path: Path, contents: str | bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if isinstance(contents, bytes):
        path.write_bytes(contents)
    else:
        path.write_text(contents, encoding="utf-8")


class WindowsLoaderInstallTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cmake = find_cmake()
        # The Windows default Visual Studio generator discovers MSVC itself.
        # Choosing Ninja there would require cl.exe in PATH/a Developer Prompt.
        cls.generator = (
            ["-G", "Ninja Multi-Config"]
            if os.name != "nt" and shutil.which("ninja")
            else []
        )

    def run_cmake(self, *arguments: str) -> str:
        command = [self.cmake, *arguments]
        result = subprocess.run(
            command,
            cwd=self.fixture,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=120,
        )
        self.assertEqual(
            result.returncode,
            0,
            f"Command failed: {command!r}\n{result.stdout}\n{result.stderr}",
        )
        return result.stdout

    def create_fixture(
        self, *, msvc: bool | None = None, include_inapp_plugin: bool = True
    ) -> None:
        source = self.fixture / "source with spaces"
        source.mkdir()
        # This is the production file, including its default-prefix branch,
        # all regular install rules, the target guards, and final loader copy.
        shutil.copyfile(WINDOWS_CMAKE, source / "CMakeLists.txt")
        shutil.copyfile(
            WINDOWS_CMAKE.with_name("xboard_sentry_symbols.cmake"),
            source / "xboard_sentry_symbols.cmake",
        )
        write_file(
            source / "flutter" / "CMakeLists.txt",
            """set(FLUTTER_ICU_DATA_FILE "${CMAKE_CURRENT_LIST_DIR}/icudtl.dat" PARENT_SCOPE)
set(FLUTTER_LIBRARY "${CMAKE_CURRENT_LIST_DIR}/flutter_windows.dll" PARENT_SCOPE)
set(PROJECT_BUILD_DIR "${CMAKE_CURRENT_LIST_DIR}/generated/" PARENT_SCOPE)
set(AOT_LIBRARY "${CMAKE_CURRENT_LIST_DIR}/app.so" PARENT_SCOPE)
""",
        )
        write_file(
            source / "runner" / "CMakeLists.txt",
            """add_executable(${BINARY_NAME} main.cpp)
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/runner-dir-$<CONFIG>.txt"
  CONTENT "$<TARGET_FILE_DIR:${BINARY_NAME}>")
""",
        )
        no_compat_definition = f"""#ifdef {MUTEX_COMPAT_DEFINITION}
#error Mutex compatibility definition leaked beyond the InAppWebView plugin
#endif
"""
        write_file(
            source / "runner" / "main.cpp",
            no_compat_definition + "int main() { return 0; }\n",
        )
        # Only override the normal directory variable after project() has
        # identified the real compiler. The compiler ID/toolchain/cache remain
        # unchanged, so both branches can be compiled on Linux and Windows.
        compiler_condition = (
            "" if msvc is None else f"set(MSVC {'TRUE' if msvc else 'FALSE'})\n"
        )
        self.expect_compat_definition = os.name == "nt" if msvc is None else msvc
        plugin_check = (
            f"#ifndef {MUTEX_COMPAT_DEFINITION}\n"
            "#error InAppWebView is missing the old-runtime mutex definition\n"
            if self.expect_compat_definition
            else f"#ifdef {MUTEX_COMPAT_DEFINITION}\n"
            "#error Non-MSVC build received the MSVC mutex definition\n"
        ) + "#endif\n"
        for name in ("plugin.cpp", "texture.cpp"):
            write_file(
                source / "flutter" / name,
                plugin_check + f"int fixture_{Path(name).stem}() {{ return 0; }}\n",
            )
        write_file(
            source / "flutter" / "desktop.cpp",
            no_compat_definition + "int fixture_desktop() { return 0; }\n",
        )
        inapp_plugin = (
            """add_library(flutter_inappwebview_windows_plugin STATIC
  "${CMAKE_CURRENT_LIST_DIR}/plugin.cpp"
  "${CMAKE_CURRENT_LIST_DIR}/texture.cpp")
target_link_libraries(${BINARY_NAME} PRIVATE flutter_inappwebview_windows_plugin)
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/inapp-definitions-$<CONFIG>.txt"
  CONTENT "$<TARGET_PROPERTY:flutter_inappwebview_windows_plugin,COMPILE_DEFINITIONS>")
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/inapp-interface-definitions-$<CONFIG>.txt"
  CONTENT "$<TARGET_PROPERTY:flutter_inappwebview_windows_plugin,INTERFACE_COMPILE_DEFINITIONS>")
"""
            if include_inapp_plugin
            else ""
        )
        write_file(
            source / "flutter" / "generated_plugins.cmake",
            compiler_condition
            + """add_library(Webview2 SHARED IMPORTED GLOBAL)
set_target_properties(Webview2 PROPERTIES
  IMPORTED_LOCATION "${CMAKE_CURRENT_LIST_DIR}/new/WebView2Loader.dll")
add_library(desktop_webview_window_plugin STATIC "${CMAKE_CURRENT_LIST_DIR}/desktop.cpp")
target_link_libraries(${BINARY_NAME} PRIVATE desktop_webview_window_plugin)
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/runner-definitions-$<CONFIG>.txt"
  CONTENT "$<TARGET_PROPERTY:${BINARY_NAME},COMPILE_DEFINITIONS>")
file(GENERATE OUTPUT "${CMAKE_BINARY_DIR}/desktop-definitions-$<CONFIG>.txt"
  CONTENT "$<TARGET_PROPERTY:desktop_webview_window_plugin,COMPILE_DEFINITIONS>")
"""
            + inapp_plugin
            + """
# A regular install rule supplies the older plugin loader before the shared
# loader override, just as the real bundle may already contain an older DLL.
set(PLUGIN_BUNDLED_LIBRARIES
  "${CMAKE_CURRENT_LIST_DIR}/old/WebView2Loader.dll")
""",
        )
        self.new_loader = source / "flutter" / "new" / "WebView2Loader.dll"
        write_file(self.new_loader, NEW_LOADER)
        write_file(source / "flutter" / "old" / "WebView2Loader.dll", OLD_LOADER)
        for relative in (
            "EnableLoopback.exe",
            "flutter/icudtl.dat",
            "flutter/flutter_windows.dll",
            "flutter/app.so",
            "flutter/generated/native_assets/windows/fixture_native.dll",
            "flutter/generated/flutter_assets/fixture_asset.txt",
        ):
            write_file(source / relative, f"fixture: {relative}\n")
        source_time = time.time() - 3600
        os.utime(self.new_loader, (source_time, source_time))
        self.source = source
        self.build = self.fixture / "build with spaces"

    def configure_and_build(
        self, configuration: str, *, explicit_prefix: bool = False
    ) -> Path:
        configure = [
            "-S",
            str(self.source),
            "-B",
            str(self.build),
            *self.generator,
            f"-DCMAKE_BUILD_TYPE={configuration}",
        ]
        custom_prefix = self.fixture / "explicit install with spaces"
        if explicit_prefix:
            configure.append(f"-DCMAKE_INSTALL_PREFIX={custom_prefix}")
        self.run_cmake(*configure)
        self.run_cmake("--build", str(self.build), "--config", configuration)
        return custom_prefix

    def check_compile_definitions(
        self, configuration: str, *, include_inapp_plugin: bool = True
    ) -> None:
        def definitions(target: str) -> list[str]:
            return (
                (self.build / f"{target}-definitions-{configuration}.txt")
                .read_text(encoding="utf-8")
                .split(";")
            )

        self.assertNotIn(MUTEX_COMPAT_DEFINITION, definitions("runner"))
        self.assertNotIn(MUTEX_COMPAT_DEFINITION, definitions("desktop"))
        if include_inapp_plugin:
            self.assertEqual(
                MUTEX_COMPAT_DEFINITION in definitions("inapp"),
                self.expect_compat_definition,
            )
            self.assertNotIn(
                MUTEX_COMPAT_DEFINITION, definitions("inapp-interface")
            )

    def check_install(self, configuration: str, explicit_prefix: bool) -> None:
        with tempfile.TemporaryDirectory(prefix="xflclash-loader-install-") as tmp:
            self.fixture = Path(tmp).resolve()
            self.create_fixture()
            custom_prefix = self.configure_and_build(
                configuration, explicit_prefix=explicit_prefix
            )
            self.check_compile_definitions(configuration)

            target_dir = Path(
                (self.build / f"runner-dir-{configuration}.txt")
                .read_text(encoding="utf-8")
                .strip()
            )
            install_dir = custom_prefix if explicit_prefix else target_dir
            cache = (self.build / "CMakeCache.txt").read_text(encoding="utf-8")
            if not explicit_prefix:
                # Assert that we actually exercised Flutter's unchanged default
                # target-directory prefix, rather than testing a fixed prefix.
                self.assertIn(
                    "CMAKE_INSTALL_PREFIX:PATH=$<TARGET_FILE_DIR:FlClash>", cache
                )

            for attempt in range(2):
                with self.subTest(install_attempt=attempt + 1):
                    installed_loader = install_dir / "WebView2Loader.dll"
                    write_file(installed_loader, OLD_LOADER)
                    destination_time = time.time() + 3600
                    os.utime(installed_loader, (destination_time, destination_time))
                    self.assertGreater(
                        installed_loader.stat().st_mtime,
                        self.new_loader.stat().st_mtime,
                    )
                    stale_asset = install_dir / "data/flutter_assets/stale.txt"
                    write_file(stale_asset, "must be removed on each install")
                    self.run_cmake(
                        "--install", str(self.build), "--config", configuration
                    )
                    self.assertEqual(installed_loader.read_bytes(), NEW_LOADER)
                    self.assertFalse(stale_asset.exists())
                    for relative in (
                        "EnableLoopback.exe",
                        "flutter_windows.dll",
                        "data/icudtl.dat",
                        "fixture_native.dll",
                        "data/flutter_assets/fixture_asset.txt",
                    ):
                        self.assertTrue(
                            (install_dir / relative).is_file(),
                            f"Missing real install output: {relative}",
                        )
                    self.assertEqual(
                        (install_dir / "data/app.so").is_file(),
                        configuration != "Debug",
                    )
                    literal_paths = [
                        path.relative_to(self.fixture)
                        for path in self.fixture.rglob("*")
                        if "$<TARGET_FILE_DIR:" in path.name
                    ]
                    self.assertEqual(literal_paths, [])

    def test_default_prefix_debug(self) -> None:
        self.check_install("Debug", explicit_prefix=False)

    def test_default_prefix_release(self) -> None:
        self.check_install("Release", explicit_prefix=False)

    def test_explicit_prefix_debug(self) -> None:
        self.check_install("Debug", explicit_prefix=True)

    def test_explicit_prefix_release(self) -> None:
        self.check_install("Release", explicit_prefix=True)

    def check_compatibility_branch(
        self, *, msvc: bool, include_inapp_plugin: bool = True
    ) -> None:
        with tempfile.TemporaryDirectory(prefix="xflclash-mutex-compile-") as tmp:
            self.fixture = Path(tmp).resolve()
            self.create_fixture(msvc=msvc, include_inapp_plugin=include_inapp_plugin)
            self.configure_and_build("Release")
            self.check_compile_definitions(
                "Release", include_inapp_plugin=include_inapp_plugin
            )

    def test_msvc_mutex_definition_is_private(self) -> None:
        self.check_compatibility_branch(msvc=True)

    def test_non_msvc_does_not_define_mutex_compatibility(self) -> None:
        self.check_compatibility_branch(msvc=False)

    def test_missing_inapp_plugin_is_supported(self) -> None:
        self.check_compatibility_branch(msvc=True, include_inapp_plugin=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
