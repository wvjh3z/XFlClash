#!/usr/bin/env python3
"""Offline privacy-maintenance tests. No credentials, real events or network."""

from __future__ import annotations

from contextlib import redirect_stdout
import copy
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError


SCRIPT = Path(__file__).resolve().parents[1] / "configure_sentry_projects.py"
SPEC = importlib.util.spec_from_file_location("sentry_projects", SCRIPT)
maintenance = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(maintenance)
KEY = "a" * 32
TOKEN = "never-print-this-auth-token"
DSN = f"https://{KEY}@o123.ingest.us.sentry.io/456"


def project_settings(project="omofly", *, ready=True):
    return {
        "id": "456", "slug": project,
        "dataScrubber": ready, "dataScrubberDefaults": ready,
        "scrubIPAddresses": ready, "storeCrashReports": 0 if ready else 5,
        "sensitiveFields": list(maintenance.SENSITIVE_FIELDS) if ready else ["customBilling"],
        "safeFields": ["debug_id", "public_note"] if ready else ["email", "public_note"],
        "relayPiiConfig": '{"rules":{"custom-rule":{"type":"anything"}}}',
        "unrelatedSetting": {"retained": True},
    }


class FakeResponse:
    def __init__(self, url, body):
        self.url = url
        self.body = body

    def geturl(self):
        return self.url

    def read(self, limit):
        return self.body[:limit]

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False


class FakeOpener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        response = self.responses.pop(0)
        if isinstance(response, BaseException):
            raise response
        return FakeResponse(request.full_url, response)


class FakeClient:
    def __init__(self, *, ready=True):
        self.settings = {project: project_settings(project, ready=ready)
                         for project in maintenance.PROJECTS}
        self.calls = []
        self.probes = []
        self.ignore_updates = False
        self.raw_forbidden = False
        self.raw_not_found_count = 0

    def api(self, path, *, method="GET", payload=None, scope=None):
        self.calls.append((path, method, copy.deepcopy(payload)))
        project = next(project for project in maintenance.PROJECTS
                       if path.startswith(maintenance.project_path(project)))
        if method == "PUT":
            if not self.ignore_updates:
                self.settings[project].update(copy.deepcopy(payload))
            return copy.deepcopy(self.settings[project])
        if path.endswith("keys/?status=active"):
            return [{"isActive": True, "dsn": {"public": DSN, "secret": TOKEN}}]
        if "/events/" in path:
            if self.raw_forbidden:
                raise maintenance.SafeError("http_error", status=403,
                                            scope="event:read (and project access)")
            if self.raw_not_found_count:
                self.raw_not_found_count -= 1
                raise maintenance.SafeError("http_error", status=404)
            event = json.loads(self.probes[-1][2].decode().splitlines()[2])
            event["extra"] = {"token": "[Filtered]", "email": "[Filtered]", "uuid": "[Filtered]"}
            event["user"]["ip_address"] = None
            return event
        return copy.deepcopy(self.settings[project])

    def send_probe(self, endpoint, public_key, envelope):
        self.probes.append((endpoint, public_key, envelope))


