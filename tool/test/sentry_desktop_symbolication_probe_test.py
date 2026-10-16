#!/usr/bin/env python3
"""Offline safety and symbolication-result checks; never sends an event."""

import argparse
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sentry_desktop_symbolication_probe as probe


class ProbeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.binary, self.symbols = self.root / "app", self.root / "app.debug"
        self.binary.write_bytes(b"final-build-module")
        self.symbols.write_bytes(b"same-build-debug-companion")
        self.identifier = "12345678-1234-5678-1234-567812345678"
        self.evidence_path = self.root / "evidence.json"
        self.evidence = {"schema_version": 1, "status": "uploaded_and_processed",
            "platform": "linux", "flavor": "brand_a", "native": [{
                "target": "FlClash", "architecture": "x64", "format": "elf",
                "debug_ids": [self.identifier], "build_id": "aa" * 20,
                "binary": probe.fingerprint(self.binary), "symbols": probe.fingerprint(self.symbols)}]}
        self.args = argparse.Namespace(evidence=self.evidence_path, selection=None,
            build_root=self.root, binary=self.binary, symbols=self.symbols,
            target="FlClash", architecture="x86_64", relative_address="0x1234",
            image_size="0x2000", image_vmaddr="0x0", expected_function="native_function",
            expected_file="native_source.cpp", expected_line=17)
        self.save_evidence()

    def save_evidence(self):
        self.evidence_path.write_text(json.dumps(self.evidence))

    def report(self):
        report = probe.make_report(self.args)
        report.update(status="sent", sent=True)
        return report

    def event(self, report):
        event = probe.make_event(report)
        frame = event["exception"]["values"][0]["stacktrace"]["frames"][0]
        frame.update(function="Namespace::native_function()", filename="/private/source/native_source.cpp", lineno=17)
        return event

    def test_request_does_not_contain_expected_location_or_private_paths(self):
        report = self.report()
        payload = json.dumps(probe.make_event(report))
        for forbidden in ("native_function", "native_source.cpp", str(self.root), '"lineno"', '"function"'):
            self.assertNotIn(forbidden, payload)
        self.assertFalse(report["native_crash_test"])
        self.assertFalse(report["device_capture_verified"])
        # Receiving the identical unsymbolicated address event is insufficient.
        self.assertFalse(probe.check_event(probe.make_event(report), report)["server_symbolication_verified"])

    def test_file_hashes_and_successful_upload_are_mandatory(self):
        self.evidence["status"] = "audited"
        self.save_evidence()
        with self.assertRaises(probe.SafeError):
            self.report()
        self.evidence["status"] = "uploaded_and_processed"
        self.save_evidence()
        self.binary.write_bytes(b"different-build")
        with self.assertRaises(probe.SafeError):
            self.report()

    def test_selection_binds_module_metadata_and_artifacts(self):
        selected = {"schema_version": 1, "platform": "linux", "module": {
            "target": "FlClash", "architecture": "x86_64", "debug_id": self.identifier,
            "code_file": "app", "debug_file": "app.debug", "image_size": 8192,
            "image_vmaddr": "0x400000", "binary_path": "app", "symbols_path": "app.debug"},
            "frame": {"addr_mode": "rel:0", "instruction_addr": "0x1234"},
            "expected": {"function": "native_function", "filename": "native_source.cpp", "lineno": 17}}
        self.args.selection = self.root / "selection.json"
        self.args.selection.write_text(json.dumps(selected))
        report = self.report()
        self.assertEqual(report["image"]["image_vmaddr"], "0x400000")
        self.assertEqual(report["instruction_address"], hex(probe.IMAGE_ADDRESS + 0x1234))
        selected["module"]["binary_path"] = "../outside"
        self.args.selection.write_text(json.dumps(selected))
        with self.assertRaises(probe.SafeError):
            self.report()

    def test_windows_and_macos_use_correct_debug_image_types(self):
        for platform, fmt, image_type in (("windows", "pdb", "pe"), ("macos", "dsym", "macho")):
            with self.subTest(platform=platform):
                self.evidence["platform"] = platform
                self.evidence["native"][0]["format"] = fmt
                self.save_evidence()
                report = self.report()
                self.assertEqual(report["image"]["type"], image_type)
                self.assertEqual(report["image"]["debug_id"], self.identifier)

    def test_server_resolved_function_file_line_and_module_are_required(self):
        report = self.report()
        event = self.event(report)
        self.assertTrue(probe.check_event(event, report)["server_symbolication_verified"])
        frame = event["exception"]["values"][0]["stacktrace"]["frames"][0]
        for field, value in (("function", "other_function"), ("filename", "other.cpp"),
                             ("lineno", None), ("lineno", 0), ("lineno", 18), ("instruction_addr", "0x22")):
            with self.subTest(field=field, value=value):
                modified = copy.deepcopy(event)
                modified["exception"]["values"][0]["stacktrace"]["frames"][0][field] = value
                self.assertFalse(probe.check_event(modified, report)["server_symbolication_verified"])
        event["debug_meta"]["images"][0]["debug_id"] = "87654321-1234-5678-1234-567812345678"
        self.assertFalse(probe.check_event(event, report)["server_symbolication_verified"])

    def swift_report(self):
        self.evidence["platform"] = "macos"
        self.evidence["native"][0].update(target="runner", architecture="arm64", format="dsym")
        self.args.target, self.args.architecture = "runner", "arm64"
        self.args.relative_address, self.args.image_size, self.args.image_vmaddr = "0x2a18", 3883008, "0x100000000"
        self.args.expected_function = "MainFlutterWindow.awakeFromNib()"
        self.args.expected_file, self.args.expected_line = "MainFlutterWindow.swift", 7
        self.save_evidence()
        return self.report()

    @staticmethod
    def swift_event(report, function="MainFlutterWindow.awakeFromNib"):
        # Shape observed in the read-only projection of our ARM probe: the
        # exact address/file/line/image survived, and only empty () was omitted.
        event = probe.make_event(report)
        frame = event["exception"]["values"][0]["stacktrace"]["frames"][0]
        frame.update(function=function, filename="MainFlutterWindow.swift", lineno=7)
        return event

    def test_macos_swift_name_only_real_frame_shape_passes_check_and_verify(self):
        report = self.swift_report()
        event = self.swift_event(report)
        result = probe.check_event(event, report)
        self.assertTrue(result["server_symbolication_verified"])
        self.assertEqual(result["resolved_expected_frame_count"], 1)
        client = mock.Mock()
        client.api.return_value = event
        probe.verify(report, attempts=1, interval=0, client=client)
        client.api.assert_called_once_with(probe.project_path("omofly") + "events/" + report["event_id"] + "/json/", scope="event:read")
        self.assertEqual(report["status"], "verified")
        self.assertFalse(report["native_crash_test"] or report["device_capture_verified"])
        # Existing exact-substring behavior remains the first branch.
        self.assertTrue(probe.check_event(self.swift_event(report, "Module.MainFlutterWindow.awakeFromNib()"), report)
                        ["server_symbolication_verified"])

    def test_swift_name_only_fallback_never_matches_approximate_or_parameter_names(self):
        report = self.swift_report()
        observed = ("MainFlutterWindow.otherMethod", "OtherMainFlutterWindow.awakeFromNib",
                    "Other.MainFlutterWindow.awakeFromNib", "MainFlutterWindow.awakeFromNibExtra",
                    "MainFlutterWindow.awakeFromNib.extra", "MainFlutterWindow.awakeFromNib ",
                    "MainFlutterWindow.awakeFromNib(_:)", "MainFlutterWindow.awakeFromNib(Int)",
                    "MainFlutterWindow.awakeFromNib<T>", "@objc MainFlutterWindow.awakeFromNib", None)
        for function in observed:
            with self.subTest(function=function):
                event = self.swift_event(report, function)
                self.assertFalse(probe.check_event(event, report)["server_symbolication_verified"])
                client = mock.Mock()
                client.api.return_value = event
                with self.assertRaisesRegex(probe.SafeError, "server_symbolication_not_verified_before_timeout"):
                    probe.verify(copy.deepcopy(report), attempts=1, interval=0, client=client)
                client.api.assert_called_once()

    def test_swift_name_only_fallback_requires_macos_swift_and_dotted_empty_signature(self):
        baseline = self.swift_report()
        cases = [("linux", "MainFlutterWindow.swift", "MainFlutterWindow.awakeFromNib()", "MainFlutterWindow.awakeFromNib"),
                 ("windows", "MainFlutterWindow.swift", "MainFlutterWindow.awakeFromNib()", "MainFlutterWindow.awakeFromNib"),
                 ("macos", "MainFlutterWindow.cpp", "MainFlutterWindow.awakeFromNib()", "MainFlutterWindow.awakeFromNib"),
                 ("macos", "MainFlutterWindow.SWIFT", "MainFlutterWindow.awakeFromNib()", "MainFlutterWindow.awakeFromNib"),
                 ("macos", "MainFlutterWindow.swift", "awakeFromNib()", "awakeFromNib"),
                 ("macos", "MainFlutterWindow.swift", "MainFlutterWindow.awakeFromNib(_:)", "MainFlutterWindow.awakeFromNib"),
                 ("macos", "MainFlutterWindow.swift", "MainFlutterWindow.awakeFromNib(Int)", "MainFlutterWindow.awakeFromNib"),
                 ("macos", "MainFlutterWindow.swift", "MainFlutterWindow<T>.awakeFromNib()", "MainFlutterWindow<T>.awakeFromNib"),
                 ("macos", "MainFlutterWindow.swift", "MainFlutterWindow. awakeFromNib()", "MainFlutterWindow. awakeFromNib"),
                 ("macos", "MainFlutterWindow.swift", "MainFlutterWïndow.awakeFromNib()", "MainFlutterWïndow.awakeFromNib")]
        for platform, filename, expected, function in cases:
            with self.subTest(platform=platform, filename=filename, expected=expected):
                report = copy.deepcopy(baseline)
                report["platform"] = platform
                report["image"]["type"] = probe.IMAGE_TYPES[probe.FORMATS[platform]]
                report["expected"].update(function_contains=expected, file_basename=filename)
                probe.validate_report(report)
                event = self.swift_event(report, function)
                event["exception"]["values"][0]["stacktrace"]["frames"][0]["filename"] = filename
                self.assertFalse(probe.check_event(event, report)["server_symbolication_verified"])

    def test_swift_name_only_does_not_relax_address_file_line_uuid_arch_or_image_guards(self):
        report = self.swift_report()
        event = self.swift_event(report)
        for field, value in (("instruction_addr", "0x100002a19"), ("filename", "Other.swift"),
                             ("lineno", 8), ("lineno", 0), ("lineno", None)):
            modified = copy.deepcopy(event)
            modified["exception"]["values"][0]["stacktrace"]["frames"][0][field] = value
            self.assertFalse(probe.check_event(modified, report)["server_symbolication_verified"])
        for field, value in (("debug_id", "87654321-1234-5678-1234-567812345678"), ("arch", "x86_64"),
                             ("image_addr", "0x100001000"), ("type", "elf"), ("code_file", "OtherApp")):
            modified = copy.deepcopy(event)
            modified["debug_meta"]["images"][0][field] = value
            self.assertFalse(probe.check_event(modified, report)["server_symbolication_verified"])

    def test_line_zero_requires_server_line_greater_than_zero(self):
        self.args.expected_line = 0
        report = self.report()
        event = self.event(report)
        self.assertTrue(probe.check_event(event, report)["server_symbolication_verified"])
        event["exception"]["values"][0]["stacktrace"]["frames"][0]["lineno"] = None
        self.assertFalse(probe.check_event(event, report)["server_symbolication_verified"])

    def test_own_event_identity_and_project_allowlist(self):
        report = self.report()
        for key, value in (("organization", "other-org"), ("project", "other-project"),
                           ("event_id", "../../other"), ("native_crash_test", True)):
            modified = {**report, key: value}
            with self.assertRaises(probe.SafeError):
                probe.validate_report(modified)
        event = self.event(report)
        event["tags"]["xflclash.probe_id"] = "another-id"
        with self.assertRaises(probe.SafeError):
            probe.check_event(event, report)

    def test_verify_reads_only_own_event_and_saves_no_server_body(self):
        report = self.report()
        event = self.event(report)
        event["user"] = {"email": "real-user-data-must-never-be-saved"}
        client = mock.Mock()
        client.api.return_value = event
        probe.verify(report, attempts=1, interval=1, client=client)
        client.api.assert_called_once_with(probe.project_path("omofly") + "events/" + report["event_id"] + "/json/", scope="event:read")
        self.assertEqual(report["status"], "verified")
        self.assertNotIn("real-user-data", json.dumps(report))

    def test_upload_token_cannot_replace_maintenance_token(self):
        with mock.patch.dict(probe.os.environ, {"SENTRY_AUTH_TOKEN": "upload-token-only"}, clear=True):
            with self.assertRaises(probe.SafeError) as error:
                probe.verify(self.report(), attempts=1, interval=1)
        self.assertEqual(error.exception.code, "maintenance_token_environment_required")

    def test_emit_uses_only_public_ingest_auth_from_prod_defines(self):
        defines = self.root / "defines.json"
        defines.write_text(json.dumps({"XB_FLAVOR_ID": "brand_a", "XB_DEBUG": "false",
            "XB_SENTRY_DSN": "https://" + "a" * 32 + "@o123.ingest.us.sentry.io/456"}))
        response = mock.MagicMock()
        response.__enter__.return_value.geturl.return_value = "https://o123.ingest.us.sentry.io/api/456/envelope/"
        opener = mock.Mock()
        opener.open.return_value = response
        with mock.patch.dict(probe.os.environ, {"SENTRY_AUTH_TOKEN": "upload-secret",
                                               "SENTRY_MAINTENANCE_TOKEN": "maintenance-secret"}):
            probe.send_event(defines, self.report(), opener=opener)
        request = opener.open.call_args.args[0]
        serialized = str(request.headers) + request.data.decode()
        self.assertNotIn("Authorization", request.headers)
        self.assertNotIn("upload-secret", serialized)
        self.assertNotIn("maintenance-secret", serialized)
        self.assertNotIn("native_function", serialized)

    def test_existing_report_prevents_duplicate_event(self):
        report_path = self.root / "report.json"
        report_path.write_text("existing-report")
        with mock.patch.object(probe, "send_event") as send, mock.patch("sys.stderr"):
            result = probe.main(["emit", "--evidence", str(self.evidence_path), "--defines", "unused",
                                 "--report", str(report_path)])
        self.assertEqual(result, 1)
        send.assert_not_called()
        self.assertEqual(report_path.read_text(), "existing-report")

    def test_unknown_or_malformed_fields_never_reach_safe_output(self):
        report_path, output = self.root / "input.json", self.root / "safe-output.json"
        secret = "accidentally-pasted-maintenance-secret"
        for modify in (
            lambda report: report.update(token=secret),
            lambda report: report.update(created_at=secret),
            lambda report: report["binary"].update(bytes=secret),
            lambda report: report["expected"].update(token=secret),
            lambda report: report.update(error={"code": secret}),
            lambda report: report.update(verification={"raw_response": secret}),
        ):
            report = self.report()
            modify(report)
            raw = json.dumps(report)
            report_path.write_text(raw)
            with mock.patch.object(probe, "verify") as verify, mock.patch("sys.stderr"):
                result = probe.main(["verify", "--report", str(report_path), "--output", str(output)])
            self.assertEqual(result, 1)
            verify.assert_not_called()
            self.assertNotIn(secret, output.read_text())
            self.assertEqual(report_path.read_text(), raw)

    def test_safe_projection_discards_input_summaries(self):
        report = self.report()
        report.update(error={"code": "old_failure"}, verification={"probe_received": True,
            "debug_image_matches_uploaded_module": True, "server_symbolication_verified": True,
            "resolved_expected_frame_count": 1}, verified_at=report["created_at"])
        projected = probe.safe_report(report)
        self.assertNotIn("error", projected)
        self.assertNotIn("verification", projected)
        self.assertNotIn("verified_at", projected)


if __name__ == "__main__":
    unittest.main()
