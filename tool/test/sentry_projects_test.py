#!/usr/bin/env python3
"""Offline raw-log maintenance tests. No credentials, real events or network."""

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
        "dataScrubber": not ready, "dataScrubberDefaults": not ready,
        "scrubIPAddresses": not ready, "storeCrashReports": -1 if ready else 0,
        "sensitiveFields": ["token", "email", "customBilling"],
        "safeFields": ["email", "public_note"],
        "relayPiiConfig": None if ready else '{"rules":{"custom-rule":{"type":"anything"}},"applications":{"$string":["custom-rule"]}}',
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
        self.scrub_probe = False

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
            if self.scrub_probe:
                event["extra"] = {"token": "[Filtered]", "email": "[Filtered]", "uuid": "[Filtered]"}
                event["user"]["ip_address"] = None
            return event
        return copy.deepcopy(self.settings[project])

    def send_probe(self, endpoint, public_key, envelope):
        self.probes.append((endpoint, public_key, envelope))


class SettingsTests(unittest.TestCase):
    def test_minimal_update_preserves_sensitive_safe_and_unrelated_fields(self):
        original = project_settings(ready=False)
        untouched = copy.deepcopy(original)
        desired = maintenance.desired_settings(original)
        self.assertEqual(original, untouched)
        self.assertEqual(desired, {**maintenance.FIXED_SETTINGS, "relayPiiConfig": ""})
        self.assertNotIn("sensitiveFields", desired)
        self.assertNotIn("safeFields", desired)
        self.assertNotIn("unrelatedSetting", desired)

    def test_already_matching_fields_are_not_rewritten(self):
        settings = project_settings()
        settings["scrubIPAddresses"] = True
        self.assertEqual(maintenance.desired_settings(settings), {"scrubIPAddresses": False})

    def test_options_mirror_and_minus_one_are_supported(self):
        settings = project_settings()
        for field, option in maintenance.OPTION_KEYS.items():
            settings.setdefault("options", {})[option] = settings.pop(field)
        self.assertTrue(maintenance.safe_settings_report(settings)["raw_logging_ready"])

    def test_boolean_zero_and_crash_boolean_cannot_falsely_satisfy_settings(self):
        settings = project_settings()
        settings["dataScrubber"] = 0
        settings["storeCrashReports"] = True
        report = maintenance.safe_settings_report(settings)
        self.assertFalse(report["raw_logging_ready"])
        self.assertFalse(report["data_scrubber_disabled"])
        self.assertFalse(report["raw_crash_storage_unlimited"])

    def test_omitted_advanced_rules_field_is_not_evidence_that_rules_are_disabled(self):
        settings = project_settings()
        del settings["relayPiiConfig"]
        self.assertFalse(maintenance.safe_settings_report(settings)["raw_logging_ready"])
        self.assertEqual(maintenance.desired_settings(settings), {"relayPiiConfig": ""})

    def test_null_and_blank_advanced_rules_are_disabled_but_json_rules_are_cleared(self):
        for value in (None, "", "  ", "\n"):
            with self.subTest(value=value):
                settings = project_settings()
                settings["relayPiiConfig"] = value
                self.assertTrue(maintenance.safe_settings_report(settings)["raw_logging_ready"])
                self.assertEqual(maintenance.desired_settings(settings), {})
        for value in ('{"applications":{"$string":["@email:replace"]}}', '{}', {"rules": {}}):
            with self.subTest(value=value):
                settings["relayPiiConfig"] = value
                self.assertFalse(maintenance.safe_settings_report(settings)["raw_logging_ready"])
                # None is deliberately not used: Sentry's writer treats it as no update.
                self.assertEqual(maintenance.desired_settings(settings), {"relayPiiConfig": ""})

    def test_audit_is_read_only_and_reports_missing_settings_as_failure(self):
        client = FakeClient(ready=False)
        result = maintenance.process_project(client, "omofly", "audit")
        self.assertFalse(result["ok"])
        self.assertFalse(result["raw_logging_ready"])
        self.assertEqual(len(client.calls), 1)
        self.assertEqual(client.probes, [])

    def test_apply_clears_active_advanced_rules_and_verifies_fresh_read(self):
        client = FakeClient(ready=False)
        original = copy.deepcopy(client.settings["omofly"])
        result = maintenance.process_project(client, "omofly", "apply")
        self.assertTrue(result["ok"])
        self.assertTrue(result["settings_changed"])
        self.assertEqual([call[1] for call in client.calls], ["GET", "PUT", "GET"])
        self.assertEqual(client.calls[1][2], {**maintenance.FIXED_SETTINGS, "relayPiiConfig": ""})
        self.assertEqual(client.settings["omofly"]["relayPiiConfig"], "")
        for field in ("sensitiveFields", "safeFields", "unrelatedSetting"):
            self.assertEqual(client.settings["omofly"][field], original[field])
        self.assertEqual(client.probes, [])

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
        self.assertFalse(result["raw_logging_ready"])

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
    def test_probe_contains_only_synthetic_markers_and_preserves_all_four_raw_values(self):
        event_id, markers, debug_id, envelope = maintenance.make_probe()
        event = json.loads(envelope.decode().splitlines()[2])
        self.assertEqual(event["level"], "info")
        self.assertEqual(event["environment"], "sentry-deployment-check")
        self.assertNotIn(TOKEN, envelope.decode())
        self.assertNotEqual(markers[2], debug_id)
        self.assertEqual(markers, ("deployment-only-token-" + event_id,
                                  "deployment-" + event_id + "@example.invalid",
                                  str(maintenance.uuid.UUID(event_id)), "192.0.2.1"))
        report = maintenance.check_probe(event, event_id, markers, debug_id)
        self.assertTrue(report["probe_verified"])
        self.assertEqual(report["probe_preserved_marker_count"], 4)
        for marker in markers:
            self.assertNotIn(marker, json.dumps(report))
        self.assertNotIn(debug_id, json.dumps(report))

    def test_each_scrubbed_or_missing_marker_fails_and_cannot_pass_by_appearing_elsewhere(self):
        event_id, markers, debug_id, envelope = maintenance.make_probe()
        original = json.loads(envelope.decode().splitlines()[2])
        for field, marker in zip(("token", "email", "uuid", "ip_address"), markers):
            with self.subTest(field=field):
                event = copy.deepcopy(original)
                event["user" if field == "ip_address" else "extra"][field] = "[Filtered]"
                event["extra"]["somewhere_else"] = marker
                report = maintenance.check_probe(event, event_id, markers, debug_id)
                self.assertEqual(report["probe_preserved_marker_count"], 3)
                self.assertFalse(report["probe_verified"])

    def test_lost_native_debug_identifier_fails_even_with_all_raw_markers(self):
        event_id, markers, debug_id, envelope = maintenance.make_probe()
        event = json.loads(envelope.decode().splitlines()[2])
        event["debug_meta"] = {}
        report = maintenance.check_probe(event, event_id, markers, debug_id)
        self.assertEqual(report["probe_preserved_marker_count"], 4)
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

    def test_verification_requires_confirmed_raw_settings_before_any_probe(self):
        client = FakeClient(ready=False)
        report = maintenance.process_project(client, "omofly", "verify")
        self.assertFalse(report["ok"])
        self.assertEqual(report["error"], "raw_logging_settings_not_ready")
        self.assertEqual(client.probes, [])

    def test_permission_failure_preserves_generated_probe_ids_without_retry(self):
        client = FakeClient()
        client.raw_forbidden = True
        report = maintenance.process_project(client, "omofly", "verify")
        self.assertFalse(report["ok"])
        self.assertEqual(report["http_status"], 403)
        self.assertIn("event:read", report["required_scope"])
        self.assertEqual(len([call for call in client.calls if "/events/" in call[0]]), 1)
        self.assertTrue(report["probe_sent"])
        event = json.loads(client.probes[0][2].decode().splitlines()[2])
        self.assertEqual(report["probe_event_id"], event["event_id"])
        self.assertEqual(report["probe_debug_id"], event["debug_meta"]["images"][0]["debug_id"])

    def test_probe_timeout_is_bounded_and_never_reports_delivery_as_success(self):
        client = FakeClient()
        client.raw_not_found_count = 20
        sleeps = []
        report = {}
        with self.assertRaises(maintenance.SafeError) as captured:
            maintenance.verify_probe(client, "omofly", client.settings["omofly"],
                                     attempts=3, sleep=sleeps.append, report=report)
        self.assertEqual(captured.exception.code, "probe_not_received_before_timeout")
        self.assertEqual(sleeps, [5, 5])
        self.assertEqual(len(client.probes), 1)
        self.assertTrue(report["probe_sent"])
        self.assertRegex(report["probe_event_id"], r"^[0-9a-f]{32}$")
        self.assertRegex(report["probe_debug_id"], r"^[0-9a-f-]+-1$")

    def test_organization_or_propagation_scrubbing_is_an_explicit_probe_failure(self):
        client = FakeClient()
        client.scrub_probe = True
        result = maintenance.process_project(client, "omofly", "verify")
        self.assertTrue(result["raw_logging_ready"])
        self.assertEqual(result["probe_preserved_marker_count"], 0)
        self.assertFalse(result["probe_verified"])
        self.assertFalse(result["ok"])
        self.assertEqual(len(client.probes), 1)

    def test_apply_and_verify_reports_only_safe_flags_counts_and_synthetic_identifiers(self):
        client = FakeClient(ready=False)
        result = maintenance.process_project(client, "omofly", "apply-and-verify")
        self.assertTrue(result["ok"])
        serialized = json.dumps(result)
        self.assertNotIn(DSN, serialized)
        self.assertNotIn(TOKEN, serialized)
        self.assertNotIn("customBilling", serialized)
        self.assertNotIn("custom-rule", serialized)
        event = json.loads(client.probes[0][2].decode().splitlines()[2])
        for marker in tuple(event["extra"].values()) + (event["user"]["ip_address"],):
            self.assertNotIn(marker, serialized)