class SettingsTests(unittest.TestCase):
    def test_merge_preserves_custom_fields_and_advanced_rules(self):
        original = project_settings(ready=False)
        original["safeFields"] += ["Authorization", "api_token", "UUID", "*", "debug_id"]
        untouched = copy.deepcopy(original)
        desired = maintenance.desired_settings(original)
        self.assertEqual(original, untouched)
        self.assertIn("customBilling", desired["sensitiveFields"])
        self.assertEqual(desired["safeFields"], ["public_note", "debug_id"])
        self.assertNotIn("relayPiiConfig", desired)
        self.assertEqual(set(desired), set(maintenance.FIXED_SETTINGS) | {"sensitiveFields", "safeFields"})

    def test_case_insensitive_merge_does_not_duplicate_sensitive_field(self):
        settings = project_settings()
        settings["sensitiveFields"][0] = "TOKEN"
        self.assertEqual(maintenance.desired_settings(settings)["sensitiveFields"],
                         settings["sensitiveFields"])

    def test_options_mirror_and_zero_are_supported(self):
        settings = project_settings()
        for field, option in maintenance.OPTION_KEYS.items():
            settings.setdefault("options", {})[option] = settings.pop(field)
        self.assertTrue(maintenance.safe_settings_report(settings)["privacy_ready"])

    def test_invalid_lists_fail_before_any_update(self):
        settings = project_settings()
        settings["safeFields"] = "*"
        with self.assertRaises(maintenance.SafeError):
            maintenance.desired_settings(settings)

    def test_audit_is_read_only_and_reports_missing_settings_as_failure(self):
        client = FakeClient(ready=False)
        result = maintenance.process_project(client, "omofly", "audit")
        self.assertFalse(result["ok"])
        self.assertFalse(result["privacy_ready"])
        self.assertEqual(len(client.calls), 1)
        self.assertEqual(client.probes, [])

    def test_apply_sends_minimal_payload_then_verifies_fresh_read(self):
        client = FakeClient(ready=False)
        original_relay = client.settings["omofly"]["relayPiiConfig"]
        result = maintenance.process_project(client, "omofly", "apply")
        self.assertTrue(result["ok"])
        self.assertTrue(result["settings_changed"])
        self.assertEqual([call[1] for call in client.calls], ["GET", "PUT", "GET"])
        self.assertNotIn("relayPiiConfig", client.calls[1][2])
        self.assertEqual(client.settings["omofly"]["relayPiiConfig"], original_relay)
        self.assertTrue(client.settings["omofly"]["unrelatedSetting"]["retained"])

    def test_apply_is_idempotent_and_never_rewrites_ready_project(self):
        client = FakeClient()
        result = maintenance.process_project(client, "omofly", "apply")
        self.assertTrue(result["ok"])
        self.assertFalse(result["settings_changed"])
        self.assertEqual([call[1] for call in client.calls], ["GET"])

    def test_put_success_without_actual_settings_change_is_not_a_pass(self):
        client = FakeClient(ready=False)
        client.ignore_updates = True
        result = maintenance.process_project(client, "omofly", "apply")
        self.assertFalse(result["ok"])
        self.assertFalse(result["privacy_ready"])

    def test_unknown_project_cannot_be_requested(self):
        client = maintenance.SentryClient(TOKEN, opener=FakeOpener([]))
        with self.assertRaises(maintenance.SafeError):
            client.api("/api/0/projects/another-org/private-project/")
        with self.assertRaises(maintenance.SafeError):
            maintenance.project_path("other")


