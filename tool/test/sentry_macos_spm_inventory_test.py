#!/usr/bin/env python3
"""Offline Pods/SPM graph, receipt and dSYM regressions; no app builds."""

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import uuid

TOOL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOL))
sys.path.insert(0, str(TOOL / "test"))
import sentry_macos_inventory as inventory
import sentry_macos_generation_test as generation
from sentry_macos_symbols_test import macho, universal
from sentry_macho import MachoError, static_archive_architectures, is_macho


def package(name, products, targets, dependencies=()):
    return dict(name=name, products=products, targets=targets, dependencies=list(dependencies))


def library(name, targets, linkage="automatic"):
    return dict(name=name, type={"library": [linkage]}, targets=targets)


def target(name, dependencies=(), kind="regular", **extra):
    return dict(name=name, type=kind, dependencies=list(dependencies), **extra)


def static_archive(payload):
    header = (b"member.o/".ljust(16) + b"0".ljust(12) + b"0".ljust(6) + b"0".ljust(6)
              + b"644".ljust(8) + str(len(payload)).encode().ljust(10) + b"`\n")
    return b"!<arch>\n" + header + payload + (b"\n" if len(payload) & 1 else b"")


class SpmInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sentry-spm-graph-")
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name).resolve()
        self.build = self.project / "build"
        self.app = self.build / "macos/Build/Products/Release/Fixture.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Fixture"}))
        (self.app / "Contents/MacOS/Fixture").write_bytes(macho(str(uuid.uuid4())))
        self.add_module("example")
        self.vendor = self.add_module("VendorBinary")
        self.root = self.project / "macos/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage"
        self.source = self.project / "local-source"
        self.binary = self.project / "local-binary"
        self.cache = self.build / "macos/SourcePackages"
        self.launch = self.cache / "checkouts/LaunchAtLogin"
        self.write_package(self.root, package("FlutterGeneratedPluginSwiftPackage", [
            library("FlutterGeneratedPluginSwiftPackage", ["FlutterGeneratedPluginSwiftPackage"], "static")], [
                target("FlutterGeneratedPluginSwiftPackage", [
                    {"product": ["Example", "source", None, None]},
                    {"product": ["Static", "source", None, None]},
                    {"product": ["VendorProduct", "vendor", None, None]},
                ])], [self.local_dependency("source", self.source), self.local_dependency("vendor", self.binary)]))
        self.write_package(self.source, package("Source", [library("Example", ["example"], "dynamic"),
                                                          library("Static", ["StaticPart"], "static")], [
            target("example", [{"target": ["DynamicChild", None]}]), target("DynamicChild"), target("StaticPart"),
        ]))
        self.vendor_root = self.binary / "VendorBinary.xcframework"
        self.vendor_library = self.make_xcframework(self.vendor_root, self.vendor)
        self.write_package(self.binary, package("Vendor", [library("VendorProduct", ["VendorBinary"])], [
            target("VendorBinary", kind="binary", path="VendorBinary.xcframework")]))
        self.write_package(self.launch, package("LaunchAtLogin", [library("LaunchAtLogin", ["LaunchAtLogin"])], [target("LaunchAtLogin")]))
        self.state = {"version": 6, "object": {"dependencies": [
            {"packageRef": {"identity": "launchatlogin"}, "subpath": "LaunchAtLogin"}], "artifacts": []}}
        self.save_state()
        self.pods = self.project / "macos/Pods"
        self.cp = self.pods / "Target Support Files/Pods-Runner/Pods-Runner-frameworks-Release-input-files.xcfilelist"
        self.cp.parent.mkdir(parents=True)
        self.cp.write_text("")
        self.pod_owned = self.build / "macos/sentry-native-owned.json"
        self.pod_owned.write_text(json.dumps({"schema_version": 1, "products": []}))
        self.metadata = self.project / ".flutter-plugins-dependencies"
        self.metadata.write_text(json.dumps({"swift_package_manager_enabled": {"macos": True}}))
        self.links = [("local", self.root, "FlutterGeneratedPluginSwiftPackage"),
                      ("remote", "launchatlogin", "LaunchAtLogin")]

    def save_state(self):
        (self.cache / "workspace-state.json").write_text(json.dumps(self.state))

    @staticmethod
    def make_xcframework(root, binary, *, debug=False):
        variant = root / "selected-by-metadata"
        variant.mkdir(parents=True)
        library = variant / "VendorBinary"
        shutil.copyfile(binary, library)
        item = dict(LibraryIdentifier=variant.name, LibraryPath=library.name, BinaryPath=library.name,
                    SupportedPlatform="macos", SupportedArchitectures=["x86_64"])
        if debug:
            item["DebugSymbolsPath"] = "dSYMs"
            (variant / "dSYMs").mkdir()
        (root / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundlePackageType="XFWK", XCFrameworkFormatVersion="1.0", AvailableLibraries=[item])))
        return library

    @staticmethod
    def local_dependency(name, path):
        return {"fileSystem": [{"identity": name, "nameForTargetDependencyResolutionOnly": name, "path": str(path)}]}

    def write_package(self, path, value):
        path.mkdir(parents=True, exist_ok=True)
        (path / "Package.swift").write_text("// Offline evaluated-manifest fixture; never compiled.\n")
        (path / "dump.json").write_text(json.dumps(value))

    def add_module(self, name):
        path = self.app / "Contents/Frameworks" / (name + ".framework") / name
        path.parent.mkdir(parents=True)
        path.write_bytes(macho(str(uuid.uuid4()), filetype=6))
        return path

    def collect(self):
        with mock.patch.object(inventory, "linked_packages", return_value=inventory.LinkGraph(self.links, [str(self.cp)])), \
             mock.patch.object(inventory.PackageGraph, "dump", side_effect=lambda path: json.loads((path / "dump.json").read_text())):
            inventory.collect_inventory(self.project, self.build, self.app, pods_root=self.pods)
        return inventory.load_inventory(self.build, self.app)

    def test_spm_source_dynamic_static_direct_package_and_binary_are_distinct(self):
        result = self.collect()
        self.assertEqual(result["dependency_managers"], ["spm"])
        self.assertEqual(result["products"], [{"product": "example.framework", "target": "example", "source": "spm"}])
        hosts = {item["target"]: item["hosts"] for item in result["source_targets"]}
        self.assertEqual(hosts["example"], ["example"])
        self.assertEqual(hosts["DynamicChild"], ["example"])
        self.assertEqual(hosts["StaticPart"], ["runner"])
        self.assertEqual(hosts["LaunchAtLogin"], ["runner"])
        self.assertEqual(result["binary_targets"], [{"package": "Vendor", "target": "VendorBinary",
                                                    "hosts": ["VendorBinary"], "dynamic_hosts": ["VendorBinary"]}])

    def test_linux_generated_false_does_not_suppress_actual_xcode_package_edges(self):
        self.metadata.write_text(json.dumps({"swift_package_manager_enabled": {"macos": False}}))
        self.assertEqual(self.collect()["dependency_managers"], ["spm"])

    def test_stale_pods_rows_do_not_require_frameworks_after_spm_static_linkage(self):
        self.pod_owned.write_text(json.dumps({"schema_version": 1, "products": [
            {"target": "StaticPart", "product": "StaticPart.framework"},
            {"target": "example", "product": "example.framework"}]}))
        self.assertEqual(self.collect()["dependency_managers"], ["spm"])

    def test_pure_spm_does_not_require_a_legacy_pods_file(self):
        self.pod_owned.unlink()
        self.assertEqual(self.collect()["dependency_managers"], ["spm"])

    def test_static_binary_target_is_recorded_as_vendor_inside_host(self):
        shutil.rmtree(self.vendor.parent)
        self.vendor_library.write_bytes(static_archive(macho(str(uuid.uuid4()), filetype=1)))
        # A non-Mac dynamic slice with a matching runtime UUID must not turn
        # the selected macOS static package into a dynamic vendor host.
        other = self.vendor_root / "macos-looking-but-ios"
        other.mkdir()
        runner_id = inventory.inspect_macho(self.app / "Contents/MacOS/Fixture")["variants"][0]["uuid"]
        (other / "VendorBinary").write_bytes(macho(runner_id, filetype=6))
        info = plistlib.loads((self.vendor_root / "Info.plist").read_bytes())
        info["AvailableLibraries"].append(dict(LibraryIdentifier=other.name, LibraryPath="VendorBinary",
            SupportedPlatform="ios", SupportedArchitectures=["x86_64"], SupportedPlatformVariant="simulator"))
        (self.vendor_root / "Info.plist").write_bytes(plistlib.dumps(info))
        result = self.collect()
        self.assertEqual(result["binary_targets"], [{"package": "Vendor", "target": "VendorBinary",
                                                    "hosts": ["runner"], "dynamic_hosts": []}])

    def test_automatic_source_library_promoted_to_dynamic_uses_final_image(self):
        path = self.source / "dump.json"
        value = json.loads(path.read_text())
        value["products"][0]["type"] = {"library": ["automatic"]}
        path.write_text(json.dumps(value))
        result = self.collect()
        self.assertEqual(result["products"][0]["target"], "example")

    def test_mixed_build_uses_actual_cp_embedded_source_product(self):
        self.add_module("PodPlugin")
        self.cp.write_text('${BUILT_PRODUCTS_DIR}/PodPlugin/PodPlugin.framework\n')
        self.pod_owned.write_text(json.dumps({"schema_version": 1, "products": [
            {"target": "PodPlugin", "product": "PodPlugin.framework"},
            {"target": "stale", "product": "stale.framework"}]}))
        result = self.collect()
        self.assertEqual(result["dependency_managers"], ["pods", "spm"])
        self.assertEqual({item["source"] for item in result["products"]}, {"pods", "spm"})

    def test_missing_inventory_for_actual_source_pod_fails(self):
        self.add_module("PodPlugin")
        self.cp.write_text('${BUILT_PRODUCTS_DIR}/PodPlugin/PodPlugin.framework\n')
        self.pod_owned.unlink()
        with self.assertRaisesRegex(inventory.InventoryError, "macos_pods_inventory_missing"):
            self.collect()

    def test_pods_prebuilt_framework_is_not_source_coverage(self):
        self.add_module("PodVendor")
        self.cp.write_text('${PODS_XCFRAMEWORKS_BUILD_DIR}/PodVendor/PodVendor.framework\n')
        self.pod_owned.unlink()
        result = self.collect()
        self.assertEqual(result["dependency_managers"], ["pods", "spm"])
        self.assertNotIn("PodVendor.framework", {item["product"] for item in result["products"]})

    def test_linked_empty_placeholder_can_coexist_with_pods(self):
        self.links = self.links[:1]
        self.write_package(self.root, package("FlutterGeneratedPluginSwiftPackage", [
            library("FlutterGeneratedPluginSwiftPackage", ["FlutterGeneratedPluginSwiftPackage"], "static")], [target("FlutterGeneratedPluginSwiftPackage")]))
        self.metadata.write_text(json.dumps({"swift_package_manager_enabled": {"macos": False}}))
        self.cp.write_text('${BUILT_PRODUCTS_DIR}/example/example.framework\n')
        self.pod_owned.write_text(json.dumps({"schema_version": 1, "products": [
            {"target": "example", "product": "example.framework"}]}))
        result = self.collect()
        self.assertEqual(result["dependency_managers"], ["pods", "spm"])
        self.assertEqual(result["products"][0]["source"], "pods")

    def test_legacy_pods_only_path_stays_supported(self):
        self.links = []
        self.metadata.write_text(json.dumps({"swift_package_manager_enabled": {"macos": False}}))
        self.cp.write_text('${BUILT_PRODUCTS_DIR}/example/example.framework\n')
        self.pod_owned.write_text(json.dumps({"schema_version": 1, "products": [
            {"target": "example", "product": "example.framework"}]}))
        result = self.collect()
        self.assertEqual(result["dependency_managers"], ["pods"])
        self.assertEqual(result["products"], [{"product": "example.framework", "target": "example", "source": "pods"}])

    def test_missing_actual_cp_embed_inputs_cannot_downgrade_to_prebuilt(self):
        self.cp.unlink()
        with self.assertRaisesRegex(inventory.InventoryError, "embedding_graph_missing"):
            self.collect()

    def test_source_dynamic_product_missing_fails_before_receipt(self):
        shutil.rmtree(self.vendor.parents[1] / "example.framework")
        with self.assertRaisesRegex(inventory.InventoryError, "macos_dynamic_package_product_missing"):
            self.collect()

    def test_deleted_inventory_or_receipt_cannot_fall_back_to_pods(self):
        for filename in (inventory.INVENTORY, inventory.RECEIPT):
            self.collect()
            (self.build / filename).unlink()
            with self.assertRaisesRegex(inventory.InventoryError, "missing_or_mismatched"):
                inventory.load_inventory(self.build, self.app)

    def test_deleting_owned_product_or_changing_manager_breaks_receipt(self):
        for mutate in (lambda value: value["products"].clear(),
                       lambda value: value.update(dependency_managers=["pods"])):
            self.collect()
            path = self.build / inventory.INVENTORY
            value = json.loads(path.read_text())
            mutate(value)
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(inventory.InventoryError, "missing_or_mismatched"):
                inventory.load_inventory(self.build, self.app)

    def test_final_runtime_uuid_change_invalidates_receipt(self):
        self.collect()
        self.vendor.write_bytes(macho(str(uuid.uuid4()), filetype=6))
        with self.assertRaisesRegex(inventory.InventoryError, "missing_or_mismatched"):
            inventory.load_inventory(self.build, self.app)

    def test_remote_checkout_uses_resolved_subpath_and_never_resolves(self):
        self.state["object"]["dependencies"][0]["subpath"] = "missing-checkout"
        self.save_state()
        with self.assertRaisesRegex(inventory.InventoryError, "checkout_missing"):
            self.collect()

    def test_remote_identity_is_not_inferred_from_checkout_basename(self):
        renamed = self.cache / "checkouts/checkout-with-another-basename"
        self.launch.rename(renamed)
        self.state["object"]["dependencies"][0]["subpath"] = renamed.name
        self.save_state()
        graph = inventory.PackageGraph(self.root, self.cache, [])
        self.assertEqual(graph.checkout("launchatlogin"), renamed)
        self.assertEqual(graph.identities[renamed], "launchatlogin")
        self.assertEqual(self.collect()["source_targets"][-1]["package"], "Source")

    @unittest.skipIf(os.name == "nt", "Real Flutter symlink layout fixture requires POSIX")
    def test_flutter_symlink_layout_preserves_identity_and_relative_binary_paths(self):
        packages = self.root.parent / ".packages"
        packages.mkdir()
        real_plugin = self.project / "pub-cache/plugin-0.3.2/macos/plugin"
        real_framework = self.project / "sdk-cache/framework-with-another-basename"
        plugin, framework = packages / "plugin-0.3.2", packages / "FlutterFramework"
        self.write_package(real_framework, package("FlutterFramework", [library("FlutterFramework", ["VendorBinary"])],
            [target("VendorBinary", kind="binary", path="Binaries/VendorBinary.xcframework")]))
        artifact = real_framework / "Binaries/VendorBinary.xcframework"
        self.make_xcframework(artifact, self.vendor)
        self.write_package(real_plugin, package("Plugin", [library("Plugin", ["Plugin"])],
            [target("Plugin", [{"product": ["FlutterFramework", "FlutterFramework", None, None]}])],
            [self.local_dependency("flutterframework", Path("../FlutterFramework"))]))
        plugin.symlink_to(real_plugin, target_is_directory=True)
        framework.symlink_to(real_framework, target_is_directory=True)
        # Keep the logical symlink in the actual process argument/cwd too,
        # independently of the graph's in-memory path keys.
        dumper = inventory.ManifestDumper(swift="fixture-swift")
        with mock.patch.object(inventory.subprocess, "Popen",
                side_effect=FileNotFoundError(2, "fixture", "fixture-swift")) as launch, \
             self.assertRaisesRegex(inventory.InventoryError, "manifest_tool_unavailable"):
            dumper.dump(plugin)
        self.assertEqual(launch.call_args.args[0][-2:], [str(plugin), "dump-package"])
        self.assertEqual(launch.call_args.kwargs["cwd"], plugin)
        self.write_package(self.root, package("FlutterGeneratedPluginSwiftPackage", [
            library("FlutterGeneratedPluginSwiftPackage", ["FlutterGeneratedPluginSwiftPackage"], "static")],
            [target("FlutterGeneratedPluginSwiftPackage", [{"product": ["Plugin", "plugin", None, None]},
                {"product": ["FlutterFramework", "flutterframework", None, None]}])],
            [{"fileSystem": [{"identity": "plugin-0.3.2", "nameForTargetDependencyResolutionOnly": "plugin", "path": str(plugin)}]},
             self.local_dependency("flutterframework", framework)]))
        self.assertFalse((real_plugin.parent / "FlutterFramework").exists())
        for child_path in ("../FlutterFramework", str(real_plugin.parent / "FlutterFramework")):
            with self.subTest(child_path_kind="relative" if child_path.startswith("..") else "physical_absolute"):
                value = json.loads((real_plugin / "dump.json").read_text())
                value["dependencies"][0]["fileSystem"][0]["path"] = child_path
                (real_plugin / "dump.json").write_text(json.dumps(value))
                graph = inventory.PackageGraph(self.root, self.cache, inventory.runtime_modules(self.build, self.app))
                seen = []
                def dump(path):
                    seen.append(path)
                    return json.loads((path / "dump.json").read_text())
                with mock.patch.object(graph, "dump", side_effect=dump):
                    _, sources, binaries = graph.collect()
                self.assertEqual(seen, [self.root, plugin, framework])
                self.assertEqual(graph.identity_paths["flutterframework"], framework)
                self.assertEqual(graph.identities[plugin], "plugin-0.3.2")
                self.assertEqual(graph.vendor_roots, {framework / "Binaries/VendorBinary.xcframework"})
                self.assertEqual(binaries[0]["dynamic_hosts"], ["VendorBinary"])
                self.assertTrue(any(item["target"] == "Plugin" for item in sources))

    def test_explicit_resolved_local_identity_wins_missing_literal_but_conflicts_fail(self):
        graph = inventory.PackageGraph(self.root, self.cache, [])
        self.state["object"]["dependencies"].append({"packageRef": {"identity": "source", "kind": "fileSystem",
            "location": str(self.source)}, "subpath": "identity-not-a-directory-basename"})
        self.save_state()
        missing = self.local_dependency("source", self.project / "nonexistent-literal")["fileSystem"][0]
        self.assertEqual(graph.dependency_path(self.root, ("fileSystem", missing)), self.source)
        other = self.project / "different-source"
        self.write_package(other, package("Other", [], []))
        self.state["object"]["dependencies"][-1]["packageRef"]["location"] = str(other)
        self.save_state()
        with self.assertRaisesRegex(inventory.InventoryError, "identity_path_conflict"):
            self.collect()

    def test_missing_manifest_path_is_distinct_from_actual_tool_or_execution_failure(self):
        dumper = inventory.ManifestDumper(swift="fixture-swift")
        with mock.patch.object(inventory.subprocess, "Popen") as launch:
            for path, code in ((self.project / "absent", "directory_missing"),
                               (self.project, "file_missing")):
                with self.assertRaisesRegex(inventory.InventoryError, "manifest_" + code):
                    dumper.dump(path)
            launch.assert_not_called()
        for failure, code in ((FileNotFoundError(2, "private-path", "fixture-swift"), "tool_unavailable"),
                              (PermissionError("private-path"), "execution_failed")):
            with mock.patch.object(inventory.subprocess, "Popen", side_effect=failure), \
                 self.assertRaisesRegex(inventory.InventoryError, "manifest_" + code):
                dumper.dump(self.root)
        self.assertNotIn("private", json.dumps(dumper.report()))

    def test_unselected_remote_dependency_needs_no_cached_checkout(self):
        value = json.loads((self.source / "dump.json").read_text())
        value["dependencies"].append({"sourceControl": [{"identity": "unused-remote"}]})
        (self.source / "dump.json").write_text(json.dumps(value))
        self.assertEqual(self.collect()["products"][0]["target"], "example")

    def test_binary_artifact_identity_must_match_the_selected_package(self):
        value = json.loads((self.binary / "dump.json").read_text())
        value["targets"][0].pop("path")
        value["targets"][0]["url"] = "https://example.invalid/fixture.zip"
        (self.binary / "dump.json").write_text(json.dumps(value))
        artifact = self.cache / "artifacts/vendor/VendorBinary/VendorBinary.xcframework"
        shutil.copytree(self.vendor_root, artifact)
        entry = {"targetName": "VendorBinary", "packageRef": {"identity": "unrelated-package"}, "path": str(artifact)}
        self.state["object"]["artifacts"] = [entry]
        self.save_state()
        with self.assertRaisesRegex(inventory.InventoryError, "artifact_missing"):
            self.collect()
        self.state["object"]["artifacts"].append({**entry, "packageRef": {"identity": "vendor"}})
        self.save_state()
        self.assertEqual(self.collect()["binary_targets"][0]["dynamic_hosts"], ["VendorBinary"])

    def test_source_wrapper_keeps_dynamic_binary_target_outside_static_host(self):
        value = json.loads((self.binary / "dump.json").read_text())
        value["products"][0]["targets"] = ["Wrapper"]
        value["targets"].append(target("Wrapper", [{"target": ["VendorBinary", None]}]))
        (self.binary / "dump.json").write_text(json.dumps(value))
        result = self.collect()
        self.assertEqual(result["binary_targets"][0]["dynamic_hosts"], ["VendorBinary"])
        self.assertEqual(result["binary_targets"][0]["hosts"], ["VendorBinary"])
        self.assertEqual(next(item["hosts"] for item in result["source_targets"] if item["target"] == "Wrapper"), ["runner"])

    def test_wrong_vendor_runtime_uuid_is_not_reported_as_static_coverage(self):
        self.vendor.write_bytes(macho(str(uuid.uuid4()), filetype=6))
        with self.assertRaisesRegex(inventory.InventoryError, "runtime_uuid_mismatch"):
            self.collect()

    def test_vendor_staging_parent_symlink_cannot_delete_outside_build(self):
        outside = self.project / "outside"
        outside.mkdir()
        protected = outside / "vendor"
        protected.mkdir()
        sentinel = protected / "keep"
        sentinel.write_text("fixture")
        link = self.build / "redirect"
        try:
            link.symlink_to(outside, target_is_directory=True)
        except OSError:
            self.skipTest("Symlink creation unavailable")
        graph = inventory.PackageGraph(self.root, self.cache, [])
        with self.assertRaisesRegex(inventory.InventoryError, "unsafe_macos_vendor_symbol_destination"):
            graph.copy_vendor_dsyms(link / "vendor", self.build)
        self.assertEqual(sentinel.read_text(), "fixture")

    def test_vendor_staging_selects_only_distributed_uuid_debug_only_companions(self):
        graph = inventory.PackageGraph(self.root, self.cache, inventory.runtime_modules(self.build, self.app))
        graph.vendor_roots.add(self.vendor_root)
        info = plistlib.loads((self.vendor_root / "Info.plist").read_bytes())
        info["AvailableLibraries"][0]["DebugSymbolsPath"] = "dSYMs"
        (self.vendor_root / "Info.plist").write_bytes(plistlib.dumps(info))
        identifier = inventory.inspect_macho(self.vendor)["variants"][0]["uuid"]
        for name, payload in {
            "matching": macho(identifier, debug=True, text=False),
            "other-platform": macho(str(uuid.uuid4()), debug=True, text=False),
            "runtime-renamed": self.vendor.read_bytes(),
        }.items():
            path = self.vendor_library.parent / ("dSYMs/" + name + ".dSYM/Contents/Resources/DWARF/vendor")
            path.parent.mkdir(parents=True)
            path.write_bytes(payload)
        destination = self.build / "macos/sentry-prebuilt-dsyms"
        graph.copy_vendor_dsyms(destination, self.build)
        copied = list(destination.glob("*.dSYM/Contents/Resources/DWARF/*"))
        self.assertEqual(len(copied), 1)
        self.assertEqual(inventory.inspect_macho(copied[0])["variants"][0]["uuid"], identifier)

    def test_xcframework_platform_and_debug_selection_ignore_misleading_names(self):
        value = plistlib.loads((self.vendor_root / "Info.plist").read_bytes())
        poison = self.vendor_root / "macos-arm64_32-deceptive"
        poison.mkdir()
        (poison / "VendorBinary").write_bytes(b"\xca\xfe\xba\xbe" + b"not-a-valid-runtime")
        value["AvailableLibraries"].insert(0, dict(LibraryIdentifier=poison.name,
            LibraryPath="VendorBinary", SupportedPlatform="watchos", SupportedArchitectures=["arm64_32"]))
        (self.vendor_root / "Info.plist").write_bytes(plistlib.dumps(value))
        result = self.collect()
        self.assertEqual(result["binary_targets"][0]["dynamic_hosts"], ["VendorBinary"])
        report = json.loads((self.build / inventory.MANIFEST_REPORT).read_text())
        self.assertEqual(report["binary_artifacts"]["selected_macos_libraries"], 1)
        self.assertEqual(report["binary_artifacts"]["runtime_images"], 1)
        self.assertEqual(report["inventory_stage"], "inventory_receipt")

    def test_xcframework_missing_platform_architecture_and_escaped_paths_fail_closed(self):
        info_path = self.vendor_root / "Info.plist"
        original = plistlib.loads(info_path.read_bytes())
        shutil.copyfile(self.vendor_library, self.vendor_library.parent / "DifferentBinary")
        for changes, code in (({"SupportedPlatform": "ios", "SupportedPlatformVariant": "maccatalyst"}, "macos_library_missing"),
                ({"LibraryPath": "../../outside"}, "unsafe_macos_xcframework_path"),
                ({"BinaryPath": "/private/path"}, "unsafe_macos_xcframework_path"),
                ({"BinaryPath": "DifferentBinary"}, "unsafe_macos_xcframework_path"),
                ({"DebugSymbolsPath": "../../outside"}, "unsafe_macos_xcframework_path")):
            value = plistlib.loads(plistlib.dumps(original))
            value["AvailableLibraries"][0].update(changes)
            info_path.write_bytes(plistlib.dumps(value))
            with self.subTest(changes=sorted(changes)), self.assertRaisesRegex(inventory.InventoryError, code):
                inventory.selected_vendor_libraries(self.vendor_root, {"x86_64"})
        info_path.write_bytes(plistlib.dumps(original))
        with self.assertRaisesRegex(inventory.InventoryError, "architecture_missing"):
            inventory.selected_vendor_libraries(self.vendor_root, {"arm64", "x86_64"})

    @unittest.skipIf(os.name == "nt", "Debug directory symlink containment fixture requires POSIX")
    def test_declared_mac_debug_directory_cannot_follow_another_platform_bundle(self):
        info_path = self.vendor_root / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["AvailableLibraries"][0]["DebugSymbolsPath"] = "dSYMs"
        info_path.write_bytes(plistlib.dumps(info))
        debug = self.vendor_library.parent / "dSYMs"
        debug.mkdir()
        outside = self.vendor_root / "ios-only/Matching.dSYM"
        dwarf = outside / "Contents/Resources/DWARF/vendor"
        dwarf.parent.mkdir(parents=True)
        identifier = inventory.inspect_macho(self.vendor)["variants"][0]["uuid"]
        dwarf.write_bytes(macho(identifier, debug=True, text=False))
        (debug / "Redirect.dSYM").symlink_to(outside, target_is_directory=True)
        graph = inventory.PackageGraph(self.root, self.cache, inventory.runtime_modules(self.build, self.app))
        graph.vendor_roots.add(self.vendor_root)
        with self.assertRaisesRegex(inventory.InventoryError, "unsafe_macos_xcframework_path"):
            graph.copy_vendor_dsyms(self.build / "macos/sentry-prebuilt-dsyms", self.build)

    def test_invalid_vendor_and_noninventory_exceptions_have_fixed_stage_and_kind(self):
        self.vendor_library.write_bytes(b"\xca\xfe\xba\xbe" + b"private-not-a-valid-fat")
        with self.assertRaisesRegex(inventory.InventoryError, "payload_invalid"):
            self.collect()
        report = json.loads((self.build / inventory.MANIFEST_REPORT).read_text())
        self.assertEqual(report["inventory_stage"], "vendor_container_classification")
        self.assertEqual(report["exception_kind"], "macho_error")
        self.assertNotIn("private", json.dumps(report))
        with mock.patch.object(inventory, "linked_packages", return_value=inventory.LinkGraph(self.links)), \
             mock.patch.object(inventory.PackageGraph, "collect", side_effect=TypeError("private-token /private/path")), \
             self.assertRaises(TypeError):
            inventory.collect_inventory(self.project, self.build, self.app)
        report = json.loads((self.build / inventory.MANIFEST_REPORT).read_text())
        self.assertEqual(report["inventory_stage"], "selected_product_graph")
        self.assertEqual(report["exception_kind"], "type_error")
        self.assertNotIn("private", json.dumps(report))

    def test_valid_static_archive_cannot_satisfy_the_actual_runner(self):
        runner = self.app / "Contents/MacOS/Fixture"
        runner.write_bytes(universal([("x86_64", static_archive(macho(str(uuid.uuid4()), filetype=1)))]))
        with self.assertRaisesRegex(inventory.InventoryError, "invalid_macos_dependency_runtime"):
            self.collect()

    def test_dynamic_pod_archive_substitution_cannot_disappear_during_receipt_rebuild(self):
        self.metadata.write_text(json.dumps({"swift_package_manager_enabled": {"macos": False}}))
        self.pod_owned.write_text(json.dumps({"schema_version": 1, "products": [
            {"target": "example", "product": "example.framework"}]}))
        self.cp.write_text("${BUILT_PRODUCTS_DIR}/example.framework\n")
        linked = inventory.LinkGraph([], [str(self.cp)])
        with mock.patch.object(inventory, "linked_packages", return_value=linked):
            inventory.collect_inventory(self.project, self.build, self.app, pods_root=self.pods)
        initial = inventory.load_inventory(self.build, self.app)
        self.assertEqual(initial["products"], [{"target": "example", "product": "example.framework", "source": "pods"}])
        binary = self.app / "Contents/Frameworks/example.framework/example"
        binary.write_bytes(universal([("x86_64", static_archive(macho(str(uuid.uuid4()), filetype=1)))]))
        (self.build / inventory.INVENTORY).unlink()
        (self.build / inventory.RECEIPT).unlink()
        with mock.patch.object(inventory, "linked_packages", return_value=linked), \
             self.assertRaisesRegex(inventory.InventoryError, "invalid_macos_dependency_runtime"):
            inventory.collect_inventory(self.project, self.build, self.app, pods_root=self.pods)
        self.assertFalse((self.build / inventory.INVENTORY).exists())
        self.assertFalse((self.build / inventory.RECEIPT).exists())
        with self.assertRaises(MachoError):
            inventory.write_inventory(self.build, self.app, "Release", ["pods"], [])
        report = json.loads((self.build / inventory.MANIFEST_REPORT).read_text())
        self.assertEqual((report["inventory_stage"], report["exception_kind"]), ("runtime_inventory", "macho_error"))

    def test_dump_command_only_evaluates_local_manifest(self):
        graph = inventory.PackageGraph(self.root, self.cache, [], "fixture-swift")
        with mock.patch.object(inventory.subprocess, "Popen", side_effect=FileNotFoundError(2, "private-path", "fixture-swift")) as launch, \
             self.assertRaisesRegex(inventory.InventoryError, "manifest_tool_unavailable"):
            graph.dump(self.root)
        self.assertEqual(launch.call_args.args[0], ["fixture-swift", "package", "--package-path", str(self.root), "dump-package"])
        self.assertEqual(launch.call_args.kwargs["cwd"], self.root)
        self.assertEqual(launch.call_args.kwargs["stdin"], subprocess.DEVNULL)
        self.assertEqual(inventory.ManifestDumper().command, ["/usr/bin/xcrun", "--sdk", "macosx", "swift"])

    def test_source_limitations_are_per_package_target_host_and_actual_slice(self):
        sources = [dict(package="Source", target="StaticPart", hosts=["runner", "example"])]
        result = inventory.source_line_limitations(sources, {"runner": {"arm64", "x86_64"}, "example": {"x86_64"}})
        self.assertEqual({(item["host"], item["architecture"]) for item in result},
                         {("runner", "arm64"), ("runner", "x86_64"), ("example", "x86_64")})
        self.assertTrue(all(item["reason"] == inventory.SOURCE_LINE_LIMITATION and item["source"] == "spm" for item in result))
        self.assertNotIn("missing", json.dumps(result))
        with self.assertRaisesRegex(inventory.InventoryError, "host_architecture_missing"):
            inventory.source_line_limitations(sources, {"runner": {"arm64"}})

    def configure_link_helper(self, **extra):
        self.vendor_library.write_bytes(static_archive(macho(str(uuid.uuid4()), filetype=1)))
        directory = self.binary / "Sources/LinkAnchor"
        directory.mkdir(parents=True, exist_ok=True)
        self.helper_source = directory / "Anchor.swift"
        self.helper_source.write_text("// Empty selected source; supplies only a library link setting.\n")
        anchor = target("LinkAnchor", path="Sources/LinkAnchor", settings=[
            {"tool": "linker", "kind": {"linkedLibrary": {"_0": "c++"}}}], **extra)
        self.write_package(self.binary, package("Vendor", [library("VendorProduct", ["VendorBinary", "LinkAnchor"])], [
            target("VendorBinary", kind="binary", path="VendorBinary.xcframework"), anchor]))
        return anchor

    def rewrite_collected(self, value):
        return inventory.write_inventory(self.build, self.app, "Release", value["dependency_managers"],
                                         value["products"], value["source_targets"], value["binary_targets"])

    def test_comments_only_lexer_does_not_strip_code_or_language_translation_edges(self):
        for raw, language in ((b" \t\r\n", "swift"), (b"// comment\r\n/* outer /* nested */ end */", "swift"),
                              (b"/* comment */\n// comment", "c++"), (b"/* comment */", "c")):
            self.assertTrue(inventory.comments_only_source(raw, language))
        for raw, language in ((b"let value = 1", "swift"), (b'"/* text */"', "swift"),
                              (b"/* unfinished", "swift"), (b"/* outer /* nested */ code */", "c"),
                              (b"// comment\rcode()", "c++"), (b"// comment\x00code()", "swift"),
                              (b"/* x *\\\n/ int live; /* */", "c"), (b"/* x *??/\n/ int live; /* */", "c"),
                              (b"#include <injected.h>", "c++"), (b"// comment\xe2\x80\xa8code()", "swift")):
            self.assertFalse(inventory.comments_only_source(raw, language))

    def test_empty_link_helper_is_preserved_with_receipt_bound_proof_and_safe_scope(self):
        self.configure_link_helper()
        value = self.collect()
        self.assertNotIn("VendorBinary.framework", {item["product"] for item in value["products"]})
        helper = next(item for item in value["source_targets"] if item["target"] == "LinkAnchor")
        self.assertEqual(helper["hosts"], ["VendorBinary"])
        self.assertEqual(helper["linker_only"]["linker_settings"], [{"kind": "linkedLibrary", "value": "c++"}])
        self.assertNotIn(helper, inventory.required_source_targets(value["source_targets"]))
        limits = inventory.source_line_limitations([helper], {"VendorBinary": {"arm64", "x86_64"}})
        self.assertEqual({item["architecture"] for item in limits}, {"arm64", "x86_64"})
        self.assertTrue(all(item["reason"] == inventory.LINKER_ONLY_LIMITATION for item in limits))
        raw = json.loads((self.build / inventory.INVENTORY).read_text())
        raw_helper = next(item for item in raw["source_targets"] if item["target"] == "LinkAnchor")
        self.assertEqual(inventory.required_source_targets([raw_helper]), [raw_helper])
        before = (self.build / inventory.INVENTORY).read_bytes()
        self.rewrite_collected(value)
        self.assertEqual(before, (self.build / inventory.INVENTORY).read_bytes())
        inventory.load_inventory(self.build, self.app)
        # A post-validation mutation loses its in-memory permission as well.
        helper["linker_only"]["sources"][0]["bytes"] += 1
        self.assertEqual(inventory.required_source_targets([helper]), [helper])

    def test_nonempty_unknown_or_injected_target_inputs_remain_owned(self):
        self.configure_link_helper()
        baseline = json.loads((self.binary / "dump.json").read_text())
        cases = [("code", {}, b"func alive() {}"), ("resources", {"resources": [{"path": "assets", "rule": {"copy": {}}}]}, None),
                 ("headers", {"publicHeadersPath": "include"}, None), ("plugins", {"pluginUsages": [{"name": "Generator"}]}, None),
                 ("exclude", {"exclude": ["private.c"]}, None), ("unknown", {"newCompilerMode": True}, None),
                 ("unsafe", {"settings": [{"tool": "swift", "kind": {"unsafeFlags": {"_0": ["-import-objc-header", "injected.h"]}}}]}, None),
                 ("dependency", {"dependencies": [{"target": ["VendorBinary", None]}]}, None)]
        for name, fields, content in cases:
            with self.subTest(name=name):
                value = json.loads(json.dumps(baseline))
                value["targets"][1].update(fields)
                (self.binary / "dump.json").write_text(json.dumps(value))
                self.helper_source.write_bytes(content or b"// empty\n")
                result = self.collect()
                helper = next(item for item in result["source_targets"] if item["target"] == "LinkAnchor")
                self.assertNotIn("linker_only", helper)
                self.assertIn("VendorBinary.framework", {item["product"] for item in result["products"]})
        (self.binary / "dump.json").write_text(json.dumps(baseline))
        self.helper_source.with_suffix(".h").write_text("// Even an empty header is not a source-only proof.\n")
        result = self.collect()
        self.assertNotIn("linker_only", next(item for item in result["source_targets"] if item["target"] == "LinkAnchor"))

    def test_link_helper_proof_rejects_modified_bytes_manifest_unknown_fields_or_host(self):
        self.configure_link_helper()
        original = self.collect()
        for field in ("source", "manifest", "new_file"):
            with self.subTest(field=field):
                manifest = self.binary / "Package.swift"
                source_before, manifest_before = self.helper_source.read_bytes(), manifest.read_bytes()
                extra = self.helper_source.with_name("Injected.swift")
                if field == "source":
                    self.helper_source.write_text("// Changed bytes, still empty.\n")
                elif field == "manifest":
                    manifest.write_text("// Changed selected manifest.\n")
                else:
                    extra.write_text("// New source was not part of the recorded enumeration.\n")
                with self.assertRaisesRegex(inventory.InventoryError, "inventory_missing_or_mismatched"):
                    inventory.load_inventory(self.build, self.app)
                self.helper_source.write_bytes(source_before)
                manifest.write_bytes(manifest_before)
                extra.unlink(missing_ok=True)
        for field in ("proof_deleted", "wrong_host", "unknown_field", "marker", "wrong_product"):
            with self.subTest(field=field):
                value = json.loads(json.dumps(original))
                helper = next(item for item in value["source_targets"] if item["target"] == "LinkAnchor")
                if field == "proof_deleted":
                    del helper["linker_only"]
                elif field == "marker":
                    del helper["linker_only"]
                    helper["_linker_only_validated"] = True
                elif field == "wrong_host":
                    helper["linker_only"]["binary_targets"][0]["host"] = "runner"
                elif field == "wrong_product":
                    helper["linker_only"]["product_targets"] = ["LinkAnchor"]
                else:
                    helper["linker_only"]["raw"] = "private-token /private/source"
                self.rewrite_collected(value)
                with self.assertRaisesRegex(inventory.InventoryError, "inventory_missing_or_mismatched"):
                    inventory.load_inventory(self.build, self.app)

    def test_an_unrelated_binary_product_cannot_waive_empty_source_obligation(self):
        self.configure_link_helper()
        shutil.rmtree(self.vendor.parent)
        value = json.loads((self.binary / "dump.json").read_text())
        value["products"] = [library("VendorProduct", ["LinkAnchor"]), library("OtherBinary", ["VendorBinary"])]
        (self.binary / "dump.json").write_text(json.dumps(value))
        root = json.loads((self.root / "dump.json").read_text())
        root["targets"][0]["dependencies"].append({"product": ["OtherBinary", "vendor", None, None]})
        (self.root / "dump.json").write_text(json.dumps(root))
        result = self.collect()
        helper = next(item for item in result["source_targets"] if item["target"] == "LinkAnchor")
        self.assertNotIn("linker_only", helper)
        self.assertIn(helper, inventory.required_source_targets(result["source_targets"]))

    def test_same_name_targets_from_distinct_package_identities_cannot_overwrite_live_source(self):
        self.configure_link_helper()
        other = self.project / "other-vendor"
        other_source = other / "Sources/LinkAnchor/Active.swift"
        other_source.parent.mkdir(parents=True)
        other_source.write_text("public func liveTarget() {}\n")
        self.write_package(other, package("Vendor", [library("VendorBinary", ["LinkAnchor"])], [
            target("LinkAnchor", path="Sources/LinkAnchor")]))
        value = json.loads((self.root / "dump.json").read_text())
        # Visit the live identity first, then the empty identity. Neither order
        # may erase the former descriptor under a shared display name.
        value["dependencies"].append(self.local_dependency("other-vendor", other))
        value["targets"][0]["dependencies"].insert(0, {"product": ["VendorBinary", "other-vendor", None, None]})
        (self.root / "dump.json").write_text(json.dumps(value))
        result = self.collect()
        helper = next(item for item in result["source_targets"] if item["package"] == "Vendor" and item["target"] == "LinkAnchor")
        self.assertEqual(helper["hosts"], ["VendorBinary"])
        self.assertNotIn("linker_only", helper)
        self.assertIn("VendorBinary.framework", {item["product"] for item in result["products"]})

    def test_one_empty_target_cannot_waive_another_active_target_in_the_same_product(self):
        self.configure_link_helper()
        source = self.binary / "Sources/Active/Code.swift"
        source.parent.mkdir(parents=True)
        source.write_text("public func contributesCode() {}\n")
        value = json.loads((self.binary / "dump.json").read_text())
        value["products"][0]["targets"].append("Active")
        value["targets"].append(target("Active", path="Sources/Active"))
        (self.binary / "dump.json").write_text(json.dumps(value))
        result = self.collect()
        sources = [item for item in result["source_targets"] if item["package"] == "Vendor"]
        self.assertEqual({item["target"] for item in inventory.required_source_targets(sources)}, {"Active"})
        self.assertIn("VendorBinary.framework", {item["product"] for item in result["products"]})

    def test_missing_or_oversize_helper_sources_never_create_a_waiver(self):
        self.configure_link_helper()
        for content in (None, b"/" * (inventory.MAX_LINK_HELPER_FILE_BYTES + 1)):
            if content is None:
                self.helper_source.unlink()
            else:
                self.helper_source.write_bytes(content)
            result = self.collect()
            self.assertNotIn("linker_only", next(item for item in result["source_targets"] if item["target"] == "LinkAnchor"))

    @unittest.skipIf(os.name == "nt", "Link-helper symlink fixture requires POSIX symlinks")
    def test_link_helper_package_keeps_logical_alias_but_cannot_follow_a_source_symlink(self):
        self.configure_link_helper()
        physical = self.project / "physical-vendor"
        self.binary.rename(physical)
        self.binary.symlink_to(physical, target_is_directory=True)
        result = self.collect()
        helper = next(item for item in result["source_targets"] if item["target"] == "LinkAnchor")
        self.assertEqual(helper["linker_only"]["package_path"], "local-binary")
        outside = self.project / "unbound.swift"
        outside.write_text("// Empty bytes are insufficient if their path is not a bound target source.\n")
        self.helper_source.unlink()
        self.helper_source.symlink_to(outside)
        result = self.collect()
        self.assertNotIn("linker_only", next(item for item in result["source_targets"] if item["target"] == "LinkAnchor"))

    def test_swift63_dependency_tuple_arity_is_exact_and_shape_failures_have_fixed_codes(self):
        for dependency in ({"product": ["Example", "source", None]}, {"product": ["Example", "source", None, None, None]},
                           {"byName": ["Example", None, None]}, {"target": "private-value"}):
            value = json.loads((self.root / "dump.json").read_text())
            value["targets"][0]["dependencies"] = [dependency]
            (self.root / "dump.json").write_text(json.dumps(value))
            with self.assertRaisesRegex(inventory.InventoryError, "unsupported_macos_package_target_dependency"):
                self.collect()

    def test_manifest_environment_and_stderr_projection_never_relay_raw_values(self):
        original = dict(PATH="fixture-path", HOME="fixture-home", DEVELOPER_DIR="selected-xcode", TOOLCHAINS="selected-toolchain",
                        SDKROOT="app-sdk", SWIFT_EXEC="app-compiler", SWIFTPM_CUSTOM_LIBS_DIR="app-libs",
                        SWIFTPM_MODULECACHE_OVERRIDE="app-cache", DYLD_LIBRARY_PATH="app-library",
                        SENTRY_AUTH_TOKEN="private-token", SENTRY_MAINTENANCE_TOKEN="private-token",
                        DART_DEFINES="private-defines", XB_AES_KEY="private-key", GIT_TERMINAL_PROMPT="1")
        inherited = inventory.manifest_environment(original, mode="inherited")
        host = inventory.manifest_environment(original, mode="host")
        for key in ("SENTRY_AUTH_TOKEN", "SENTRY_MAINTENANCE_TOKEN", "DART_DEFINES", "XB_AES_KEY"):
            self.assertNotIn(key, inherited)
            self.assertNotIn(key, host)
        for key in ("SDKROOT", "SWIFT_EXEC", "SWIFTPM_CUSTOM_LIBS_DIR", "SWIFTPM_MODULECACHE_OVERRIDE", "DYLD_LIBRARY_PATH"):
            self.assertIn(key, inherited)
            self.assertNotIn(key, host)
        self.assertEqual(host["DEVELOPER_DIR"], "selected-xcode")
        self.assertEqual(host["TOOLCHAINS"], "selected-toolchain")
        self.assertEqual(host["GIT_TERMINAL_PROMPT"], "0")
        raw = b"private-token /private/path https://user:secret@example.invalid/?token=secret invalid manifest: sandbox-exec: Operation not permitted"
        categories = inventory.manifest_stderr_categories(raw)
        self.assertEqual(set(categories), {"manifest_invalid", "sandbox_denied", "permission_denied"})
        self.assertNotIn("private", json.dumps(categories))
        self.assertEqual(inventory.manifest_stderr_categories(b"private-token /private/path"), ["unclassified_diagnostic"])

    @unittest.skipIf(os.name == "nt", "Bounded manifest pipe fixture requires POSIX")
    def test_dump_only_visits_actual_product_closure_without_runtime_or_receipt(self):
        tool = self.project / "fixture-swift"
        tool.write_text("#!" + sys.executable + "\nfrom pathlib import Path\nprint((Path.cwd() / 'dump.json').read_text())\n")
        tool.chmod(0o755)
        value = json.loads((self.root / "dump.json").read_text())
        value["targets"].append(target("NotSelected", [{"product": ["Missing", "unused", None, None]}]))
        value["dependencies"].append(self.local_dependency("unused", self.project / "must-not-be-evaluated"))
        (self.root / "dump.json").write_text(json.dumps(value))
        with mock.patch.object(inventory, "linked_packages", return_value=inventory.LinkGraph(self.links)):
            report = inventory.diagnose_manifests(self.project, self.build, environment={}, swift=str(tool))
        self.assertEqual(report["status"], "complete", report)
        self.assertTrue(report["closure_complete"])
        self.assertEqual([row["package"] for row in report["calls"]],
                         ["FlutterGeneratedPluginSwiftPackage", "source", "vendor", "launchatlogin"])
        self.assertEqual([row["ordinal"] for row in report["calls"]], [1, 2, 3, 4])
        self.assertEqual(report["selected_target_count"], 6)
        self.assertFalse((self.build / inventory.INVENTORY).exists())
        self.assertFalse((self.build / inventory.RECEIPT).exists())
        graph = inventory.PackageGraph(self.root, self.cache, [], manifest_only=True)
        with self.assertRaisesRegex(inventory.InventoryError, "manifest_diagnostics_only"):
            graph.collect()

    @unittest.skipIf(os.name == "nt", "Bounded manifest pipe fixture requires POSIX")
    def test_manifest_process_failures_timeouts_caps_and_json_have_safe_reports(self):
        tool = self.project / "fixture-swift"
        cases = [
            ("import sys; print('invalid manifest private-token /private/path', file=sys.stderr); sys.exit(7)",
             "macos_local_package_manifest_evaluation_failed", 7, False),
            ("print('private-token /private/path')", "macos_local_package_manifest_json_invalid", 0, False),
            ("import time; time.sleep(60)", "macos_local_package_manifest_evaluation_timeout", None, True),
            ("print('private-token' * 10000)", "macos_local_package_manifest_output_limit", None, False),
        ]
        for code, expected, exit_code, timed_out in cases:
            with self.subTest(expected=expected):
                tool.write_text("#!" + sys.executable + "\n" + code + "\n")
                tool.chmod(0o755)
                dumper = inventory.ManifestDumper(swift=str(tool), environment={}, timeout=.2)
                output = io.StringIO()
                started = time.monotonic()
                with mock.patch.object(inventory, "MANIFEST_STDOUT_LIMIT", 256), \
                     contextlib.redirect_stdout(output), contextlib.redirect_stderr(output), \
                     self.assertRaises(inventory.InventoryError) as raised:
                    dumper.dump(self.root, role="generated_root", package_label="FlutterGeneratedPluginSwiftPackage")
                self.assertEqual(str(raised.exception), expected)
                report = dumper.report(error=str(raised.exception))
                self.assertFalse(report["closure_complete"])
                row = report["calls"][0]
                self.assertEqual(row["timed_out"], timed_out)
                if exit_code is not None:
                    self.assertEqual(row["exit_code"], exit_code)
                self.assertLessEqual(row["stdout_bytes"], 256)
                self.assertLess(time.monotonic() - started, 3)
                self.assertEqual(output.getvalue(), "")
                self.assertNotIn("private", json.dumps(report))
                self.assertNotIn(str(self.project), json.dumps(report))

    @unittest.skipIf(os.name == "nt", "Bounded manifest pipe fixture requires POSIX")
    def test_diagnostic_failure_identifies_package_and_cannot_claim_complete_closure(self):
        tool = self.project / "fixture-swift"
        tool.write_text("#!" + sys.executable + "\nfrom pathlib import Path\nimport sys\n"
                        "if Path.cwd().name == 'local-source':\n"
                        " print('invalid manifest private-token /private/path', file=sys.stderr)\n"
                        " sys.exit(9)\n"
                        "print((Path.cwd() / 'dump.json').read_text())\n")
        tool.chmod(0o755)
        with mock.patch.object(inventory, "linked_packages", return_value=inventory.LinkGraph(self.links)):
            report = inventory.diagnose_manifests(self.project, self.build, environment={}, swift=str(tool))
        self.assertEqual(report["status"], "failed")
        self.assertFalse(report["closure_complete"])
        self.assertEqual(report["error"], "macos_local_package_manifest_evaluation_failed")
        failed = report["calls"][-1]
        self.assertEqual((failed["ordinal"], failed["role"], failed["package"], failed["exit_code"]),
                         (2, "dependency_local", "source", 9))
        self.assertEqual(failed["stderr_categories"], ["manifest_invalid"])
        self.assertNotIn("private", json.dumps(report))
        self.assertFalse((self.build / inventory.INVENTORY).exists())
        self.assertFalse((self.build / inventory.RECEIPT).exists())

    def test_xcode_parser_uses_frameworks_edges_for_generated_and_direct_packages(self):
        objects = {
            "project": {"packageReferences": ["local", "remote"]},
            "runner": {"isa": "PBXNativeTarget", "name": "Runner", "buildPhases": ["frameworks", "cp"]},
            "frameworks": {"isa": "PBXFrameworksBuildPhase", "files": ["f1", "f2"]},
            "f1": {"productRef": "generated"}, "f2": {"productRef": "launch"},
            "generated": {"productName": "FlutterGeneratedPluginSwiftPackage"},
            "launch": {"productName": "LaunchAtLogin", "package": "remote"},
            "local": {"isa": "XCLocalSwiftPackageReference", "relativePath": "Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage"},
            "remote": {"isa": "XCRemoteSwiftPackageReference", "repositoryURL": "https://github.com/sindresorhus/LaunchAtLogin"},
            "cp": {"isa": "PBXShellScriptBuildPhase", "shellScript": '${PODS_ROOT}/Target Support Files/Pods-Runner/Pods-Runner-frameworks.sh',
                   "inputFileListPaths": [str(self.cp)]},
        }
        with mock.patch.object(inventory.subprocess, "run", return_value=subprocess.CompletedProcess(
                [], 0, json.dumps({"objects": objects, "rootObject": "project"}), '')):
            result = inventory.linked_packages(self.project)
            self.assertEqual(result, self.links)
            self.assertEqual(result.pods_filelists, [str(self.cp)])


class StaticArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="sentry-static-archive-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()

    def test_thin_and_universal_archives_are_not_runtime_images(self):
        thin = static_archive(macho(str(uuid.uuid4()), filetype=1))
        arm = static_archive(macho(str(uuid.uuid4()), architecture="arm64", filetype=1))
        for raw, architectures in ((thin, {"x86_64"}), (universal([("x86_64", thin), ("arm64", arm)]), {"arm64", "x86_64"})):
            path = self.root / "archive"
            path.write_bytes(raw)
            self.assertEqual(static_archive_architectures(path), architectures)
            self.assertEqual(is_macho(path), raw[:4] == b"\xca\xfe\xba\xbe")
            with self.assertRaises(MachoError):
                inventory.inspect_macho(path)

    def test_archive_headers_bounds_cpus_and_object_members_are_validated(self):
        thin = static_archive(macho(str(uuid.uuid4()), filetype=1))
        valid = universal([("x86_64", thin)])
        wrong_cpu = bytearray(valid)
        struct.pack_into(">i", wrong_cpu, 8, 0x0100000c)
        wrong_count = bytearray(valid)
        struct.pack_into(">I", wrong_count, 4, 65)
        wrong_bounds = bytearray(valid)
        struct.pack_into(">I", wrong_bounds, 16, len(valid) + 1)
        wrong_metadata = bytearray(thin)
        wrong_metadata[24] = ord("x")
        mixed = universal([("x86_64", thin), ("arm64", macho(str(uuid.uuid4()), architecture="arm64"))])
        for raw in (thin[:-1], b"!<arch>\n", static_archive(macho(str(uuid.uuid4()), filetype=2)),
                    wrong_cpu, wrong_count, wrong_bounds, wrong_metadata, mixed):
            path = self.root / "invalid"
            path.write_bytes(raw)
            with self.subTest(size=len(raw)), self.assertRaises(MachoError):
                static_archive_architectures(path)
            if raw[:4] == b"\xca\xfe\xba\xbe":
                self.assertTrue(is_macho(path))  # strict runtime parsing still sees malformed FAT
                with self.assertRaises(MachoError):
                    inventory.inspect_macho(path)

    def test_arm64e_capability_bit_is_archive_metadata_only(self):
        obj = bytearray(macho(str(uuid.uuid4()), architecture="arm64", filetype=1))
        struct.pack_into("<i", obj, 8, -2147483646)
        archive = bytearray(universal([("arm64", static_archive(obj))]))
        struct.pack_into(">i", archive, 12, 2)
        path = self.root / "arm64e.a"
        path.write_bytes(archive)
        self.assertEqual(static_archive_architectures(path), {"arm64e"})
        self.assertTrue(is_macho(path))  # magic probe does not exempt app runtime archives

    @unittest.skipUnless(os.name == "posix" and generation.CLANG, "Real archive fixture requires POSIX clang")
    def test_real_llvm_ar_and_lipo_archive_has_two_validated_object_slices(self):
        ar = generation.tool_path("llvm-ar") or shutil.which("ar")
        lipo = generation.tool_path("llvm-lipo") or shutil.which("lipo")
        if not ar or not lipo:
            self.skipTest("Real archive tools unavailable")
        source = self.root / "archive.c"
        source.write_text("int archive_fixture(void) { return 7; }\n")
        archives = []
        for architecture in ("arm64", "x86_64"):
            obj, archive = self.root / (architecture + ".o"), self.root / (architecture + ".a")
            for command in ([generation.CLANG, "--target=" + architecture + "-apple-macos11", "-g", "-c", str(source), "-o", str(obj)],
                            [ar, "rcs", str(archive), str(obj)]):
                subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            archives.append(archive)
        combined = self.root / "universal.a"
        subprocess.run([lipo, "-create", *map(str, archives), "-output", str(combined)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(static_archive_architectures(combined), {"arm64", "x86_64"})
        self.assertTrue(is_macho(combined))


@unittest.skipUnless(generation.CLANG and generation.LINKER and generation.DSYMUTIL, "Mach-O fixture tools unavailable")
class SpmPreparationTests(generation.MacGenerationTests):
    def setUp(self):
        super().setUp()
        inventory.write_inventory(self.build, self.app, "Release", ["spm"], [
            {"target": "example", "product": "example.framework", "source": "spm"},
        ], [dict(package="Source", target="example", hosts=["example"]),
            dict(package="Source", target="StaticPart", hosts=["runner"])])

    def test_spm_dynamic_source_requires_matching_dsym_and_cannot_be_prebuilt(self):
        manifest = json.loads(self.prepare().read_text())
        self.assertEqual(next(item["source"] for item in manifest["artifacts"] if item["target"] == "example"), "spm")
        shutil.rmtree(self.products / "example.dSYM")
        with mock.patch("prepare_sentry_macos_symbols.subprocess.run", return_value=subprocess.CompletedProcess([], 1)), \
             self.assertRaisesRegex(generation.PreparationError, "required_macos_matching_dsym_unavailable"):
            self.prepare()

    @unittest.skipUnless(generation.CLI, "Pinned sentry-cli unavailable")
    def test_products_archive_is_not_oso_runtime_and_required_dsym_rejects_archive(self):
        import upload_sentry_symbols as upload
        archive = universal([("x86_64", static_archive(macho(str(uuid.uuid4()), filetype=1)))])
        candidate = self.products / "static-inputs/FlutterMacOS.framework/FlutterMacOS"
        candidate.parent.mkdir(parents=True)
        candidate.write_bytes(archive)
        path = self.prepare()
        upload.audit_macos(generation.CLI, self.build)
        manifest = json.loads(path.read_text())
        required_debug = self.build / next(item["debug_file"] for item in manifest["artifacts"] if item["target"] == "runner")
        required_debug.write_bytes(archive)
        with self.assertRaisesRegex(upload.SymbolError, "Invalid Mach-O runtime or debug companion"):
            upload.audit_macos(generation.CLI, self.build)

    @unittest.skipUnless(generation.CLI, "Pinned sentry-cli unavailable")
    def test_archive_cannot_replace_required_rust_runtime_even_with_fresh_receipt(self):
        import upload_sentry_symbols as upload
        self.prepare()
        rust = self.app / "Contents/Frameworks/rust_api.framework/Versions/A/rust_api"
        rust.write_bytes(universal([("x86_64", static_archive(macho(str(uuid.uuid4()), filetype=1)))]))
        with self.assertRaises(MachoError):
            inventory.write_inventory(self.build, self.app, "Release", ["spm"], [
                {"target": "example", "product": "example.framework", "source": "spm"}],
                [dict(package="Source", target="example", hosts=["example"])])
        with self.assertRaisesRegex(upload.SymbolError, "inventory/build receipt"):
            upload.audit_macos(generation.CLI, self.build)
        with self.assertRaisesRegex(generation.PreparationError, "macos_owned_or_bundle_metadata_missing"):
            self.prepare()

    def test_matching_vendor_dsym_is_usable_without_claiming_source_ownership(self):
        shutil.copytree(self.modules["FlutterMacOS"][1], self.products / "FlutterMacOS.dSYM")
        manifest = json.loads(self.prepare().read_text())
        self.assertTrue(any(item["target"] == "FlutterMacOS" and item["source"] == "prebuilt" for item in manifest["artifacts"]))
        self.assertFalse(any(item["target"] == "FlutterMacOS" for item in manifest["required"]))
        if generation.CLI:
            import upload_sentry_symbols as upload
            self.assertTrue(any(item["target"] == "FlutterMacOS" for item in upload.audit_macos(generation.CLI, self.build)[1]))

    @unittest.skipUnless(generation.CLI and generation.MACHO_STRIP, "Offline CLI/strip tools unavailable")
    def test_empty_helper_static_vendor_without_host_dsym_retains_all_independent_limits(self):
        import upload_sentry_symbols as upload
        runtime = self.app / "Contents/Frameworks/FixtureVendor.framework/FixtureVendor"
        runtime.parent.mkdir(parents=True)
        self.run_command([generation.MACHO_STRIP, "-S", "-o", str(runtime), str(self.modules["FlutterMacOS"][0])])
        root = self.root / "macos/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage"
        plugin, vendor = self.root / "fixture-source", self.root / "fixture-vendor"
        for path in (root, plugin, vendor):
            path.mkdir(parents=True)
            (path / "Package.swift").write_text("// Selected evaluated manifest fixture.\n")
        source = vendor / "Sources/Anchor/Empty.swift"
        source.parent.mkdir(parents=True)
        source.write_text("// Empty link helper.\n")
        payload = vendor / "FixtureVendor.a"
        payload.write_bytes(static_archive(macho(str(uuid.uuid4()), filetype=1)))
        manifests = {
            root: package("FlutterGeneratedPluginSwiftPackage", [library("FlutterGeneratedPluginSwiftPackage", ["Generated"], "static")],
                          [target("Generated", [{"product": ["Example", "source", None, None]},
                                                {"product": ["FixtureVendor", "vendor", None, None]}])],
                          [SpmInventoryTests.local_dependency("source", plugin), SpmInventoryTests.local_dependency("vendor", vendor)]),
            plugin: package("Source", [library("Example", ["example"], "dynamic")], [target("example")]),
            vendor: package("Vendor", [library("FixtureVendor", ["FixtureVendor", "Anchor"])], [
                target("FixtureVendor", kind="binary", path=payload.name), target("Anchor", path="Sources/Anchor")]),
        }
        (self.root / ".flutter-plugins-dependencies").write_text(json.dumps({"swift_package_manager_enabled": {"macos": False}}))
        def collect():
            with mock.patch.object(inventory, "linked_packages", return_value=inventory.LinkGraph([
                    ("local", root, "FlutterGeneratedPluginSwiftPackage")])), \
                 mock.patch.object(inventory.PackageGraph, "dump", side_effect=lambda path: manifests[path]):
                inventory.collect_inventory(self.root, self.build, self.app)
        collect()
        metadata = inventory.load_inventory(self.build, self.app)
        self.assertNotIn("FixtureVendor.framework", {item["product"] for item in metadata["products"]})
        self.assertIn("example.framework", {item["product"] for item in metadata["products"]})
        path = self.prepare()
        original = json.loads(path.read_text())
        self.assertFalse(any(item["target"] == "FixtureVendor" for item in original["artifacts"]))
        reasons = {item["reason"] for item in original["limitations"] if item["target"] in {"Anchor", "FixtureVendor"}}
        expected = {inventory.LINKER_ONLY_LIMITATION, "prebuilt_debug_companion_unavailable", "static_binary_package_debug_coverage_unverified"}
        self.assertEqual(reasons, expected)
        upload.audit_macos(generation.CLI, self.build)
        for reason in sorted(expected):
            value = json.loads(json.dumps(original))
            value["limitations"] = [item for item in value["limitations"] if item["reason"] != reason]
            path.write_text(json.dumps(value))
            with self.assertRaises(upload.SymbolError):
                upload.audit_macos(generation.CLI, self.build)
        source.write_text("public func realExecutableContribution() {}\n")
        collect()
        with self.assertRaisesRegex(generation.PreparationError, "required_macos_matching_dsym_unavailable"):
            self.prepare()

    @unittest.skipUnless(generation.CLI, "Pinned sentry-cli unavailable")
    def test_collected_graph_preparation_and_real_cli_audit_are_connected(self):
        root = self.root / "macos/Flutter/ephemeral/Packages/FlutterGeneratedPluginSwiftPackage"
        plugin = self.root / "fixture-source"
        for path in (root, plugin):
            path.mkdir(parents=True)
            (path / "Package.swift").write_text("// Offline manifest evaluation fixture\n")
        (self.root / ".flutter-plugins-dependencies").write_text(json.dumps({"swift_package_manager_enabled": {"macos": False}}))
        manifests = {
            root.resolve(): package("FlutterGeneratedPluginSwiftPackage", [
                library("FlutterGeneratedPluginSwiftPackage", ["FlutterGeneratedPluginSwiftPackage"], "static")], [
                target("FlutterGeneratedPluginSwiftPackage", [{"product": ["Example", "fixture-source", None, None]}])],
                [{"fileSystem": [{"identity": "fixture-source", "path": str(plugin)}]}]),
            plugin.resolve(): package("FixtureSource", [library("Example", ["example"], "dynamic")], [target("example")]),
        }
        with mock.patch.object(inventory, "linked_packages", return_value=inventory.LinkGraph([
                ("local", root, "FlutterGeneratedPluginSwiftPackage")])), \
             mock.patch.object(inventory.PackageGraph, "dump", side_effect=lambda path: manifests[path.resolve()]):
            inventory.collect_inventory(self.root, self.build, self.app)
        self.prepare()
        import upload_sentry_symbols as upload
        self.assertEqual(next(item["source"] for item in upload.audit_macos(generation.CLI, self.build)[1]
                              if item["target"] == "example"), "spm")
        path = self.build / "sentry-native/macos/manifest.json"
        value = json.loads(path.read_text())
        value["artifacts"] = [item for item in value["artifacts"] if item["target"] != "example"]
        value["required"] = [item for item in value["required"] if item["target"] != "example"]
        value["limitations"].append(dict(target="example", architecture="x86_64", source="prebuilt", reason="external_debug_companion_unavailable"))
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(upload.SymbolError, "static host dSYM|locally compiled"):
            upload.audit_macos(generation.CLI, self.build)

    @unittest.skipUnless(generation.CLI, "Pinned sentry-cli unavailable")
    def test_static_prebuilt_boundary_cannot_disappear_from_coverage(self):
        inventory.write_inventory(self.build, self.app, "Release", ["spm"], [
            {"target": "example", "product": "example.framework", "source": "spm"}],
            [dict(package="Source", target="example", hosts=["example"])],
            [dict(package="Vendor", target="VendorStatic", hosts=["runner"], dynamic_hosts=[])])
        manifest_path = self.prepare()
        value = json.loads(manifest_path.read_text())
        self.assertTrue(any(item["target"] == "VendorStatic" and item["source"] == "prebuilt" for item in value["limitations"]))
        import upload_sentry_symbols as upload
        upload.audit_macos(generation.CLI, self.build)
        value["limitations"] = [item for item in value["limitations"] if item["target"] != "VendorStatic"]
        manifest_path.write_text(json.dumps(value))
        with self.assertRaisesRegex(upload.SymbolError, "static binary package omitted"):
            upload.audit_macos(generation.CLI, self.build)

    @unittest.skipUnless(generation.CLI, "Pinned sentry-cli unavailable")
    def test_source_line_limits_cannot_be_deleted_forged_or_replace_host_dsym(self):
        import upload_sentry_symbols as upload
        path = self.prepare()
        original = json.loads(path.read_text())
        limits = [item for item in original["limitations"] if item["reason"] == inventory.SOURCE_LINE_LIMITATION]
        self.assertEqual({(item["package"], item["target"], item["host"], item["architecture"]) for item in limits},
                         {("Source", "StaticPart", "runner", "x86_64"), ("Source", "example", "example", "x86_64")})
        self.assertTrue(all(item in upload.audit_macos(generation.CLI, self.build)[2] for item in limits))
        value = json.loads(json.dumps(original))
        value["limitations"] = [item for item in value["limitations"] if item["reason"] != inventory.SOURCE_LINE_LIMITATION]
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(upload.SymbolError, "target line coverage limitation"):
            upload.audit_macos(generation.CLI, self.build)
        for field, changed in (("package", "Other"), ("host", "rust_api"), ("architecture", "arm64"), ("source", "prebuilt")):
            value = json.loads(json.dumps(original))
            next(item for item in value["limitations"] if item["reason"] == inventory.SOURCE_LINE_LIMITATION)[field] = changed
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(upload.SymbolError, "source target coverage limitation"):
                upload.audit_macos(generation.CLI, self.build)
        value = json.loads(json.dumps(original))
        value["artifacts"] = [item for item in value["artifacts"] if item["target"] != "runner"]
        value["required"] = [item for item in value["required"] if item["target"] != "runner"]
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(upload.SymbolError, "static host dSYM|locally compiled"):
            upload.audit_macos(generation.CLI, self.build)

    @unittest.skipUnless(generation.CLI, "Pinned sentry-cli unavailable")
    def test_static_vendor_component_can_share_name_with_required_source_host(self):
        import upload_sentry_symbols as upload
        inventory.write_inventory(self.build, self.app, "Release", ["spm"], [
            {"target": "example", "product": "example.framework", "source": "spm"}],
            [dict(package="Source", target="example", hosts=["example"])],
            [dict(package="Vendor", target="example", hosts=["example"], dynamic_hosts=[])])
        path = self.prepare()
        _, _, limits = upload.audit_macos(generation.CLI, self.build)
        self.assertTrue(any(item["source"] == "spm" and item["reason"] == inventory.SOURCE_LINE_LIMITATION for item in limits))
        self.assertTrue(any(item["source"] == "prebuilt" and item["reason"] == "static_binary_package_debug_coverage_unverified" for item in limits))
        value = json.loads(path.read_text())
        value["artifacts"] = [item for item in value["artifacts"] if item["target"] != "example"]
        value["required"] = [item for item in value["required"] if item["target"] != "example"]
        path.write_text(json.dumps(value))
        with self.assertRaisesRegex(upload.SymbolError, "static host dSYM|locally compiled"):
            upload.audit_macos(generation.CLI, self.build)

    def test_real_static_source_object_contributes_lines_to_host_dsym(self):
        static = self.root / "FixtureStaticPart.c"
        main = self.root / "FixtureMain.c"
        static.write_text("int package_static_function(int n) { return n * 7; }\n")
        main.write_text("int package_static_function(int); int main(void) { return package_static_function(3); }\n")
        objects = []
        for source in (static, main):
            obj = source.with_suffix(".o")
            self.run_command([generation.CLANG, "--target=x86_64-apple-macos11", "-g", "-c", str(source), "-o", str(obj)])
            objects.append(str(obj))
        runtime = self.app / "Contents/MacOS/中文品牌"
        self.run_command(generation.fixture_link_command(runtime, objects))
        self.run_command([generation.DSYMUTIL, str(runtime), "-o", str(self.products / "static-runner.dSYM")])
        # Regenerate the receipt exactly as the real final Xcode phase does.
        inventory.write_inventory(self.build, self.app, "Release", ["spm"], [
            {"target": "example", "product": "example.framework", "source": "spm"}],
            [dict(package="Source", target="StaticPart", hosts=["runner"])])
        manifest = json.loads(self.prepare().read_text())
        debug = self.build / next(item["debug_file"] for item in manifest["artifacts"] if item["target"] == "runner")
        dwarfdump = generation.tool_path("llvm-dwarfdump") or shutil.which("dwarfdump")
        if dwarfdump:
            result = subprocess.run([dwarfdump, "--debug-info", str(debug)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0)
            self.assertIn("FixtureStaticPart.c", result.stdout)

    def test_live_g0_child_and_deadstripped_child_remain_unverified_not_missing(self):
        nm = generation.tool_path("llvm-nm") or (shutil.which("nm") if sys.platform == "darwin" else None)
        dwarfdump = generation.tool_path("llvm-dwarfdump") or shutil.which("dwarfdump")
        if not nm or not dwarfdump:
            self.skipTest("Mach-O nm/dwarfdump fixture tools unavailable")
        for live in (True, False):
            with self.subTest(live=live):
                static, main = self.root / "FixtureStaticG0.c", self.root / "FixtureHostG.c"
                static.write_text('__attribute__((noinline,visibility("hidden"))) int package_static_g0(int n) { return n * 7; }\n')
                main.write_text("int package_static_g0(int); int main(void) { return " + ("package_static_g0(3)" if live else "3") + "; }\n")
                objects = []
                for source, debug_flag in ((static, "-g0"), (main, "-g")):
                    obj = source.with_suffix(".o")
                    self.run_command([generation.CLANG, "--target=x86_64-apple-macos11", debug_flag, "-c", str(source), "-o", str(obj)])
                    objects.append(str(obj))
                runtime = self.app / "Contents/MacOS/中文品牌"
                command = generation.fixture_link_command(runtime, objects)
                command.append("-Wl,-dead_strip" if sys.platform == "darwin" else "-dead_strip")
                self.run_command(command)
                symbols = subprocess.run([nm, str(runtime)], check=True, capture_output=True, text=True).stdout
                self.assertEqual("_package_static_g0" in symbols, live)
                bundle = self.products / "g0-static-runner.dSYM"
                shutil.rmtree(bundle, ignore_errors=True)
                self.run_command([generation.DSYMUTIL, str(runtime), "-o", str(bundle)])
                inventory.write_inventory(self.build, self.app, "Release", ["spm"], [
                    {"target": "example", "product": "example.framework", "source": "spm"}],
                    [dict(package="Source", target="StaticG0", hosts=["runner"])])
                manifest = json.loads(self.prepare().read_text())
                debug = self.build / next(item["debug_file"] for item in manifest["artifacts"] if item["target"] == "runner")
                units = subprocess.run([dwarfdump, "--debug-info", str(debug)], check=True, capture_output=True, text=True).stdout
                self.assertIn("FixtureHostG.c", units)
                self.assertNotIn("FixtureStaticG0.c", units)
                limitation = next(item for item in manifest["limitations"] if item.get("target") == "StaticG0")
                self.assertEqual(limitation["reason"], inventory.SOURCE_LINE_LIMITATION)
                self.assertNotIn("missing", json.dumps(limitation))
                if generation.CLI:
                    import upload_sentry_symbols as upload
                    self.assertIn(limitation, upload.audit_macos(generation.CLI, self.build)[2])


@unittest.skipUnless(sys.platform == "darwin", "Swift object proof requires the real Apple SDK/compiler")
class DarwinLinkHelperObjectTests(unittest.TestCase):
    def test_real_empty_swift_library_object_has_no_executable_functions_or_positive_rows(self):
        from pick_sentry_symbolication_probe import dwarf_positive_line_rows, in_ranges, symbols
        with tempfile.TemporaryDirectory(prefix="sentry-empty-swift-") as temporary:
            root = Path(temporary).resolve()
            source = root / "Sources/LinkAnchor/Anchor.swift"
            source.parent.mkdir(parents=True)
            source.write_text("// No content needed; library link helper fixture.\n")
            (root / "Package.swift").write_text('''// swift-tools-version:5.3
import PackageDescription
let package = Package(name: "Fixture", products: [.library(name: "FixtureVendor", targets: ["VendorBinary", "LinkAnchor"])],
  targets: [.binaryTarget(name: "VendorBinary", path: "VendorBinary.xcframework"),
            .target(name: "LinkAnchor", linkerSettings: [.linkedLibrary("c++")])])
''')
            environment = inventory.manifest_environment(dict(os.environ), mode="host")
            contents = {False: "// No content needed; library link helper fixture.\n",
                        True: "public func positiveLinkHelper(_ n: Int) -> Int { return n + 7 }\n"}
            objects = {}
            for active in (False, True):
                source.write_text(contents[active])
                obj = root / ("active.o" if active else "empty.o")
                result = subprocess.run(["/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-O", "-g",
                                         "-emit-object", "-module-name", "LinkAnchor", str(source), "-o", str(obj)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60, env=environment)
                self.assertEqual(result.returncode, 0, "Swift fixture compilation failed")
                objects[active] = (obj, inventory.inspect_macho(obj)["variants"][0])
            # Construct the shared artifact before either subtest's assertions.
            # A primary inspection failure must not create a missing-artifact
            # error in the independent nonempty-source control.
            artifact = root / "VendorBinary.xcframework"
            variant = artifact / "selected-mac"
            variant.mkdir(parents=True)
            (variant / "VendorBinary.a").write_bytes(static_archive(objects[False][0].read_bytes()))
            (artifact / "Info.plist").write_bytes(plistlib.dumps(dict(CFBundlePackageType="XFWK", AvailableLibraries=[
                dict(LibraryIdentifier=variant.name, LibraryPath="VendorBinary.a", SupportedPlatform="macos",
                     SupportedArchitectures=[objects[False][1]["architecture"]])], XCFrameworkFormatVersion="1.0")))
            for active in (False, True):
                with self.subTest(active=active):
                    source.write_text(contents[active])
                    obj, item = objects[active]
                    self.assertEqual(item["filetype"], 1)
                    self.assertEqual(item["has_executable_text"], active)
                    ranges = [(section["addr"], section["addr"] + section["size"])
                              for section in item["sections"] if section["segment"] == "__TEXT"
                              and section["has_contents"] and section["size"] > 0
                              and (section["name"] == "__text" or section["flags"] & 0x80000400)]
                    self.assertEqual(bool(ranges), active)
                    outputs = []
                    for command in (["/usr/bin/xcrun", "nm", "-n", str(obj)],
                                    ["/usr/bin/xcrun", "dwarfdump", "--debug-line", str(obj)]):
                        result = subprocess.run(command, capture_output=True, text=True, timeout=30, env=environment)
                        self.assertEqual(result.returncode, 0, "Apple object inspection failed")
                        self.assertLess(len(result.stdout), 1024 * 1024)
                        outputs.append(result.stdout)
                    # nm's T label does not prove the address has instructions.
                    # Use the production picker's executable-range rule for
                    # both function entries and positive source-line PCs.
                    functions = [address for address, _ in symbols(outputs[0]) if in_ranges(address, ranges)]
                    rows = [address for address, _ in dwarf_positive_line_rows(outputs[1]) if in_ranges(address, ranges)]
                    self.assertEqual(bool(functions), active)
                    self.assertEqual(bool(rows), active)
                    # The runtime UUID is a fixture label, not an app claim.
                    graph = inventory.PackageGraph(root, root / "cache", [
                        dict(target="FixtureVendor", product="FixtureVendor.framework", variants=[
                            dict(architecture=item["architecture"], uuid=str(uuid.uuid4()))])], project_root=root.parent)
                    products, targets, _ = graph.collect([(root, "FixtureVendor")])
                    raw_target = next(value for value in graph.packages[root]["targets"] if value["name"] == "LinkAnchor")
                    self.assertEqual(inventory._helper_target_inputs(raw_target),
                                     ("Sources/LinkAnchor", None, [{"kind": "linkedLibrary", "value": "c++"}]))
                    self.assertEqual(bool(products), active)
                    self.assertEqual(bool(inventory.required_source_targets(targets)), active)
                    self.assertEqual("linker_only" in targets[0], not active)


class InventoryCliSafetyTests(unittest.TestCase):
    def test_production_main_keeps_default_host_xcrun_selection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            environment = {"CONFIGURATION": "Release", "PLATFORM_NAME": "macosx", "PROJECT_DIR": str(root / "macos"),
                           "FLUTTER_BUILD_DIR": "build", "TARGET_BUILD_DIR": str(root), "FULL_PRODUCT_NAME": "Fixture.app"}
            with mock.patch.dict(os.environ, environment, clear=True), mock.patch.object(inventory.sys, "platform", "darwin"), \
                 mock.patch.object(inventory, "collect_inventory") as collect, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(inventory.main(["--xcode-build"]), 0)
            self.assertNotIn("swift", collect.call_args.kwargs)

    def test_only_allowlisted_inventory_codes_are_printed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            environment = {"CONFIGURATION": "Release", "PLATFORM_NAME": "macosx", "PROJECT_DIR": str(root / "macos"),
                           "FLUTTER_BUILD_DIR": "build", "TARGET_BUILD_DIR": str(root), "FULL_PRODUCT_NAME": "Fixture.app"}
            for error, expected in ((inventory.InventoryError("unsupported_macos_package_target_dependency"), "unsupported_macos_package_target_dependency"),
                (inventory.InventoryError("private_token"), "macos_dependency_inventory_failed"),
                (RuntimeError("private-token /private/source"), "macos_dependency_inventory_failed"),
                (KeyError("private-token"), "macos_dependency_inventory_failed")):
                output = io.StringIO()
                with mock.patch.dict(os.environ, environment, clear=True), mock.patch.object(inventory.sys, "platform", "darwin"), \
                     mock.patch.object(inventory, "collect_inventory", side_effect=error), \
                     contextlib.redirect_stderr(output):
                    self.assertEqual(inventory.main(["--xcode-build"]), 1)
                self.assertEqual(output.getvalue().strip(), expected)
                self.assertNotIn("private", output.getvalue())



class CrispComposerGraphTests(unittest.TestCase):
    """0.4.0 target topology through the production inventory resolver.

    The manifest evaluator and final Mach-O discovery are substituted here;
    actual Xcode compilation and UUID matching are separate platform checks.
    """
    def test_both_brands_and_architectures_keep_composer_in_owning_dsym(self):
        manifest = (TOOL/'test/fixtures/desktop_webview_window_0_4_0/macos/desktop_webview_window/Package.swift').read_text(encoding='utf-8')
        self.assertIn('dependencies: ["desktop_webview_window_composer",', manifest)
        self.assertIn('.library(name: "desktop-webview-window", targets: ["desktop_webview_window"])', manifest)
        for brand in ('OmoFly', 'Daishu'):
            for arch in ('x86_64', 'arm64'):
                for dynamic in (False, True):
                    with self.subTest(brand=brand, arch=arch, dynamic=dynamic), tempfile.TemporaryDirectory() as tmp:
                        root = Path(tmp).resolve()
                        plugin, framework = root/'plugin', root/'FlutterFramework'
                        for directory in (plugin, framework):
                            directory.mkdir(); (directory/'Package.swift').write_text('// evaluated fixture')
                        values = {
                            plugin: package('desktop_webview_window', [library('desktop-webview-window', ['desktop_webview_window'])], [
                                target('desktop_webview_window', [
                                    {'byName': ['desktop_webview_window_composer', None]},
                                    {'product': ['FlutterFramework', 'FlutterFramework', None, None]}]),
                                target('desktop_webview_window_composer', publicHeadersPath='include'),
                            ], [SpmInventoryTests.local_dependency('FlutterFramework', framework)]),
                            framework: package('FlutterFramework', [library('FlutterFramework', ['FlutterFramework'])],
                                               [target('FlutterFramework', kind='system')]),
                        }
                        modules = [dict(target='runner', product=brand, architecture=arch)]
                        if dynamic: modules.append(dict(target='desktop_webview_window', product='desktop_webview_window.framework', architecture=arch))
                        graph = inventory.PackageGraph(plugin, root/'cache', modules)
                        with mock.patch.object(graph, 'dump', side_effect=lambda path: values[path]):
                            products, sources, binaries = graph.collect([(plugin, 'desktop-webview-window')])
                        expected = 'desktop_webview_window' if dynamic else 'runner'
                        owned = {row['target']: row['hosts'] for row in sources}
                        self.assertEqual(owned, {'desktop_webview_window': [expected], 'desktop_webview_window_composer': [expected]})
                        self.assertEqual(len(products), int(dynamic))
                        self.assertEqual(binaries, [])
                        # Missing transitive target is a failure, never silently
                        # declared covered merely because the wrapper exists.
                        values[plugin]['targets'].pop()
                        broken = inventory.PackageGraph(plugin, root/'cache', modules)
                        with mock.patch.object(broken, 'dump', side_effect=lambda path: values[path]):
                            with self.assertRaises(inventory.InventoryError):
                                broken.collect([(plugin, 'desktop-webview-window')])

if __name__ == "__main__":
    unittest.main()