class CommandTests(unittest.TestCase):
    def test_missing_token_is_safe_and_does_not_build_opener(self):
        output = io.StringIO()
        with patch.dict(maintenance.os.environ, {}, clear=True), \
                patch.object(maintenance, "build_opener") as opener, redirect_stdout(output):
            self.assertEqual(maintenance.main([]), 1)
        opener.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())["error"], "missing_or_invalid_auth_token")

    def test_symbol_token_alone_cannot_authorize_maintenance_or_start_network(self):
        output = io.StringIO()
        with patch.dict(maintenance.os.environ, {"SENTRY_AUTH_TOKEN": TOKEN}, clear=True), \
                patch.object(maintenance, "build_opener") as opener, redirect_stdout(output):
            self.assertEqual(maintenance.main([]), 1)
        opener.assert_not_called()
        self.assertEqual(json.loads(output.getvalue())["error"], "missing_or_invalid_auth_token")
        self.assertNotIn(TOKEN, output.getvalue())

    def test_both_tokens_present_only_maintenance_credential_reaches_client(self):
        client = FakeClient()
        output = io.StringIO()
        symbol_token = "synthetic-symbol-upload-token"
        with patch.dict(maintenance.os.environ, {
                "SENTRY_MAINTENANCE_TOKEN": TOKEN,
                "SENTRY_AUTH_TOKEN": symbol_token,
        }, clear=True), patch.object(maintenance, "SentryClient", return_value=client) as factory, \
                redirect_stdout(output):
            self.assertEqual(maintenance.main([]), 0)
        factory.assert_called_once_with(TOKEN)
        self.assertEqual(client.probes, [])
        self.assertNotIn(TOKEN, output.getvalue())
        self.assertNotIn(symbol_token, output.getvalue())

    def test_default_mode_is_audit_for_both_fixed_projects_and_safe_artifact(self):
        client = FakeClient()
        output = io.StringIO()
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.json"
            with patch.dict(maintenance.os.environ, {"SENTRY_MAINTENANCE_TOKEN": TOKEN}, clear=True), \
                    patch.object(maintenance, "SentryClient", return_value=client) as factory, \
                    redirect_stdout(output):
                self.assertEqual(maintenance.main(["--report", str(report)]), 0)
            factory.assert_called_once_with(TOKEN)
            self.assertEqual(output.getvalue(), report.read_text(encoding="utf-8"))
        result = json.loads(output.getvalue())
        self.assertEqual(result["mode"], "audit")
        self.assertEqual([item["project"] for item in result["projects"]], list(maintenance.PROJECTS))
        self.assertTrue(all(call[1] == "GET" for call in client.calls))
        self.assertEqual(client.probes, [])
        self.assertNotIn(TOKEN, output.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
