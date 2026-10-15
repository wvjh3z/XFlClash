#!/usr/bin/env python3
"""Audit/apply raw-log retention for the two existing Sentry projects.

Default mode is read-only audit. apply changes only the five documented logging
fields; verify sends one synthetic info event per project and reads only that
new event. No real user event, DSN, token, response body or event payload is
written to stdout, stderr or the safe report artifact.

Requires SENTRY_MAINTENANCE_TOKEN in the environment (project:read for audit/key lookup;
project:write or project:admin for apply; event:read for raw-event verification).
SENTRY_AUTH_TOKEN is reserved for symbol uploads and is never used as a fallback.
The maintenance token needs no organization or release permissions.
Raw-event JSON is an experimental Sentry endpoint: verification fails explicitly
if its permissions/schema change; audit/apply remain independent of that endpoint.
Unlimited raw crash storage applies to future reports, subject to Sentry plan,
retention, attachment and ingestion limits; it cannot recover previously removed
data. Organization-wide rules may still scrub events and are never modified.

References:
https://docs.sentry.io/api/projects/update-a-project/
https://docs.sentry.io/api/projects/list-a-projects-client-keys/
https://develop.sentry.dev/sdk/envelopes/
https://github.com/getsentry/sentry/blob/master/src/sentry/core/endpoints/project_details.py
https://github.com/getsentry/sentry/blob/master/src/sentry/relay/datascrubbing.py
https://github.com/getsentry/relay/blob/master/relay-pii/src/convert.rs
https://github.com/getsentry/sentry/blob/master/src/sentry/issues/endpoints/project_event_details.py
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
import uuid


ORGANIZATION = "ka-chiu-lee"
PROJECTS = ("omofly", "daishu")
MODES = ("audit", "apply", "verify", "apply-and-verify")
API_HOSTS = frozenset(("sentry.io", "us.sentry.io", "de.sentry.io"))
API_ROOT = "https://sentry.io"
PROBE_ENVIRONMENT = "sentry-deployment-check"
FIXED_SETTINGS = {
    "dataScrubber": False,
    "dataScrubberDefaults": False,
    "scrubIPAddresses": False,
    "storeCrashReports": -1,
}
OPTION_KEYS = {
    "dataScrubber": "sentry:scrub_data",
    "dataScrubberDefaults": "sentry:scrub_defaults",
    "scrubIPAddresses": "sentry:scrub_ip_address",
    "storeCrashReports": "sentry:store_crash_reports",
    "sensitiveFields": "sentry:sensitive_fields",
    "safeFields": "sentry:safe_fields",
    "relayPiiConfig": "sentry:relay_pii_config",
}
MAX_RESPONSE_BYTES = 4 * 1024 * 1024


class SafeError(Exception):
    """Only fixed diagnostic codes and numeric status may enter a report."""

    def __init__(self, code: str, *, status: int | None = None,
                 scope: str | None = None):
        super().__init__(code)
        self.code = code
        self.status = status
        self.scope = scope


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, url):
        return None


def project_path(project: str) -> str:
    if project not in PROJECTS:
        raise SafeError("project_not_allowed")
    return f"/api/0/projects/{ORGANIZATION}/{project}/"


def valid_api_url(url: str, expected_path_query: str | None = None) -> bool:
    try:
        parsed = urlsplit(url)
        allowed = (parsed.scheme == "https" and parsed.hostname in API_HOSTS
                   and parsed.port in (None, 443) and "@" not in parsed.netloc
                   and not parsed.fragment)
    except ValueError:
        return False
    path_query = parsed.path + (f"?{parsed.query}" if parsed.query else "")
    return bool(allowed and (expected_path_query is None
                            or path_query == expected_path_query))


class SentryClient:
    def __init__(self, token: str, *, opener=None):
        if not token or "\r" in token or "\n" in token:
            raise SafeError("missing_or_invalid_auth_token")
        self._token = token
        self._opener = opener or build_opener(NoRedirect())

    def _request(self, url: str, *, method: str, body: bytes | None,
                 headers: dict, api: bool, scope: str | None = None):
        original = urlsplit(url)
        original_path = original.path + (f"?{original.query}" if original.query else "")
        for attempt in range(3):
            request = Request(url, data=body, headers=headers, method=method)
            try:
                with self._opener.open(request, timeout=20) as response:
                    if response.geturl() != url:
                        raise SafeError("unexpected_automatic_redirect")
                    content = response.read(MAX_RESPONSE_BYTES + 1)
                    if len(content) > MAX_RESPONSE_BYTES:
                        raise SafeError("response_too_large")
                    return content
            except HTTPError as error:
                if error.code in (301, 302, 303, 307, 308):
                    location = error.headers.get("Location", "")
                    destination = urljoin(url, location)
                    error.close()
                    if (api and attempt < 2
                            and valid_api_url(destination, original_path)):
                        url = destination
                        continue
                    raise SafeError("redirect_rejected", status=error.code) from None
                status = error.code
                error.close()
                raise SafeError("http_error", status=status, scope=scope) from None
            except (URLError, TimeoutError, OSError, ValueError):
                raise SafeError("network_error") from None
        raise SafeError("redirect_limit")

    def api(self, path: str, *, method: str = "GET", payload=None,
            scope: str = "project:read"):
        allowed_paths = [re.escape(project_path(project))
                         + r"(?:keys/\?status=active|events/[0-9a-f]{32}/json/)?"
                         for project in PROJECTS]
        if not any(re.fullmatch(pattern, path) for pattern in allowed_paths):
            raise SafeError("api_path_not_allowed")
        if method not in ("GET", "PUT"):
            raise SafeError("api_method_not_allowed")
        if method == "PUT" and path not in tuple(map(project_path, PROJECTS)):
            raise SafeError("api_write_path_not_allowed")
        url = API_ROOT + path
        if not valid_api_url(url):
            raise SafeError("api_url_not_allowed")
        body = None if payload is None else json.dumps(payload).encode("utf-8")
        content = self._request(
            url, method=method, body=body,
            headers={"Authorization": f"Bearer {self._token}",
                     "Content-Type": "application/json", "Accept": "application/json"},
            api=True, scope=scope,
        )
        try:
            return json.loads(content)
        except (ValueError, UnicodeError):
            raise SafeError("invalid_json_response") from None

    def send_probe(self, endpoint: str, public_key: str, envelope: bytes) -> None:
        # This separate request has no management token or DSN in its headers/body.
        parsed = urlsplit(endpoint)
        match = re.fullmatch(r"/api/([0-9]+)/envelope/", parsed.path)
        if not match:
            raise SafeError("untrusted_ingest_endpoint")
        expected, _ = parse_public_dsn(
            f"https://{public_key}@{parsed.netloc}/{match.group(1)}", match.group(1))
        if endpoint != expected:
            raise SafeError("untrusted_ingest_endpoint")
        self._request(
            endpoint, method="POST", body=envelope,
            headers={"Content-Type": "application/x-sentry-envelope",
                     "X-Sentry-Auth": f"Sentry sentry_version=7, sentry_key={public_key}, "
                                      "sentry_client=xflclash-deployment-check/1.0"},
            api=False,
        )


def setting_value(project: dict, field: str):
    if field in project:
        return project[field]
    options = project.get("options", {})
    return options.get(OPTION_KEYS[field]) if isinstance(options, dict) else None


def advanced_rules_disabled(project: dict) -> bool:
    options = project.get("options", {})
    if ("relayPiiConfig" not in project
            and (not isinstance(options, dict)
                 or OPTION_KEYS["relayPiiConfig"] not in options)):
        return False
    value = setting_value(project, "relayPiiConfig")
    return value is None or (isinstance(value, str) and not value.strip())


def setting_matches(project: dict, field: str, value) -> bool:
    actual = setting_value(project, field)
    return type(actual) is type(value) and actual == value


def desired_settings(project: dict) -> dict:
    payload = {field: value for field, value in FIXED_SETTINGS.items()
               if not setting_matches(project, field, value)}
    if not advanced_rules_disabled(project):
        # null is allowed by the serializer but the writer treats it as no update.
        # An empty string is accepted and actually removes active project rules.
        payload["relayPiiConfig"] = ""
    # Existing sensitive/safe field definitions are inert while dataScrubber is
    # false. Preserve them and all unrelated project/organization settings.
    return payload


def safe_settings_report(project: dict) -> dict:
    matched = {field: setting_matches(project, field, value)
               for field, value in FIXED_SETTINGS.items()}
    advanced_disabled = advanced_rules_disabled(project)
    return {
        "raw_logging_ready": all(matched.values()) and advanced_disabled,
        "data_scrubber_disabled": matched["dataScrubber"],
        "default_scrubber_disabled": matched["dataScrubberDefaults"],
        "ip_scrubbing_disabled": matched["scrubIPAddresses"],
        "raw_crash_storage_unlimited": matched["storeCrashReports"],
        "advanced_project_rules_disabled": advanced_disabled,
    }


def parse_public_dsn(dsn: str, project_id: str) -> tuple[str, str]:
    try:
        parsed = urlsplit(dsn)
        public_key = parsed.username or ""
        valid = (
            parsed.scheme == "https" and parsed.port in (None, 443)
            and re.fullmatch(r"o[0-9]+\.ingest(?:\.(?:us|de))?\.sentry\.io",
                             parsed.hostname or "")
            and re.fullmatch(r"[0-9a-fA-F]{32}", public_key)
            and not parsed.password and not parsed.query and not parsed.fragment
            and re.fullmatch(r"[0-9]+", project_id)
            and parsed.path == f"/{project_id}"
        )
    except (ValueError, TypeError):
        valid = False
    if not valid:
        raise SafeError("untrusted_public_dsn")
    return f"https://{parsed.hostname}/api/{project_id}/envelope/", public_key


def make_probe():
    event_id = uuid.uuid4().hex
    # All marker values are synthetic and reproducible from this generated ID.
    # A timed-out run can re-read its own event and perform the exact comparison
    # without sending another event or exporting any real event data.
    markers = (
        "deployment-only-token-" + event_id,
        "deployment-" + event_id + "@example.invalid",
        str(uuid.UUID(event_id)),
        "192.0.2.1",
    )
    debug_id = str(uuid.uuid4()) + "-1"
    event = {
        "event_id": event_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "platform": "native",
        "level": "info",
        "environment": PROBE_ENVIRONMENT,
        "message": "Sentry raw-log deployment verification (synthetic data only)",
        "extra": {"token": markers[0], "email": markers[1], "uuid": markers[2]},
        "user": {"ip_address": markers[3]},
        "debug_meta": {"images": [{
            "type": "pe", "debug_id": debug_id, "code_id": "5f3759df1000",
            "code_file": "deployment-check.dll", "debug_file": "deployment-check.pdb",
            "image_addr": "0x10000000",
            "image_size": 4096,
        }]},
    }
    envelope = "\n".join((
        json.dumps({"event_id": event_id, "sent_at": event["timestamp"]}),
        json.dumps({"type": "event", "content_type": "application/json"}),
        json.dumps(event), "",
    )).encode("utf-8")
    return event_id, markers, debug_id, envelope


def check_probe(event: dict, event_id: str, markers: tuple, debug_id: str) -> dict:
    if (not isinstance(event, dict) or event.get("event_id") != event_id
            or event.get("environment") != PROBE_ENVIRONMENT):
        raise SafeError("unexpected_probe_event")
    extra = event.get("extra")
    extra = extra if isinstance(extra, dict) else {}
    user = event.get("user")
    user = user if isinstance(user, dict) else {}
    preserved = {
        "probe_token_preserved": extra.get("token") == markers[0],
        "probe_email_preserved": extra.get("email") == markers[1],
        "probe_uuid_preserved": extra.get("uuid") == markers[2],
        "probe_ip_preserved": user.get("ip_address") == markers[3],
    }
    images = event.get("debug_meta", {}).get("images", [])
    debug_preserved = any(isinstance(image, dict)
                          and image.get("debug_id", "").casefold() == debug_id.casefold()
                          for image in images)
    return {"probe_received": True, "probe_marker_count": len(markers),
            "probe_preserved_marker_count": sum(preserved.values()), **preserved,
            "debug_identifier_preserved": debug_preserved,
            "probe_verified": all(preserved.values()) and debug_preserved}


def verify_probe(client: SentryClient, project: str, settings: dict, *,
                 attempts: int = 12, sleep=time.sleep, report: dict | None = None) -> dict:
    keys = client.api(project_path(project) + "keys/?status=active")
    if not isinstance(keys, list):
        raise SafeError("invalid_client_keys_response")
    candidates = [key for key in keys if isinstance(key, dict)
                  and key.get("isActive") is True]
    if not candidates:
        raise SafeError("no_active_client_key")
    public_dsn = candidates[0].get("dsn", {}).get("public", "")
    endpoint, public_key = parse_public_dsn(public_dsn, str(settings.get("id", "")))
    event_id, markers, debug_id, envelope = make_probe()
    if report is not None:
        # These identifiers belong only to this generated non-user probe. Keep
        # them if polling fails so maintainers can re-read it without resending.
        report.update(probe_event_id=event_id, probe_debug_id=debug_id, probe_sent=False)
    client.send_probe(endpoint, public_key, envelope)
    if report is not None:
        report["probe_sent"] = True
    for attempt in range(attempts):
        try:
            event = client.api(project_path(project) + f"events/{event_id}/json/",
                               scope="event:read (and project access)")
            return check_probe(event, event_id, markers, debug_id)
        except SafeError as error:
            if error.status != 404:
                raise
        if attempt + 1 < attempts:
            sleep(5)
    raise SafeError("probe_not_received_before_timeout")


def process_project(client: SentryClient, project: str, mode: str) -> dict:
    report = {"project": project, "ok": False}
    try:
        settings = client.api(project_path(project))
        if not isinstance(settings, dict) or settings.get("slug") != project:
            raise SafeError("unexpected_project_response")
        initial = safe_settings_report(settings)
        report["settings_changed"] = False
        if mode in ("apply", "apply-and-verify") and not initial["raw_logging_ready"]:
            payload = desired_settings(settings)
            client.api(project_path(project), method="PUT", payload=payload,
                       scope="project:write or project:admin")
            report["settings_changed"] = True
            settings = client.api(project_path(project))
            if not isinstance(settings, dict) or settings.get("slug") != project:
                raise SafeError("unexpected_project_response")
        report.update(safe_settings_report(settings))
        if mode in ("verify", "apply-and-verify"):
            if not report["raw_logging_ready"]:
                raise SafeError("raw_logging_settings_not_ready")
            report.update(verify_probe(client, project, settings, report=report))
        report["ok"] = report["raw_logging_ready"] and report.get("probe_verified", True)
    except SafeError as error:
        report["error"] = error.code
        if error.status is not None:
            report["http_status"] = error.status
        if error.scope:
            report["required_scope"] = error.scope
    except Exception:
        # Never leak exception strings/tracebacks from unexpected library/API values.
        report["error"] = "unexpected_error"
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=MODES, default="audit")
    parser.add_argument("--report", type=Path)
    arguments = parser.parse_args(argv)
    try:
        client = SentryClient(os.environ.get("SENTRY_MAINTENANCE_TOKEN", ""))
        reports = [process_project(client, project, arguments.mode) for project in PROJECTS]
        report = {"mode": arguments.mode,
                  "ok": all(item["ok"] for item in reports), "projects": reports}
    except SafeError as error:
        report = {"mode": arguments.mode, "ok": False, "error": error.code}
    output = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.report:
        try:
            arguments.report.parent.mkdir(parents=True, exist_ok=True)
            arguments.report.write_text(output, encoding="utf-8")
        except OSError:
            print("Unable to write safe Sentry report", file=sys.stderr)
            return 1
    print(output, end="")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
