#!/usr/bin/env python3
"""Record the dependency graph used by a completed macOS Xcode build.

`swift package dump-package` evaluates local manifests only. It does not resolve
packages, download dependencies or compile their targets. Remote dependencies
must already exist in Flutter's Xcode SourcePackages/checkouts directory.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import selectors
import shutil
import signal
import subprocess
import sys
import time
from urllib.parse import urlparse

from sentry_macho import MachoError, inspect_macho, is_macho, static_archive_architectures

INVENTORY = "macos/sentry-native-inventory.json"
RECEIPT = "macos/sentry-native-build.json"
SOURCE_LINE_LIMITATION = "host_dsym_only_target_lines_unverified"
LINKER_ONLY_LIMITATION = "comments_only_binary_link_helper_no_target_lines"
MAX_LINK_HELPER_FILES = 64
MAX_LINK_HELPER_FILE_BYTES = 65536
MAX_LINK_HELPER_BYTES = 262144
MANIFEST_REPORT = "macos/sentry-manifest-diagnostics.json"
MANIFEST_STDOUT_LIMIT = 2 * 1024 * 1024
MANIFEST_STDERR_LIMIT = 128 * 1024
MANIFEST_TIMEOUT = 120
SWIFT_COMMAND = ("/usr/bin/xcrun", "--sdk", "macosx", "swift")
MANIFEST_ROLES = frozenset({"generated_root", "direct_local", "direct_remote", "dependency_local", "dependency_remote"})
HOST_ENVIRONMENT_OVERRIDES = frozenset({
    "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "SWIFT_EXEC", "SWIFT_EXEC_MANIFEST",
    "SWIFT_DRIVER_SWIFT_EXEC", "SWIFT_DRIVER_SWIFT_FRONTEND_EXEC", "SWIFTPM_CUSTOM_BIN_DIR",
    "SWIFTPM_CUSTOM_BINDIR", "SWIFTPM_CUSTOM_LIBS_DIR", "SWIFTPM_PD_LIBS",
    "SWIFTPM_MODULECACHE_OVERRIDE", "SWIFTPM_TESTS_MODULECACHE", "SWIFTPM_BUILD_DIR",
    "SWIFT_MODULECACHE_PATH", "CLANG_MODULE_CACHE_PATH", "CC", "CXX", "LD", "LIBTOOL",
    "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH", "LIBRARY_PATH",
    "CFLAGS", "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "LD_LIBRARY_PATH",
})

# Only locally defined codes may leave the Xcode phase. A lowercase-looking
# arbitrary exception is not sufficient evidence that its text is safe.
SAFE_ERROR_CODES = frozenset({
    "ambiguous_macos_package_dependency", "ambiguous_macos_package_product_dependency", "ambiguous_macos_package_runtime",
    "cyclic_macos_package_host_mapping", "duplicate_macos_dependency_ownership", "duplicate_macos_dependency_runtime",
    "invalid_macos_dependency_label", "invalid_macos_dependency_runtime", "invalid_macos_executable_metadata",
    "invalid_macos_package_manifest", "macos_binary_package_artifact_missing", "macos_binary_package_runtime_uuid_mismatch",
    "macos_dependency_inventory_missing_or_mismatched", "macos_dependency_manager_metadata_missing",
    "macos_dependency_runner_missing", "macos_dependency_runtime_escaped_bundle", "macos_dynamic_package_product_missing",
    "macos_flutter_package_link_missing", "macos_inventory_requires_macos_xcode_environment",
    "macos_local_package_manifest_evaluation_failed", "macos_local_package_manifest_evaluation_timeout",
    "macos_local_package_manifest_json_invalid", "macos_local_package_manifest_output_limit",
    "macos_local_package_manifest_tool_unavailable", "macos_local_package_manifest_execution_failed",
    "macos_local_package_manifest_directory_missing", "macos_local_package_manifest_file_missing",
    "macos_manifest_diagnostics_only", "macos_package_identity_path_conflict",
    "invalid_macos_xcframework_metadata", "macos_xcframework_macos_library_missing",
    "macos_xcframework_architecture_missing", "macos_binary_package_payload_invalid",
    "unsafe_macos_xcframework_path", "unsupported_macos_binary_package_container",
    "macos_package_target_missing", "macos_pods_embedding_graph_missing",
    "macos_pods_inventory_missing", "macos_resolved_package_checkout_missing", "macos_resolved_package_state_unavailable",
    "macos_source_package_host_architecture_missing", "macos_xcode_local_package_reference_missing",
    "macos_xcode_project_metadata_unavailable", "macos_xcode_project_metadata_timeout",
    "macos_xcode_runner_link_graph_missing", "unsafe_macos_dependency_inventory_destination",
    "unsafe_macos_vendor_symbol_destination", "unsupported_macos_package_condition", "unsupported_macos_package_dependency",
    "unsupported_macos_package_linkage", "unsupported_macos_package_module_aliases", "unsupported_macos_package_product",
    "unsupported_macos_package_target_dependency", "unsupported_macos_package_traits", "unsupported_macos_pods_embed_graph",
    "unsupported_macos_resolved_package_state", "unsupported_macos_runtime_package_target", "unsupported_macos_xcode_package_reference",
    "unsafe_macos_manifest_report_destination",
})


class InventoryError(RuntimeError):
    pass


class _VerifiedLinkHelper(dict):
    """An in-memory marker; serialized claims alone never waive source gates."""

    def __init__(self, value):
        super().__init__(value)
        self.verified_digest = hashlib.sha256(encoded(value)).digest()


def _verified_link_helper(item):
    return (isinstance(item, _VerifiedLinkHelper)
            and item.verified_digest == hashlib.sha256(encoded(item)).digest())


def required_source_targets(records):
    return [item for item in records if not _verified_link_helper(item)]


def comments_only_source(raw, language):
    """Recognize whitespace/comments, never strip strings or preprocessor text.

    Swift block comments nest. C/C++ comments do not: text after their first
    closing delimiter must be inspected as code. Unknown/unfinished tokens
    remain ordinary source targets, including unterminated comments.
    """
    if (language not in {"swift", "c", "c++"} or len(raw) > MAX_LINK_HELPER_FILE_BYTES
            or any(value > 126 or value < 32 and value not in b"\t\r\n\v\f" for value in raw)
            or language in {"c", "c++"} and (b"\\" in raw or b"??" in raw)):
        return False
    cursor = 0
    while cursor < len(raw):
        if raw[cursor] in b" \t\r\n\v\f":
            cursor += 1
        elif raw[cursor:cursor + 2] == b"//":
            cursor += 2
            while cursor < len(raw) and raw[cursor] not in b"\r\n\v\f":
                cursor += 1
        elif raw[cursor:cursor + 2] == b"/*":
            cursor, depth = cursor + 2, 1
            while cursor < len(raw) and depth:
                token = raw[cursor:cursor + 2]
                if token == b"*/":
                    depth, cursor = depth - 1, cursor + 2
                elif token == b"/*" and language == "swift":
                    depth, cursor = depth + 1, cursor + 2
                else:
                    cursor += 1
            if depth:
                return False
        else:
            return False
    return True


def _helper_relative(value):
    if (not isinstance(value, str) or not value or not re.fullmatch(r"[A-Za-z0-9_.+/-]+", value)
            or Path(value).is_absolute() or any(part in {"", ".", ".."} for part in value.split("/"))):
        raise ValueError()
    return Path(value)


def _helper_sources(package, target_path, declared_sources):
    """Enumerate this target only. Headers, resources and symlinks veto proof."""
    source_root = package / _helper_relative(target_path)
    if (not source_root.is_dir() or source_root.is_symlink()
            or not source_root.resolve().is_relative_to(package.resolve())):
        raise ValueError()
    files, pending, total, entries = [], [source_root], 0, 0
    while pending:
        directory = pending.pop()
        for path in sorted(directory.iterdir()):
            entries += 1
            if entries > 256 or path.is_symlink() or not path.resolve().is_relative_to(package.resolve()):
                raise ValueError()
            if path.is_dir():
                if len(path.relative_to(source_root).parts) > 16:
                    raise ValueError()
                pending.append(path)
                continue
            language = {".swift": "swift", ".c": "c", ".cc": "c++", ".cpp": "c++", ".cxx": "c++"}.get(path.suffix)
            if language is None or not path.is_file() or path.stat().st_size > MAX_LINK_HELPER_FILE_BYTES:
                raise ValueError()
            with path.open("rb") as stream:
                raw = stream.read(MAX_LINK_HELPER_FILE_BYTES + 1)
            total += len(raw)
            if total > MAX_LINK_HELPER_BYTES or len(files) >= MAX_LINK_HELPER_FILES or not comments_only_source(raw, language):
                raise ValueError()
            relative = path.relative_to(package).as_posix()
            _helper_relative(relative)
            files.append(dict(path=relative, language=language, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()))
    if not files:
        raise ValueError()
    if declared_sources is not None:
        if (not isinstance(declared_sources, list) or not declared_sources
                or any(not isinstance(value, str) for value in declared_sources)):
            raise ValueError()
        declared = [(Path(target_path) / _helper_relative(value)).as_posix() for value in declared_sources]
        if len(set(declared)) != len(declared) or set(declared) != {item["path"] for item in files}:
            raise ValueError()
    return sorted(files, key=lambda item: item["path"])


def _helper_linker_settings(settings):
    if not isinstance(settings, list) or len(settings) > 16:
        raise ValueError()
    projected = []
    for item in settings:
        if (not isinstance(item, dict) or set(item) - {"tool", "kind", "condition"}
                or item.get("tool") != "linker" or item.get("condition") is not None
                or not isinstance(item.get("kind"), dict) or len(item["kind"]) != 1):
            raise ValueError()
        kind, value = next(iter(item["kind"].items()))
        if kind not in {"linkedLibrary", "linkedFramework"} or not isinstance(value, dict) or set(value) != {"_0"}:
            raise ValueError()
        projected.append(dict(kind=kind, value=label(value["_0"])))
    return projected


def _helper_target_inputs(target):
    allowed = {"name", "type", "path", "sources", "exclude", "resources", "dependencies", "settings",
               "publicHeadersPath", "pluginUsages", "packageAccess"}
    if (set(target) - allowed or target["type"] != "regular" or target.get("dependencies", []) != []
            or any(target.get(name, []) != [] for name in ("exclude", "resources", "pluginUsages"))
            or target.get("publicHeadersPath") is not None
            or "packageAccess" in target and type(target["packageAccess"]) is not bool):
        raise ValueError()
    target_path = target.get("path")
    if target_path is None:
        target_path = "Sources/" + label(target["name"])
    return target_path, target.get("sources"), _helper_linker_settings(target.get("settings", []))


def _helper_manifest_sha(package):
    manifest = package / "Package.swift"
    if not manifest.is_file() or manifest.is_symlink() or not manifest.resolve().is_relative_to(package.resolve()):
        raise ValueError()
    with manifest.open("rb") as stream:
        raw = stream.read(MANIFEST_STDOUT_LIMIT + 1)
    if len(raw) > MANIFEST_STDOUT_LIMIT:
        raise ValueError()
    return hashlib.sha256(raw).hexdigest()


def _validate_link_helper(item, project, binaries):
    proof = item["linker_only"]
    fields = {"schema_version", "reason", "package_path", "manifest_sha256", "target_path", "declared_sources",
              "sources", "linker_settings", "product", "product_targets", "binary_targets"}
    if (not isinstance(proof, dict) or set(proof) != fields or type(proof["schema_version"]) is not int or proof["schema_version"] != 1
            or proof["reason"] != LINKER_ONLY_LIMITATION):
        raise ValueError()
    package = logical_package_path(project / _helper_relative(proof["package_path"]))
    sources = proof["sources"]
    if (not isinstance(sources, list) or not sources or len(sources) > MAX_LINK_HELPER_FILES
            or any(not isinstance(source, dict) or set(source) != {"path", "language", "bytes", "sha256"}
                   or type(source["bytes"]) is not int for source in sources)):
        raise ValueError()
    if (_helper_manifest_sha(package) != proof["manifest_sha256"]
            or _helper_sources(package, proof["target_path"], proof["declared_sources"]) != proof["sources"]):
        raise ValueError()
    # This remains within the existing build-receipt trust model. The manifest
    # digest binds the selected, evaluated descriptor; it is not a signature
    # against an actor rewriting every build input and both receipt files.
    label(proof["product"])
    targets = proof["product_targets"]
    if (not isinstance(targets, list) or not targets or len(targets) > 64
            or len(set(map(label, targets))) != len(targets) or item["target"] not in targets):
        raise ValueError()
    settings = proof["linker_settings"]
    if not isinstance(settings, list) or len(settings) > 16:
        raise ValueError()
    for setting in settings:
        if (not isinstance(setting, dict) or set(setting) != {"kind", "value"}
                or setting["kind"] not in {"linkedLibrary", "linkedFramework"}):
            raise ValueError()
        label(setting["value"])
    references = proof["binary_targets"]
    if not isinstance(references, list) or not references or len(references) > 64:
        raise ValueError()
    expected = {(binary["package"], binary["target"], host) for binary in binaries for host in binary["hosts"]}
    actual = set()
    for ref in references:
        if not isinstance(ref, dict) or set(ref) != {"package", "target", "host"}:
            raise ValueError()
        identity = tuple(label(ref[key]) for key in ("package", "target", "host"))
        if (identity in actual or identity not in expected or ref["package"] != item["package"]
                or ref["target"] not in targets or ref["host"] not in item["hosts"]):
            raise ValueError()
        actual.add(identity)
    if {ref["host"] for ref in references} != set(item["hosts"]):
        raise ValueError()
    return _VerifiedLinkHelper(item)


def logical_package_path(path, owner=None):
    """Normalize dot segments without following Flutter's package symlinks.

    A plugin's ../FlutterFramework belongs to the generated .packages layout,
    not to the pub-cache directory to which the plugin symlink points.
    Physical paths are resolved independently for validation, never as bases
    for relative manifest dependencies or binary targets.
    """
    path = Path(path)
    if not path.is_absolute() and owner is not None:
        path = Path(owner) / path
    return Path(os.path.abspath(path))


def _xcframework_path(root, value):
    if (not isinstance(value, str) or not value or Path(value).is_absolute()
            or "\\" in value or "\0" in value
            or any(part in {".", ".."} for part in Path(value).parts)):
        raise InventoryError("unsafe_macos_xcframework_path")
    result = root / value
    if not result.resolve().is_relative_to(root.resolve()):
        raise InventoryError("unsafe_macos_xcframework_path")
    return result


def selected_vendor_libraries(root, required_architectures):
    """Read the selected binaryTarget's macOS libraries, never other platforms.

    XCFramework identifiers are opaque. Platform, architecture, payload and
    optional debug directories come from the actual Info.plist, not filenames.
    """
    if root.suffix != ".xcframework":
        if root.is_file():
            return [dict(binary=root, debug_roots=[], architectures=set(required_architectures))]
        raise InventoryError("unsupported_macos_binary_package_container")
    info_path = _xcframework_path(root, "Info.plist")
    try:
        value = plistlib.loads(info_path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise InventoryError("invalid_macos_xcframework_metadata") from None
    if (not isinstance(value, dict) or value.get("CFBundlePackageType") != "XFWK"
            or not isinstance(value.get("AvailableLibraries"), list)):
        raise InventoryError("invalid_macos_xcframework_metadata")
    selected, covered = [], set()
    for item in value["AvailableLibraries"]:
        if not isinstance(item, dict) or not isinstance(item.get("SupportedPlatform"), str):
            raise InventoryError("invalid_macos_xcframework_metadata")
        if item["SupportedPlatform"] != "macos" or item.get("SupportedPlatformVariant"):
            continue
        architectures = item.get("SupportedArchitectures")
        if (not isinstance(architectures, list) or not architectures
                or any(not isinstance(arch, str) for arch in architectures)
                or len(set(architectures)) != len(architectures)):
            raise InventoryError("invalid_macos_xcframework_metadata")
        architectures = {label(arch) for arch in architectures}
        relevant = architectures & required_architectures
        if not relevant:
            continue
        if relevant & covered:
            raise InventoryError("invalid_macos_xcframework_metadata")
        identifier = item.get("LibraryIdentifier")
        if not isinstance(identifier, str) or Path(identifier).name != identifier:
            raise InventoryError("invalid_macos_xcframework_metadata")
        variant = _xcframework_path(root, identifier)
        library = _xcframework_path(variant, item.get("LibraryPath"))
        if not library.exists():
            raise InventoryError("macos_binary_package_artifact_missing")
        if item.get("BinaryPath"):
            binary = _xcframework_path(variant, item["BinaryPath"])
            if ((library.is_file() and binary.resolve() != library.resolve())
                    or (library.is_dir() and not binary.resolve().is_relative_to(library.resolve()))):
                raise InventoryError("unsafe_macos_xcframework_path")
        elif library.is_file():
            binary = library
        elif library.suffix == ".framework":
            infos = [library / "Info.plist", library / "Resources/Info.plist"]
            info = next((path for path in infos if path.is_file()), None)
            if info is None or not info.resolve().is_relative_to(variant.resolve()):
                raise InventoryError("invalid_macos_xcframework_metadata")
            try:
                executable = plistlib.loads(info.read_bytes())["CFBundleExecutable"]
            except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException):
                raise InventoryError("invalid_macos_xcframework_metadata") from None
            if not isinstance(executable, str) or Path(executable).name != executable:
                raise InventoryError("invalid_macos_xcframework_metadata")
            binary = _xcframework_path(library, executable)
        else:
            raise InventoryError("unsupported_macos_binary_package_container")
        if not binary.is_file():
            raise InventoryError("macos_binary_package_artifact_missing")
        debug_roots = []
        if item.get("DebugSymbolsPath"):
            debug = _xcframework_path(variant, item["DebugSymbolsPath"])
            if not debug.is_dir():
                raise InventoryError("macos_binary_package_artifact_missing")
            debug_roots.append(debug)
        selected.append(dict(binary=binary, debug_roots=debug_roots, architectures=architectures))
        covered.update(relevant)
    if not selected:
        raise InventoryError("macos_xcframework_macos_library_missing")
    if not required_architectures <= covered:
        raise InventoryError("macos_xcframework_architecture_missing")
    return selected


def safe_exception_kind(error):
    for kind, name in ((InventoryError, "inventory_error"), (MachoError, "macho_error"),
                       (KeyError, "key_error"), (TypeError, "type_error"),
                       (ValueError, "value_error"), (OSError, "os_error")):
        if isinstance(error, kind):
            return name
    return "unexpected_error"


def manifest_environment(environment=None, *, mode="host"):
    if mode not in {"inherited", "host"}:
        raise ValueError("invalid_manifest_environment_mode")
    # SwiftPM 6.3.3 UserToolchain.swift consumes compiler/library overrides;
    # SwiftSDK.swift consumes SDKROOT. Select this Xcode's host tools/SDK via
    # xcrun instead of inheriting an application's compilation settings.
    # DEVELOPER_DIR and TOOLCHAINS still select the intended Xcode/toolchain.
    # https://github.com/swiftlang/swift-package-manager/blob/swift-6.3.3-RELEASE/Sources/PackageModel/UserToolchain.swift#L327
    # https://github.com/swiftlang/swift-package-manager/blob/swift-6.3.3-RELEASE/Sources/PackageModel/SwiftSDKs/SwiftSDK.swift#L525
    result = {}
    for key, value in (os.environ if environment is None else environment).items():
        upper = key.upper()
        if (upper.startswith(("SENTRY_", "XB_", "DART_DEFINE", "FLUTTER_XCODE_"))
                or any(word in upper for word in ("TOKEN", "PASSWORD", "SECRET", "AES_KEY", "DSN"))):
            continue
        if mode == "host" and (upper in HOST_ENVIRONMENT_OVERRIDES or upper.startswith("DYLD_")):
            continue
        result[key] = value
    result["GIT_TERMINAL_PROMPT"] = "0"
    return result


def manifest_stderr_categories(output):
    # Raw diagnostics may contain paths, source fragments or credentials.
    # Return fixed positive hints only, never matched text or absence claims.
    lower = output.lower()
    patterns = (
        ("sandbox_denied", (b"sandbox-exec:", b"sandbox_apply:", b"sandbox: deny")),
        ("permission_denied", (b"permission denied", b"operation not permitted")),
        ("sdk_unavailable", (b"unable to find sdk", b"sdk not found", b"invalid sdk", b"no such sysroot")),
        ("compiler_sdk_mismatch", (b"compiled with swift", b"sdk is not supported by the compiler", b"this sdk is not supported")),
        ("package_description_missing", (b"no such module 'packagedescription'", b"unable to load standard library")),
        ("tools_version_unsupported", (b"requires minimum swift tools version", b"is using swift tools version")),
        ("module_cache_incompatible", (b"module cache", b"modulecache", b"precompiled module")),
        ("dynamic_library_load_failed", (b"dyld:", b"library not loaded", b"symbol not found")),
        ("filesystem_lock", (b"another instance of swiftpm", b"could not acquire lock", b"resource temporarily unavailable")),
        ("manifest_path_missing", (b"could not find package.swift", b"manifest file not found", b"no package.swift found")),
        ("manifest_invalid", (b"invalid manifest", b"manifest parse error")),
        ("compiler_failed", (b"compile command failed", b"failed to build module", b"compiler command failed")),
        ("manifest_runtime_failed", (b"manifest evaluation failed", b"manifest execution failed")),
    )
    found = [category for category, needles in patterns if any(needle in lower for needle in needles)]
    return found or (["unclassified_diagnostic"] if output else [])


def _stop_manifest_process(process):
    if os.name != "posix":
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
        return
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass


class ManifestDumper:
    """Evaluate only a local manifest; bounded raw bytes never leave memory."""
    def __init__(self, *, environment=None, environment_mode="host", swift=None, timeout=MANIFEST_TIMEOUT):
        self.environment_mode = environment_mode
        self.environment = manifest_environment(environment, mode=environment_mode)
        self.command = [swift] if swift else list(SWIFT_COMMAND)
        self.timeout, self.records = timeout, []

    def dump(self, path, *, role="dependency_local", package_label="unknown"):
        safe_label = package_label if isinstance(package_label, str) and re.fullmatch(r"[A-Za-z0-9_.+-]{1,120}", package_label) else "unknown"
        record = dict(ordinal=len(self.records) + 1, role=role if role in MANIFEST_ROLES else "dependency_local",
                      package=safe_label, status="failed", exit_code=None, timed_out=False,
                      stdout_bytes=0, stderr_bytes=0, output_truncated=False, stderr_categories=[],
                      positive_evidence_only=True)
        self.records.append(record)
        process = None
        stdout, stderr = bytearray(), bytearray()
        try:
            path = logical_package_path(path)
            if not path.is_dir():
                raise InventoryError("macos_local_package_manifest_directory_missing")
            if not (path / "Package.swift").is_file():
                raise InventoryError("macos_local_package_manifest_file_missing")
            try:
                process = subprocess.Popen([*self.command, "package", "--package-path", str(path), "dump-package"],
                    cwd=path, env=self.environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, start_new_session=os.name == "posix")
            except FileNotFoundError as error:
                if not path.is_dir():
                    raise InventoryError("macos_local_package_manifest_directory_missing") from None
                if error.filename == self.command[0]:
                    raise InventoryError("macos_local_package_manifest_tool_unavailable") from None
                raise InventoryError("macos_local_package_manifest_execution_failed") from None
            deadline = time.monotonic() + self.timeout
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ, (stdout, MANIFEST_STDOUT_LIMIT))
                selector.register(process.stderr, selectors.EVENT_READ, (stderr, MANIFEST_STDERR_LIMIT))
                while selector.get_map() or process.poll() is None:
                    if time.monotonic() >= deadline:
                        record["timed_out"] = True
                        raise InventoryError("macos_local_package_manifest_evaluation_timeout")
                    for key, _ in selector.select(min(.1, max(0, deadline - time.monotonic()))):
                        buffer, limit = key.data
                        chunk = os.read(key.fileobj.fileno(), min(65536, limit - len(buffer) + 1))
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        available = limit - len(buffer)
                        buffer.extend(chunk[:available])
                        if len(chunk) > available:
                            record["output_truncated"] = True
                            raise InventoryError("macos_local_package_manifest_output_limit")
            record["exit_code"] = process.poll()
            if record["exit_code"]:
                raise InventoryError("macos_local_package_manifest_evaluation_failed")
            try:
                value = json.loads(stdout)
            except (ValueError, TypeError):
                raise InventoryError("macos_local_package_manifest_json_invalid") from None
            record["status"] = "complete"
            return value
        except InventoryError as error:
            record["reason"] = str(error) if str(error) in SAFE_ERROR_CODES else "macos_dependency_inventory_failed"
            raise
        except (OSError, ValueError):
            record["reason"] = "macos_local_package_manifest_execution_failed"
            raise InventoryError("macos_local_package_manifest_execution_failed") from None
        finally:
            if process is not None:
                _stop_manifest_process(process)
                record["exit_code"] = process.poll()
                process.stdout.close()
                process.stderr.close()
            record.update(stdout_bytes=len(stdout), stderr_bytes=len(stderr),
                          stderr_categories=manifest_stderr_categories(bytes(stderr)))

    def report(self, *, complete=False, error=None):
        result = dict(schema_version=1, kind="macos_manifest_diagnostics", environment_mode=self.environment_mode,
                      status="complete" if complete else "failed", closure_complete=bool(complete),
                      manifest_count=len(self.records), calls=self.records)
        if error:
            result["error"] = error if error in SAFE_ERROR_CODES else "macos_dependency_inventory_failed"
        return result


def write_manifest_report(build_root, report):
    root = build_root.resolve()
    destination = root / MANIFEST_REPORT
    if destination.is_symlink() or not destination.resolve().is_relative_to(root):
        raise InventoryError("unsafe_macos_manifest_report_destination")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def source_line_limitations(source_targets, host_architectures):
    """Scope host-DWARF evidence honestly without guessing package linkage.

    The inventory records selected target-to-host edges. It does not contain
    object/CU/line mappings or prove that a selected target survived dead strip.
    Therefore each edge/actual host slice retains an explicit unverified limit.
    This is not a claim that live source code is missing symbols.
    """
    result = []
    for item in source_targets:
        package, target = label(item["package"]), label(item["target"])
        for host in sorted(item["hosts"]):
            label(host)
            architectures = host_architectures.get(host)
            if not architectures:
                raise InventoryError("macos_source_package_host_architecture_missing")
            for architecture in sorted(architectures):
                if architecture not in {"arm64", "x86_64"}:
                    raise InventoryError("macos_source_package_host_architecture_missing")
                result.append(dict(package=package, target=target, host=host, architecture=architecture,
                                   source="spm", reason=LINKER_ONLY_LIMITATION if _verified_link_helper(item) else SOURCE_LINE_LIMITATION))
    return sorted(result, key=lambda item: (item["package"], item["target"], item["host"], item["architecture"]))


def label(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]+", value):
        raise InventoryError("invalid_macos_dependency_label")
    return value


def encoded(value):
    return (json.dumps(value, sort_keys=True, indent=2) + "\n").encode()


def runtime_modules(build_root: Path, app: Path):
    root, app = build_root.resolve(), app.resolve()
    with (app / "Contents/Info.plist").open("rb") as stream:
        executable = plistlib.load(stream)["CFBundleExecutable"]
    if (not isinstance(executable, str) or not executable or len(executable) > 200
            or executable in {".", ".."} or any(c in executable for c in ("/", "\\", "\0"))):
        raise InventoryError("invalid_macos_executable_metadata")
    runner, seen, targets, result = (app / "Contents/MacOS" / executable).resolve(), set(), set(), []
    for path in sorted(app.rglob("*")):
        if not path.is_file() or path.resolve() in seen or not is_macho(path):
            continue
        actual = path.resolve()
        if not actual.is_relative_to(app) or not actual.is_relative_to(root):
            raise InventoryError("macos_dependency_runtime_escaped_bundle")
        seen.add(actual)
        target = "runner" if actual == runner else label(actual.name)
        if target in targets:
            raise InventoryError("duplicate_macos_dependency_runtime")
        targets.add(target)
        framework = next((part for part in actual.relative_to(app).parts if part.endswith(".framework")), None)
        variants = inspect_macho(actual)["variants"]
        if any(item["architecture"] not in {"x86_64", "arm64"} or not item["uuid"]
               or item["filetype"] not in {2, 6, 8} for item in variants):
            raise InventoryError("invalid_macos_dependency_runtime")
        result.append(dict(target=target, product=framework or ("runner" if actual == runner else label(actual.name)),
                           binary=actual.relative_to(root).as_posix(),
                           variants=sorted([dict(architecture=item["architecture"], uuid=item["uuid"])
                                            for item in variants], key=lambda item: item["architecture"])))
    if "runner" not in targets:
        raise InventoryError("macos_dependency_runner_missing")
    return sorted(result, key=lambda item: item["target"])


def write_inventory(build_root: Path, app: Path, configuration: str, managers, products,
                    source_targets=(), binary_targets=()):
    """Keep a separate receipt so removing/editing an ownership row fails shut."""
    root = build_root.resolve()
    inventory = dict(schema_version=2, dependency_managers=sorted(managers),
                     products=sorted(products, key=lambda item: item["product"]),
                     source_targets=sorted(source_targets, key=lambda item: (item["package"], item["target"])),
                     binary_targets=sorted(binary_targets, key=lambda item: (item["package"], item["target"])))
    raw = encoded(inventory)
    receipt = dict(schema_version=1, configuration=configuration,
                   app=app.resolve().relative_to(root).as_posix(),
                   dependency_managers=inventory["dependency_managers"],
                   inventory_sha256=hashlib.sha256(raw).hexdigest(),
                   runtime=runtime_modules(root, app))
    (root / INVENTORY).parent.mkdir(parents=True, exist_ok=True)
    if any(path.is_symlink() or not path.resolve().is_relative_to(root)
           for path in (root / INVENTORY, root / RECEIPT)):
        raise InventoryError("unsafe_macos_dependency_inventory_destination")
    (root / INVENTORY).write_bytes(raw)
    (root / RECEIPT).write_bytes(encoded(receipt))
    return root / INVENTORY


def load_inventory(build_root: Path, app: Path, configuration="Release"):
    """Shared preparation/upload gate; never fall back to the old Pods file."""
    try:
        root = build_root.resolve()
        inventory_path, receipt_path = root / INVENTORY, root / RECEIPT
        if any(path.is_symlink() or not path.resolve().is_relative_to(root)
               for path in (inventory_path, receipt_path)):
            raise ValueError()
        raw = inventory_path.read_bytes()
        value, receipt = json.loads(raw), json.loads(receipt_path.read_bytes())
        managers = value["dependency_managers"]
        if (value["schema_version"] != 2 or receipt["schema_version"] != 1
                or managers not in (["pods"], ["spm"], ["pods", "spm"])
                or receipt["dependency_managers"] != managers
                or receipt["configuration"] != configuration
                or receipt["inventory_sha256"] != hashlib.sha256(raw).hexdigest()
                or receipt["app"] != app.resolve().relative_to(root).as_posix()
                or receipt["runtime"] != runtime_modules(root, app)):
            raise ValueError()
        records, sources, binaries = value["products"], value["source_targets"], value["binary_targets"]
        if any(not isinstance(items, list) for items in (records, sources, binaries)):
            raise ValueError()
        runtime = {item["product"]: item for item in receipt["runtime"]}
        seen = set()
        for item in records:
            product, target, source = label(item["product"]), label(item["target"]), item["source"]
            if (product in seen or source not in managers or product not in runtime
                    or target != runtime[product]["target"]):
                raise ValueError()
            seen.add(product)
        seen = set()
        runtime_targets = {item["target"] for item in receipt["runtime"]}
        for item in sources + binaries:
            identity = (label(item["package"]), label(item["target"]))
            hosts = item["hosts"]
            if ("spm" not in managers or identity in seen or not isinstance(hosts, list)
                    or not hosts or len(set(hosts)) != len(hosts) or not set(hosts) <= runtime_targets):
                raise ValueError()
            seen.add(identity)
        for item in binaries:
            if (not isinstance(item["dynamic_hosts"], list)
                    or not set(item["dynamic_hosts"]) <= set(item["hosts"])):
                raise ValueError()
        if "spm" in managers and not sources and not binaries:
            raise ValueError()
        sources = [_validate_link_helper(item, root.parent, binaries) if "linker_only" in item else item for item in sources]
        value["source_targets"] = sources
        owned_targets = {item["target"] for item in records} | {"runner", "rust_api", "librust_api.dylib", "rust_api.dylib", "FlClashCore"}
        if any(not set(item["hosts"]) <= owned_targets for item in required_source_targets(sources)):
            raise ValueError()
        return value
    except (OSError, ValueError, TypeError, KeyError, MachoError) as error:
        raise InventoryError("macos_dependency_inventory_missing_or_mismatched") from error


def _aliases(name):
    name = label(name)
    return {name, name.replace("-", "_"), name.replace("_", "-")}


class PackageGraph:
    def __init__(self, root: Path, cache: Path, modules, swift=None, *, dumper=None, manifest_only=False, project_root=None):
        self.root, self.cache = logical_package_path(root), logical_package_path(cache)
        self.modules, self.swift = modules, swift
        self.dumper = dumper or ManifestDumper(swift=swift)
        self.manifest_only = manifest_only
        self.manifest_roles = {self.root: ("generated_root", "FlutterGeneratedPluginSwiftPackage")}
        self.packages, self.visited, self.sources, self.binaries, self.products = {}, set(), {}, {}, {}
        self.vendor_roots, self.vendor_targets, self.identities, self.module_parents = set(), {}, {}, {}
        self.identity_paths = {}
        self.project_root = logical_package_path(project_root) if project_root is not None else None
        self.source_descriptors, self.selected_products, self.binary_package_paths = {}, [], {}
        self.ambiguous_source_descriptors = set()
        self.selected_libraries = {}
        self.stage = "selected_product_graph"
        self.binary_counts = dict(selected_macos_libraries=0, static_archives=0, runtime_images=0, vendor_dsyms_staged=0)

    def report(self, *, complete=False, error=None):
        code = str(error) if isinstance(error, InventoryError) else "macos_dependency_inventory_failed" if error else None
        value = self.dumper.report(complete=complete, error=code)
        value.update(inventory_stage=self.stage, binary_artifacts=dict(self.binary_counts))
        if error:
            value["exception_kind"] = safe_exception_kind(error)
        return value

    def vendor_libraries(self, root, hosts=()):
        if root not in self.selected_libraries:
            architectures = {variant["architecture"] for module in self.modules
                             if not hosts or module["target"] in hosts for variant in module["variants"]}
            if not architectures:
                raise InventoryError("macos_xcframework_architecture_missing")
            self.selected_libraries[root] = selected_vendor_libraries(root, architectures)
            self.binary_counts["selected_macos_libraries"] += len(self.selected_libraries[root])
        return self.selected_libraries[root]

    def workspace_state(self):
        try:
            value = json.loads((self.cache / "workspace-state.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            raise InventoryError("macos_resolved_package_state_unavailable") from None
        if (not isinstance(value, dict) or value.get("version") not in {4, 5, 6, 7}
                or not isinstance(value.get("object"), dict)
                or not all(isinstance(value["object"].get(key), list) for key in ("dependencies", "artifacts"))):
            raise InventoryError("unsupported_macos_resolved_package_state")
        for key in ("dependencies", "artifacts"):
            for item in value["object"][key]:
                if (not isinstance(item, dict) or not isinstance(item.get("packageRef"), dict)
                        or not isinstance(item["packageRef"].get("identity"), str)
                        or (key == "dependencies" and not isinstance(item.get("subpath"), str))
                        or (key == "artifacts" and not all(isinstance(item.get(field), str) for field in ("targetName", "path")))):
                    raise InventoryError("unsupported_macos_resolved_package_state")
        return value["object"]

    def checkout(self, identity, optional=False):
        if optional and not (self.cache / "workspace-state.json").is_file():
            return None
        matches = [item for item in self.workspace_state()["dependencies"]
                   if item["packageRef"]["identity"].lower() == label(identity).lower()]
        if len(matches) != 1 or Path(matches[0]["subpath"]).name != matches[0]["subpath"]:
            if optional and not matches:
                return None
            raise InventoryError("macos_resolved_package_checkout_missing")
        path = self.cache / "checkouts" / label(matches[0]["subpath"])
        reference = matches[0]["packageRef"]
        if reference.get("kind") in {"fileSystem", "local", "root"}:
            location = reference.get("location", reference.get("path"))
            if not isinstance(location, str) or not Path(location).is_absolute():
                raise InventoryError("unsupported_macos_resolved_package_state")
            path = logical_package_path(location)
        elif not path.resolve().is_relative_to(self.cache.resolve()):
            raise InventoryError("macos_resolved_package_checkout_missing")
        if not path.is_dir() or not (path / "Package.swift").is_file():
            if optional:
                return None
            raise InventoryError("macos_resolved_package_checkout_missing")
        path = self.bind_identity(identity, path)
        self.manifest_roles.setdefault(path, ("dependency_remote", label(identity)))
        return path

    def bind_identity(self, identity, path):
        identity, path = label(identity).lower(), logical_package_path(path)
        previous = self.identity_paths.get(identity)
        if previous is not None:
            if previous.resolve() != path.resolve():
                raise InventoryError("macos_package_identity_path_conflict")
            path = previous
        self.identity_paths[identity] = path
        previous_identity = self.identities.get(path)
        if previous_identity is not None and previous_identity != identity:
            raise InventoryError("macos_package_identity_path_conflict")
        self.identities[path] = identity
        return path

    def resolved_local_path(self, identity):
        if not (self.cache / "workspace-state.json").is_file():
            return None
        matches = [item for item in self.workspace_state()["dependencies"]
                   if item["packageRef"]["identity"].lower() == label(identity).lower()]
        if len(matches) > 1:
            raise InventoryError("macos_package_identity_path_conflict")
        if not matches:
            return None
        reference = matches[0]["packageRef"]
        if reference.get("kind") not in {"fileSystem", "local", "root"}:
            return None
        location = reference.get("location", reference.get("path"))
        if not isinstance(location, str) or not Path(location).is_absolute():
            raise InventoryError("unsupported_macos_resolved_package_state")
        return logical_package_path(location)

    def dump(self, path):
        path = logical_package_path(path)
        role, package_label = self.manifest_roles.get(path, ("dependency_local", path.name))
        return self.dumper.dump(path, role=role, package_label=package_label)

    def package(self, path):
        path = logical_package_path(path)
        if path not in self.packages:
            value = self.dump(path)
            if not isinstance(value, dict):
                raise InventoryError("invalid_macos_package_manifest")
            label(value.get("name"))
            if any(not isinstance(value.get(key), list) for key in ("products", "targets", "dependencies")):
                raise InventoryError("invalid_macos_package_manifest")
            if (any(not isinstance(item, dict) or not isinstance(item.get("name"), str)
                    or not isinstance(item.get("type"), dict) or not isinstance(item.get("targets"), list)
                    for item in value["products"])
                    or any(not isinstance(item, dict) or not isinstance(item.get("name"), str)
                           or not isinstance(item.get("type"), str) or not isinstance(item.get("dependencies"), list)
                           for item in value["targets"])):
                raise InventoryError("invalid_macos_package_manifest")
            self.packages[path] = value
        return self.packages[path]

    def dependencies(self, path):
        result = {}
        for entry in self.package(path)["dependencies"]:
            if not isinstance(entry, dict) or len(entry) != 1:
                raise InventoryError("unsupported_macos_package_dependency")
            kind, values = next(iter(entry.items()))
            if (kind not in {"fileSystem", "sourceControl"} or not isinstance(values, list)
                    or len(values) != 1 or not isinstance(values[0], dict)):
                raise InventoryError("unsupported_macos_package_dependency")
            item = values[0]
            if (not isinstance(item.get("identity"), str)
                    or (kind == "fileSystem" and not isinstance(item.get("path"), str))):
                raise InventoryError("unsupported_macos_package_dependency")
            identity = label(item["identity"])
            for alias in {identity, item.get("nameForTargetDependencyResolutionOnly") or identity}:
                descriptor = (kind, item)
                if alias.lower() in result and result[alias.lower()] != descriptor:
                    raise InventoryError("ambiguous_macos_package_dependency")
                result[label(alias).lower()] = descriptor
        if logical_package_path(path) == self.root:
            # Flutter 3.44 declares its real versioned plugin symlinks and
            # FlutterFramework together in this generated root. Register those
            # explicit identities before walking any plugin's dependencies.
            # Do not infer identity from a resolved directory's basename/name.
            for kind, item in {item[1]["identity"].lower(): item for item in result.values()}.values():
                if kind != "fileSystem":
                    continue
                candidate = logical_package_path(item["path"], path)
                selected = self.resolved_local_path(item["identity"])
                if selected is not None and candidate.resolve() != selected.resolve():
                    raise InventoryError("macos_package_identity_path_conflict")
                if (candidate / "Package.swift").is_file():
                    self.bind_identity(item["identity"], candidate)
        return result

    def dependency_path(self, owner, descriptor, optional=False):
        kind, item = descriptor
        identity = label(item["identity"]).lower()
        bound = self.identity_paths.get(identity)
        if bound is not None:
            self.manifest_roles.setdefault(bound, ("dependency_local" if kind == "fileSystem" else "dependency_remote", identity))
            return bound
        if kind == "sourceControl":
            return self.checkout(item["identity"], optional)
        dependency = self.resolved_local_path(identity) or logical_package_path(item["path"], owner)
        if optional and not (dependency / "Package.swift").is_file():
            return None
        path = self.bind_identity(identity, dependency)
        self.manifest_roles.setdefault(path, ("dependency_local", label(item["identity"])))
        return path

    def matching_module(self, names):
        matches = [item for item in self.modules if item["target"] != "runner"
                   and any(item["target"] in _aliases(name)
                           or Path(item["product"]).stem in _aliases(name)
                           or item["product"] in {"lib" + alias + ".dylib" for alias in _aliases(name)}
                           for name in names)]
        if len(matches) > 1:
            raise InventoryError("ambiguous_macos_package_runtime")
        return matches[0] if matches else None

    @staticmethod
    def enabled(condition):
        if condition is None:
            return True
        if not isinstance(condition, dict) or set(condition) - {"platformNames", "config", "traits"}:
            raise InventoryError("unsupported_macos_package_condition")
        if condition.get("traits"):
            raise InventoryError("unsupported_macos_package_traits")
        return (not condition.get("platformNames") or "macos" in condition["platformNames"]) and condition.get("config", "release") == "release"

    def product(self, path, name, host="runner"):
        path = logical_package_path(path)
        value = self.package(path)
        products = [item for item in value["products"] if item["name"] == name]
        if len(products) == 1 and set(products[0]["type"]) in ({"macro"}, {"plugin"}):
            return  # Build-time tools have no runtime image in the app.
        if len(products) != 1 or set(products[0]["type"]) != {"library"}:
            raise InventoryError("unsupported_macos_package_product")
        product = products[0]
        linkage = product["type"]["library"]
        if linkage not in (["automatic"], ["static"], ["dynamic"]):
            raise InventoryError("unsupported_macos_package_linkage")
        # Automatic libraries can be promoted to dynamic by Xcode. The final
        # app, rather than the manifest's default, decides the runtime image.
        module = self.matching_module([name, *product["targets"]]) if linkage != ["static"] else None
        if linkage == ["dynamic"] and module is None and not self.manifest_only:
            raise InventoryError("macos_dynamic_package_product_missing")
        if module:
            self.module_parents.setdefault(module["target"], set()).add(host)
            host = module["target"]
        self.selected_products.append(dict(path=path, product=name, host=host, targets=product["targets"]))
        for target in product["targets"]:
            self.target(path, target, host)
        # A binary-only product is not a source-built module, even if its
        # library product was declared automatic/dynamic.
        if module and any(host in item["hosts"] for item in self.sources.values()):
            self.products[module["product"]] = dict(product=module["product"], target=host, source="spm")

    def target(self, path, name, host):
        path = logical_package_path(path)
        identity = (path, label(name), host)
        if identity in self.visited:
            return
        self.visited.add(identity)
        value = self.package(path)
        targets = [item for item in value["targets"] if item["name"] == name]
        if len(targets) != 1:
            raise InventoryError("macos_package_target_missing")
        target, key = targets[0], (value["name"], name)
        kind = target["type"]
        if kind == "binary":
            if self.manifest_only:
                return  # Selected manifest only; no runtime/artifact claims.
            record = self.binaries.setdefault(key, dict(package=key[0], target=name, hosts=[]))
            self.binary_package_paths.setdefault(key, set()).add(path)
            if target.get("path"):
                location = logical_package_path(target["path"], path)
                if not location.exists():
                    raise InventoryError("macos_binary_package_artifact_missing")
                roots = {location}
            else:
                # Xcode has already downloaded URL binary artifacts here.
                identity = self.identities.get(path, path.name.lower())
                matches = [Path(item["path"]) for item in self.workspace_state()["artifacts"]
                           if item["targetName"] == name and item["packageRef"]["identity"].lower() == identity]
                if not matches:
                    raise InventoryError("macos_binary_package_artifact_missing")
                if any(not item.is_dir() or not item.resolve().is_relative_to(self.cache.resolve()) for item in matches):
                    raise InventoryError("macos_binary_package_artifact_missing")
                roots = set(matches)
            self.vendor_roots.update(roots)
            self.vendor_targets.setdefault(key, set()).update(roots)
            if host not in record["hosts"]:
                record["hosts"].append(host)
            return
        if kind in {"system", "macro", "plugin"}:
            return  # SDK libraries and build-time tools are not app modules.
        if kind != "regular":
            raise InventoryError("unsupported_macos_runtime_package_target")
        record = self.sources.setdefault(key, dict(package=key[0], target=name, hosts=[]))
        descriptor = (path, target)
        if key in self.source_descriptors and self.source_descriptors[key] != descriptor:
            self.ambiguous_source_descriptors.add(key)
        self.source_descriptors.setdefault(key, descriptor)
        if host not in record["hosts"]:
            record["hosts"].append(host)
        dependencies = self.dependencies(path)
        for dependency in target["dependencies"]:
            if not isinstance(dependency, dict) or len(dependency) != 1:
                raise InventoryError("unsupported_macos_package_target_dependency")
            dependency_kind, values = next(iter(dependency.items()))
            expected_size = 4 if dependency_kind == "product" else 2
            # SwiftPM 6.3.3 TargetDescription.Dependency.encode explicitly emits
            # 2 values for target/byName and 4 for product, including nulls.
            # https://github.com/swiftlang/swift-package-manager/blob/swift-6.3.3-RELEASE/Sources/PackageModel/Manifest/TargetDescription.swift#L467
            if (dependency_kind not in {"target", "byName", "product"}
                    or not isinstance(values, list) or len(values) != expected_size):
                raise InventoryError("unsupported_macos_package_target_dependency")
            if not self.enabled(values[-1]):
                continue
            if dependency_kind == "product" and values[2]:
                raise InventoryError("unsupported_macos_package_module_aliases")
            dependency_name = label(values[0])
            if dependency_kind == "target" or (dependency_kind == "byName" and any(
                    item["name"] == dependency_name for item in value["targets"])):
                self.target(path, dependency_name, host)
                continue
            alias = values[1] if dependency_kind == "product" else None
            if alias:
                paths = [self.dependency_path(path, dependencies[label(alias).lower()])]
            else:
                descriptors = {item[1]["identity"]: item for item in dependencies.values()}
                paths = [self.dependency_path(path, item, optional=True) for item in descriptors.values()]
            matches = [candidate for candidate in paths if candidate is not None and any(item["name"] == dependency_name
                       for item in self.package(candidate)["products"])]
            if len(matches) != 1:
                raise InventoryError("ambiguous_macos_package_product_dependency")
            self.product(matches[0], dependency_name, host)

    def collect(self, direct_products=None):
        if self.manifest_only:
            raise InventoryError("macos_manifest_diagnostics_only")
        for path, product in direct_products or [(self.root, "FlutterGeneratedPluginSwiftPackage")]:
            self.product(path, product)
        # Distinguish vendor images by their actual UUID, not just the name of
        # a source wrapper/product surrounding a binaryTarget.
        vendor_modules = set()
        for key, roots in self.vendor_targets.items():
            vendor_ids = set()
            record = self.binaries[key]
            for root in roots:
                self.stage = "vendor_variant_selection"
                for library in self.vendor_libraries(root, record["hosts"]):
                    self.stage = "vendor_container_classification"
                    path = library["binary"]
                    archives = static_archive_architectures(path)
                    if archives is not None:
                        if not library["architectures"] <= archives:
                            raise InventoryError("macos_xcframework_architecture_missing")
                        self.binary_counts["static_archives"] += 1
                        continue
                    if not is_macho(path):
                        raise InventoryError("macos_binary_package_payload_invalid")
                    variants = inspect_macho(path)["variants"]
                    if any(item["filetype"] not in {2, 6, 8} or not item["uuid"] for item in variants):
                        raise InventoryError("macos_binary_package_payload_invalid")
                    self.binary_counts["runtime_images"] += 1
                    for item in variants:
                        vendor_ids.add((item["architecture"], item["uuid"]))
            self.stage = "vendor_runtime_uuid_mapping"
            record["dynamic_hosts"] = [item["target"] for item in self.modules if all(
                (variant["architecture"], variant["uuid"]) in vendor_ids for variant in item["variants"])]
            if vendor_ids and any(item["target"] in _aliases(record["target"])
                                  and item["target"] not in record["dynamic_hosts"] for item in self.modules):
                raise InventoryError("macos_binary_package_runtime_uuid_mismatch")
            if record["dynamic_hosts"]:
                record["hosts"] = list(record["dynamic_hosts"])
                vendor_modules.update(record["dynamic_hosts"])
        for module in self.modules:
            if module["target"] in vendor_modules:
                self.products.pop(module["product"], None)

        def source_hosts(host, seen=()):
            if host not in vendor_modules:
                return {host}
            if host in seen:
                raise InventoryError("cyclic_macos_package_host_mapping")
            return set().union(*(source_hosts(parent, (*seen, host)) for parent in self.module_parents.get(host, {"runner"})
                                 if parent != host))

        self.stage = "source_host_mapping"
        for item in self.sources.values():
            item["hosts"] = sorted(set().union(*(source_hosts(host) for host in item["hosts"])))
        self._record_link_helpers()
        return list(self.products.values()), list(self.sources.values()), list(self.binaries.values())

    def _record_link_helpers(self):
        """A deliberately narrow source proof, never a name/OSO heuristic.

        The helper and binary must be direct members of one selected product.
        More complex indirect wrappers retain the ordinary source obligation.
        All binary payloads have already passed platform/container validation.
        """
        if self.project_root is None:
            return
        for key, item in self.sources.items():
            try:
                if key in self.ambiguous_source_descriptors:
                    continue
                package, target = self.source_descriptors[key]
                target_path, declared_sources, settings = _helper_target_inputs(target)
                package_path = package.relative_to(self.project_root).as_posix()
                _helper_relative(package_path)
                files = _helper_sources(package, target_path, declared_sources)
                products = [product for product in self.selected_products if product["path"] == package
                            and item["target"] in product["targets"] and product["host"] in item["hosts"]]
                for product in products:
                    references = [dict(package=binary["package"], target=binary["target"], host=product["host"])
                                  for binary in self.binaries.values() if binary["package"] == item["package"]
                                  and self.binary_package_paths.get((binary["package"], binary["target"])) == {package}
                                  and binary["target"] in product["targets"] and product["host"] in binary["hosts"]]
                    if not references or {product["host"]} != set(item["hosts"]):
                        continue
                    proof = dict(schema_version=1, reason=LINKER_ONLY_LIMITATION, package_path=package_path,
                                 manifest_sha256=_helper_manifest_sha(package),
                                 target_path=target_path, declared_sources=declared_sources, sources=files,
                                 linker_settings=settings, product=product["product"], product_targets=product["targets"],
                                 binary_targets=sorted(references, key=lambda ref: (ref["package"], ref["target"], ref["host"])))
                    candidate = dict(item, linker_only=proof)
                    self.sources[key] = _validate_link_helper(candidate, self.project_root, list(self.binaries.values()))
                    break
            except (OSError, ValueError, TypeError, KeyError, InventoryError):
                # Missing/unknown source evidence cannot weaken the host gate.
                continue
        for product, record in list(self.products.items()):
            sources = [item for item in self.sources.values() if record["target"] in item["hosts"]]
            if sources and all(_verified_link_helper(item) for item in sources):
                self.products.pop(product)

    def copy_vendor_dsyms(self, destination, build_root):
        """Stage usable vendor companions, including local binaryTarget paths."""
        if destination.is_symlink() or not destination.resolve().is_relative_to(build_root.resolve()):
            raise InventoryError("unsafe_macos_vendor_symbol_destination")
        if destination.exists():
            shutil.rmtree(destination)
        self.stage = "vendor_debug_companions"
        runtime_ids = {(item["architecture"], item["uuid"]) for module in self.modules for item in module["variants"]}
        for root in self.vendor_roots:
            debug_roots = [debug for library in self.vendor_libraries(root) for debug in library["debug_roots"]]
            bundles = [(debug, bundle) for debug in debug_roots for bundle in ([debug] if debug.suffix == ".dSYM" else debug.rglob("*.dSYM"))]
            for debug_root, bundle in bundles:
                if not bundle.resolve().is_relative_to(debug_root.resolve()):
                    raise InventoryError("unsafe_macos_xcframework_path")
                for path in (bundle / "Contents/Resources/DWARF").glob("*"):
                    if not path.resolve().is_relative_to(debug_root.resolve()):
                        raise InventoryError("unsafe_macos_xcframework_path")
                    if not path.is_file() or path.is_symlink() or not is_macho(path):
                        continue
                    try:
                        variants = inspect_macho(path)["variants"]
                    except (MachoError, OSError):
                        continue
                    if not all(item["filetype"] == 10 and item["has_debug_info"]
                               and item["has_debug_line"] and not item["has_executable_text"]
                               and item["architecture"] in {"arm64", "x86_64"} for item in variants):
                        continue
                    if not any((item["architecture"], item["uuid"]) in runtime_ids for item in variants):
                        continue
                    digest = hashlib.sha256(path.read_bytes()).hexdigest()
                    target = destination / (digest + ".dSYM/Contents/Resources/DWARF/vendor")
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(path, target)
                    self.binary_counts["vendor_dsyms_staged"] += 1


class LinkGraph(list):
    def __init__(self, packages=(), pods_filelists=()):
        super().__init__(packages)
        self.pods_filelists = list(pods_filelists)


def linked_packages(project: Path):
    """Read actual Runner link edges, including packages outside Flutter."""
    try:
        result = subprocess.run(["plutil", "-convert", "json", "-o", "-",
                                 str(project / "macos/Runner.xcodeproj/project.pbxproj")],
                                capture_output=True, text=True, encoding="utf-8", timeout=30)
    except subprocess.TimeoutExpired:
        raise InventoryError("macos_xcode_project_metadata_timeout") from None
    if result.returncode:
        raise InventoryError("macos_xcode_project_metadata_unavailable")
    value = json.loads(result.stdout)
    objects = value["objects"]
    runners = [item for item in objects.values() if item.get("isa") == "PBXNativeTarget" and item.get("name") == "Runner"]
    if len(runners) != 1:
        raise InventoryError("macos_xcode_runner_link_graph_missing")
    references = [objects[item] for item in objects[value["rootObject"]].get("packageReferences", [])]
    products, pods_filelists = [], []
    for phase_id in runners[0]["buildPhases"]:
        phase = objects[phase_id]
        if phase["isa"] == "PBXShellScriptBuildPhase" and "Pods-Runner-frameworks.sh" in phase.get("shellScript", ""):
            paths = phase.get("inputFileListPaths", [])
            if len(paths) != 1:
                raise InventoryError("unsupported_macos_pods_embed_graph")
            pods_filelists += paths
        if phase["isa"] != "PBXFrameworksBuildPhase":
            continue
        for file_id in phase["files"]:
            dependency_id = objects[file_id].get("productRef")
            if not dependency_id:
                continue
            dependency = objects[dependency_id]
            name = label(dependency["productName"])
            reference = objects.get(dependency.get("package"))
            if reference is None:
                matches = [item for item in references if item["isa"] == "XCLocalSwiftPackageReference"
                           and Path(item["relativePath"]).name == name]
                if len(matches) != 1:
                    raise InventoryError("macos_xcode_local_package_reference_missing")
                reference = matches[0]
            if reference["isa"] == "XCLocalSwiftPackageReference":
                products.append(("local", logical_package_path(reference["relativePath"], project / "macos"), name))
            elif reference["isa"] == "XCRemoteSwiftPackageReference":
                identity = Path(urlparse(reference["repositoryURL"]).path).name.removesuffix(".git").lower()
                products.append(("remote", label(identity), name))
            else:
                raise InventoryError("unsupported_macos_xcode_package_reference")
    return LinkGraph(products, pods_filelists)


def linked_manifests(graph, linked):
    direct = []
    for kind, path, product in linked:
        actual = path if kind == "local" else graph.checkout(path)
        actual = logical_package_path(actual)
        role = "generated_root" if actual == graph.root else "direct_" + kind
        graph.manifest_roles[actual] = (role, product if kind == "local" else path)
        direct.append((actual, product))
    return direct


def diagnose_manifests(project: Path, build_root: Path, *, environment=None,
                       environment_mode="inherited", swift=None):
    """Visit the actual linked product/target closure without ownership proof.

    This evaluates already available manifests only; it never resolves remote
    dependencies, compiles package targets, or writes an inventory/receipt.
    Dynamic runtime presence and binary artifact inspection belong exclusively
    to the normal inventory path and are not inferred by this diagnostic.
    """
    dumper = ManifestDumper(environment=environment, environment_mode=environment_mode, swift=swift)
    package = project.resolve() / "macos/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage"
    graph = PackageGraph(package, build_root.resolve() / "macos/SourcePackages", [],
                         dumper=dumper, manifest_only=True)
    try:
        linked = linked_packages(project.resolve())
        if not linked:
            raise InventoryError("macos_flutter_package_link_missing")
        for path, product in linked_manifests(graph, linked):
            graph.product(path, product)
        result = dumper.report(complete=True)
    except InventoryError as error:
        result = dumper.report(error=str(error))
    except Exception:
        result = dumper.report(error="macos_dependency_inventory_failed")
    result["selected_target_count"] = len(graph.visited)
    return result


def _collect_inventory(project: Path, build_root: Path, app: Path, configuration="Release", *,
                       pods_root=None, swift=None, diagnostic):
    diagnostic["stage"] = "dependency_manager_metadata"
    plugins = json.loads((project / ".flutter-plugins-dependencies").read_text(encoding="utf-8"))
    enabled = plugins["swift_package_manager_enabled"]["macos"]
    if not isinstance(enabled, bool):
        raise InventoryError("macos_dependency_manager_metadata_missing")
    managers, products, sources, binaries = [], [], [], []
    diagnostic["stage"] = "runtime_inventory"
    modules = runtime_modules(build_root, app)
    diagnostic["stage"] = "xcode_link_graph"
    linked = linked_packages(project)
    if enabled and not any(item[2] == "FlutterGeneratedPluginSwiftPackage" for item in linked):
        raise InventoryError("macos_flutter_package_link_missing")
    # A Linux-generated macos=false cannot suppress packages that Runner
    # actually links. An already linked empty placeholder is also recorded.
    if linked:
        managers.append("spm")
        package = project / "macos/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage"
        graph = PackageGraph(package, build_root / "macos/SourcePackages", modules, swift, project_root=project)
        diagnostic.update(stage="package_graph", graph=graph)
        direct = linked_manifests(graph, linked)
        spm_products, sources, binaries = graph.collect(direct)
        graph.copy_vendor_dsyms(build_root / "macos/sentry-prebuilt-dsyms", build_root)
        products += spm_products
    # This is the configuration-specific input list used by Xcode's actual
    # [CP] Embed Pods Frameworks phase. Stale post_install rows absent from
    # the current link/embed graph must not become required products.
    diagnostic["stage"] = "pods_ownership"
    embedded, vendored = set(), set()
    for value in linked.pods_filelists:
        if not pods_root:
            raise InventoryError("macos_pods_embedding_graph_missing")
        for key, replacement in {"PODS_ROOT": str(pods_root), "CONFIGURATION": configuration}.items():
            value = value.replace("${" + key + "}", replacement).replace("$(" + key + ")", replacement)
        filelist = Path(value)
        if "$" in value or not filelist.is_file():
            raise InventoryError("macos_pods_embedding_graph_missing")
        for line in filelist.read_text(encoding="utf-8").splitlines():
            line = line.strip().strip('"')
            if line.endswith((".framework", ".dylib")):
                product = label(Path(line).name)
                embedded.add(product)
                if "${PODS_ROOT}" in line or "${PODS_XCFRAMEWORKS_BUILD_DIR}" in line:
                    vendored.add(product)
    distributed = {item["product"]: item for item in modules}
    if embedded & distributed.keys() or not linked:
        managers.append("pods")
        pods_path = build_root / "macos/sentry-native-owned.json"
        pods = json.loads(pods_path.read_text(encoding="utf-8")) if pods_path.is_file() else {"schema_version": 1, "products": []}
        if pods.get("schema_version") != 1 or not isinstance(pods.get("products"), list):
            raise InventoryError("macos_pods_inventory_missing")
        spm_owned = {item["product"] for item in products}
        spm_prebuilt = {module["product"] for module in modules if any(
            module["target"] in item["dynamic_hosts"] for item in binaries)}
        for item in pods["products"]:
            product = label(item["product"])
            if (product in distributed and product in embedded
                    and product not in spm_owned | spm_prebuilt | vendored):
                products.append(dict(product=product, target=distributed[product]["target"], source="pods"))
        known = {item["product"] for item in products} | vendored | {"FlutterMacOS.framework", "rust_api.framework", "librust_api.dylib", "rust_api.dylib"}
        known |= spm_prebuilt
        if (embedded & distributed.keys()) - known or (not linked and not pods_path.is_file()):
            raise InventoryError("macos_pods_inventory_missing")
    if len({item["product"] for item in products}) != len(products):
        raise InventoryError("duplicate_macos_dependency_ownership")
    diagnostic["stage"] = "inventory_receipt"
    return write_inventory(build_root, app, configuration, managers, products, sources, binaries)


def collect_inventory(project: Path, build_root: Path, app: Path, configuration="Release", *,
                      pods_root=None, swift=None):
    diagnostic = {"stage": "dependency_manager_metadata"}
    failure = None
    try:
        return _collect_inventory(project, build_root, app, configuration, pods_root=pods_root,
                                  swift=swift, diagnostic=diagnostic)
    except Exception as error:
        failure = error
        if isinstance(error, MachoError):
            code = "macos_binary_package_payload_invalid" if diagnostic["stage"] == "package_graph" else "invalid_macos_dependency_runtime"
            raise InventoryError(code) from None
        raise
    finally:
        graph = diagnostic.get("graph")
        if graph is not None:
            report = graph.report(complete=failure is None, error=failure)
        else:
            report = ManifestDumper(swift=swift).report(complete=failure is None,
                error=str(failure) if isinstance(failure, InventoryError) else "macos_dependency_inventory_failed" if failure else None)
            report["exception_kind"] = safe_exception_kind(failure) if failure else "none"
        report["inventory_stage"] = graph.stage if graph is not None and diagnostic["stage"] == "package_graph" else diagnostic["stage"]
        write_manifest_report(build_root, report)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcode-build", action="store_true", required=True)
    parser.parse_args(argv)
    try:
        if os.environ.get("CONFIGURATION") not in {"Release", "Profile"}:
            return 0
        if sys.platform != "darwin" or os.environ.get("PLATFORM_NAME") != "macosx":
            raise InventoryError("macos_inventory_requires_macos_xcode_environment")
        project = Path(os.environ["PROJECT_DIR"]).resolve().parent
        build = Path(os.environ["FLUTTER_BUILD_DIR"])
        if not build.is_absolute():
            build = project / build
        app = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["FULL_PRODUCT_NAME"]
        collect_inventory(project, build.resolve(), app, os.environ["CONFIGURATION"],
                          pods_root=os.environ.get("PODS_ROOT"))
        print("macos_dependency_inventory_recorded")
        return 0
    except InventoryError as error:
        code = str(error)
        print(code if code in SAFE_ERROR_CODES else "macos_dependency_inventory_failed", file=sys.stderr)
        return 1
    except Exception:
        # Manifest evaluations can include private source/cache paths. Never
        # relay command output, exception bodies or package URLs to CI logs.
        print("macos_dependency_inventory_failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