class TransportTests(unittest.TestCase):
    def test_api_get_carries_bearer_only_to_exact_sentry_api_host(self):
        opener = FakeOpener([b"{}"])
        client = maintenance.SentryClient(TOKEN, opener=opener)
        client.api(maintenance.project_path("omofly"))
        self.assertEqual(opener.requests[0].get_header("Authorization"), f"Bearer {TOKEN}")
        self.assertEqual(opener.requests[0].host, "sentry.io")

    def test_regional_redirect_requires_exact_path_and_trusted_host(self):
        path = maintenance.project_path("omofly")
        redirect = HTTPError(maintenance.API_ROOT + path, 307, "redirect",
                             {"Location": "https://us.sentry.io" + path}, io.BytesIO())
        opener = FakeOpener([redirect, b"{}"])
        client = maintenance.SentryClient(TOKEN, opener=opener)
        client.api(path)
        self.assertEqual(opener.requests[1].host, "us.sentry.io")
        self.assertEqual(opener.requests[1].get_method(), "GET")

    def test_host_path_scheme_and_credentials_redirect_attacks_are_rejected(self):
        path = maintenance.project_path("omofly")
        for destination in (
            "https://attacker.invalid" + path,
            "https://sentry.io.attacker.invalid" + path,
            "https://us.sentry.io/other/",
            "http://sentry.io" + path,
            "https://user@sentry.io" + path,
            "https://sentry.io:444" + path,
        ):
            with self.subTest(destination=destination):
                redirect = HTTPError(maintenance.API_ROOT + path, 307, "redirect",
                                     {"Location": destination}, io.BytesIO(TOKEN.encode()))
                opener = FakeOpener([redirect])
                client = maintenance.SentryClient(TOKEN, opener=opener)
                with self.assertRaises(maintenance.SafeError) as captured:
                    client.api(path)
                self.assertEqual(captured.exception.code, "redirect_rejected")
                self.assertEqual(len(opener.requests), 1)
                self.assertNotIn(TOKEN, str(captured.exception))

    def test_cross_region_put_preserves_method_and_minimal_body(self):
        path = maintenance.project_path("omofly")
        redirect = HTTPError(maintenance.API_ROOT + path, 307, "redirect",
                             {"Location": "https://de.sentry.io" + path}, io.BytesIO())
        opener = FakeOpener([redirect, b"{}"])
        client = maintenance.SentryClient(TOKEN, opener=opener)
        client.api(path, method="PUT", payload={"dataScrubber": True})
        self.assertEqual(opener.requests[1].get_method(), "PUT")
        self.assertEqual(opener.requests[1].data, opener.requests[0].data)

    def test_only_fixed_project_settings_and_synthetic_event_routes_are_allowed(self):
        client = maintenance.SentryClient(TOKEN, opener=FakeOpener([]))
        for suffix in ("../../organizations/", "events/", "issues/", "keys/?status=inactive"):
            with self.subTest(suffix=suffix), self.assertRaises(maintenance.SafeError):
                client.api(maintenance.project_path("omofly") + suffix)
        with self.assertRaises(maintenance.SafeError):
            client.api(maintenance.project_path("omofly") + "keys/?status=active", method="PUT")

    def test_http_failure_does_not_expose_body_token_or_reason(self):
        path = maintenance.project_path("omofly")
        opener = FakeOpener([HTTPError(maintenance.API_ROOT + path, 403, TOKEN, {},
                                      io.BytesIO((TOKEN + DSN).encode()))])
        result = maintenance.process_project(maintenance.SentryClient(TOKEN, opener=opener),
                                             "omofly", "audit")
        self.assertEqual(result["http_status"], 403)
        self.assertEqual(result["required_scope"], "project:read")
        self.assertNotIn(TOKEN, json.dumps(result))
        self.assertNotIn(DSN, json.dumps(result))

    def test_invalid_json_is_a_safe_failure_without_response_content(self):
        opener = FakeOpener([(TOKEN + DSN).encode()])
        result = maintenance.process_project(maintenance.SentryClient(TOKEN, opener=opener),
                                             "omofly", "audit")
        self.assertEqual(result["error"], "invalid_json_response")
        self.assertNotIn(TOKEN, json.dumps(result))
        self.assertNotIn(DSN, json.dumps(result))

    def test_oversize_response_fails_before_parsing_or_reporting_body(self):
        opener = FakeOpener([b"x" * (maintenance.MAX_RESPONSE_BYTES + 1)])
        result = maintenance.process_project(maintenance.SentryClient(TOKEN, opener=opener),
                                             "omofly", "audit")
        self.assertEqual(result["error"], "response_too_large")

    def test_ingest_never_receives_management_bearer_or_follows_redirect(self):
        endpoint, key = maintenance.parse_public_dsn(DSN, "456")
        opener = FakeOpener([b"{}"])
        client = maintenance.SentryClient(TOKEN, opener=opener)
        client.send_probe(endpoint, key, b"synthetic envelope")
        request = opener.requests[0]
        self.assertIsNone(request.get_header("Authorization"))
        self.assertNotIn(TOKEN, str(request.header_items()))
        self.assertEqual(request.host, "o123.ingest.us.sentry.io")
        redirect = HTTPError(endpoint, 307, "redirect", {"Location": endpoint}, io.BytesIO())
        redirected = FakeOpener([redirect])
        client = maintenance.SentryClient(TOKEN, opener=redirected)
        with self.assertRaises(maintenance.SafeError):
            client.send_probe(endpoint, key, b"synthetic envelope")
        self.assertEqual(len(redirected.requests), 1)

    def test_untrusted_or_wrong_project_dsn_is_rejected(self):
        for dsn in (
            DSN.replace("https:", "http:"),
            DSN.replace("sentry.io", "sentry.io.attacker.invalid"),
            DSN.replace("/456", "/789"),
            DSN + "?leak=1", DSN + "#fragment",
            DSN.replace(KEY + "@", KEY + ":password@"),
        ):
            with self.subTest(dsn=dsn), self.assertRaises(maintenance.SafeError):
                maintenance.parse_public_dsn(dsn, "456")


class ProbeTests(unittest.TestCase):
    def test_probe_contains_only_synthetic_markers_and_preserves_debug_identifier(self):
        event_id, markers, debug_id, envelope = maintenance.make_probe()
        event = json.loads(envelope.decode().splitlines()[2])
        self.assertEqual(event["level"], "info")
        self.assertEqual(event["environment"], "sentry-deployment-check")
        self.assertNotIn(TOKEN, envelope.decode())
        self.assertNotEqual(markers[2], debug_id)
        event["extra"] = {"token": "[Filtered]", "email": "[Filtered]", "uuid": "[Filtered]"}
        event["user"]["ip_address"] = None
        report = maintenance.check_probe(event, event_id, markers, debug_id)
        self.assertTrue(report["probe_verified"])
        self.assertEqual(report["probe_scrubbed_marker_count"], 4)
        for marker in markers:
            self.assertNotIn(marker, json.dumps(report))
        self.assertNotIn(debug_id, json.dumps(report))

    def test_unscrubbed_marker_or_lost_native_debug_id_fails_verification(self):
        event_id, markers, debug_id, envelope = maintenance.make_probe()
        event = json.loads(envelope.decode().splitlines()[2])
        self.assertFalse(maintenance.check_probe(event, event_id, markers, debug_id)["probe_verified"])
        event["extra"] = {}
        event["user"] = {}
        event["debug_meta"] = {}
        report = maintenance.check_probe(event, event_id, markers, debug_id)
        self.assertEqual(report["probe_scrubbed_marker_count"], 4)
        self.assertFalse(report["debug_identifier_preserved"])
        self.assertFalse(report["probe_verified"])

    def test_unknown_event_is_never_accepted(self):
        event_id, markers, debug_id, envelope = maintenance.make_probe()
        event = json.loads(envelope.decode().splitlines()[2])
        event["event_id"] = "0" * 32
        with self.assertRaises(maintenance.SafeError):
            maintenance.check_probe(event, event_id, markers, debug_id)

    def test_verify_reads_only_the_generated_event_and_polls_transient_404(self):
        client = FakeClient()
        client.raw_not_found_count = 2
        sleeps = []
        report = maintenance.verify_probe(client, "omofly", client.settings["omofly"],
                                           sleep=sleeps.append)
        self.assertTrue(report["probe_verified"])
        self.assertEqual(sleeps, [5, 5])
        self.assertEqual(len(client.probes), 1)
        event = json.loads(client.probes[0][2].decode().splitlines()[2])
        event_paths = [call[0] for call in client.calls if "/events/" in call[0]]
        self.assertEqual(event_paths, [maintenance.project_path("omofly")
                                       + f"events/{event['event_id']}/json/"] * 3)

    def test_verification_requires_confirmed_privacy_settings_before_any_probe(self):
        client = FakeClient(ready=False)
        report = maintenance.process_project(client, "omofly", "verify")
        self.assertFalse(report["ok"])
        self.assertEqual(report["error"], "privacy_settings_not_ready")
        self.assertEqual(client.probes, [])

    def test_permission_failure_is_explicit_and_not_retried(self):
        client = FakeClient()
        client.raw_forbidden = True
        report = maintenance.process_project(client, "omofly", "verify")
        self.assertFalse(report["ok"])
        self.assertEqual(report["http_status"], 403)
        self.assertIn("event:read", report["required_scope"])
        self.assertEqual(len([call for call in client.calls if "/events/" in call[0]]), 1)

    def test_probe_timeout_is_bounded_and_never_reports_delivery_as_success(self):
        client = FakeClient()
        client.raw_not_found_count = 20
        sleeps = []
        with self.assertRaises(maintenance.SafeError) as captured:
            maintenance.verify_probe(client, "omofly", client.settings["omofly"],
                                     attempts=3, sleep=sleeps.append)
        self.assertEqual(captured.exception.code, "probe_not_received_before_timeout")
        self.assertEqual(sleeps, [5, 5])
        self.assertEqual(len(client.probes), 1)

    def test_apply_and_verify_reports_only_safe_flags_and_counts(self):
        client = FakeClient(ready=False)
        result = maintenance.process_project(client, "omofly", "apply-and-verify")
        self.assertTrue(result["ok"])
        serialized = json.dumps(result)
        self.assertNotIn(DSN, serialized)
        self.assertNotIn(TOKEN, serialized)
        self.assertNotIn("customBilling", serialized)
        self.assertNotIn("custom-rule", serialized)


class CommandTests(unittest.TestCase):
    def test_missing_token_is_safe_and_does_not_build_opener(self):
        output = io.StringIO()
        with patch.dict(maintenance.os.environ, {}, clear=True), \
                patch.object(maintenance, "build_opener") as opener, redirect_stdout(output):
            self.assertEqual(maintenance.main([]), 1)
        opener.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())["error"], "missing_or_invalid_auth_token")

    def test_default_mode_is_audit_for_both_fixed_projects_and_safe_artifact(self):
        client = FakeClient()
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            with patch.dict(maintenance.os.environ, {"SENTRY_AUTH_TOKEN": TOKEN}), \
                    patch.object(maintenance, "SentryClient", return_value=client), \
                    redirect_stdout(output):
                self.assertEqual(maintenance.main(["--report", str(report)]), 0)
            self.assertEqual(output.getvalue(), report.read_text(encoding="utf-8"))
        result = json.loads(output.getvalue())
        self.assertEqual(result["mode"], "audit")
        self.assertEqual([item["project"] for item in result["projects"]], list(maintenance.PROJECTS))
        self.assertTrue(all(call[1] == "GET" for call in client.calls))
        self.assertEqual(client.probes, [])
        self.assertNotIn(TOKEN, output.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
