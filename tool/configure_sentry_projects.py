#!/usr/bin/env python3
"""Audit/apply privacy settings for the two existing Sentry projects.

Default mode is read-only audit. apply changes only the six documented privacy
fields; verify sends one synthetic info event per project and reads only that
new event. No real user event, DSN, token, response body or event payload is
written to stdout, stderr or the safe report artifact.

Requires SENTRY_AUTH_TOKEN in the environment (project:read for audit/key lookup;
project:write or project:admin for apply; event:read for raw-event verification).
The token used only to upload release symbols may lack these permissions.
Raw-event JSON is an experimental Sentry endpoint: verification fails explicitly
if its permissions/schema change; audit/apply remain independent of that endpoint.
Disabling raw crash storage affects future reports, not previously retained dumps.

References:
https://docs.sentry.io/api/projects/update-a-project/
https://docs.sentry.io/api/projects/list-a-projects-client-keys/
https://develop.sentry.dev/sdk/envelopes/
https://github.com/getsentry/sentry/blob/master/src/sentry/issues/endpoints/project_event_details.py
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fnmatch
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
SENSITIVE_FIELDS = (
    "token", "password", "pwd", "email", "uuid", "authorization", "auth_data",
    "aesKey", "aes_key", "bootstrapAesKey", "subscriptionAesKey", "api_key",
    "client_secret", "cookie", "subscription_url", "subscribe_url",
)
FIXED_SETTINGS = {
    "dataScrubber": True,
    "dataScrubberDefaults": True,
    "scrubIPAddresses": True,
    "storeCrashReports": 0,
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


def string_fields(project: dict, field: str) -> list[str]:
    value = setting_value(project, field)
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise SafeError("invalid_project_privacy_fields")
    return value


def sensitive_safe_field(field: str) -> bool:
    normalized = re.sub(r"[^a-z0-9*?]", "", field.casefold())
    for sensitive in SENSITIVE_FIELDS:
        target = re.sub(r"[^a-z0-9]", "", sensitive.casefold())
        if target in normalized or fnmatch.fnmatchcase(target, normalized):
            return True
    return False


def desired_settings(project: dict) -> dict:
    sensitive = string_fields(project, "sensitiveFields")[:]
    existing = {field.casefold() for field in sensitive}
    for field in SENSITIVE_FIELDS:
        if field.casefold() not in existing:
            sensitive.append(field)
            existing.add(field.casefold())
    safe = [field for field in string_fields(project, "safeFields")
            if not sensitive_safe_field(field)]
    return {**FIXED_SETTINGS, "sensitiveFields": sensitive, "safeFields": safe}


def safe_settings_report(project: dict) -> dict:
    desired = desired_settings(project)
    sensitive = string_fields(project, "sensitiveFields")
    safe = string_fields(project, "safeFields")
    booleans = {
        key: type(setting_value(project, key)) is type(value)
        and setting_value(project, key) == value
        for key, value in FIXED_SETTINGS.items()
    }
    complete = {field.casefold() for field in sensitive} >= {
        field.casefold() for field in SENSITIVE_FIELDS
    }
    conflicts = sum(sensitive_safe_field(field) for field in safe)
    return {
        "privacy_ready": all(booleans.values()) and complete and conflicts == 0,
        "data_scrubber_enabled": booleans["dataScrubber"],
        "default_scrubber_enabled": booleans["dataScrubberDefaults"],
        "ip_scrubbing_enabled": booleans["scrubIPAddresses"],
        "raw_crash_storage_disabled": booleans["storeCrashReports"],
        "sensitive_fields_complete": complete,
        "sensitive_field_count": len(sensitive),
        "safe_field_count": len(safe),
        "conflicting_safe_field_count": conflicts,
        "added_sensitive_field_count": len(desired["sensitiveFields"]) - len(sensitive),
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
    markers = (
        "deployment-only-token-" + uuid.uuid4().hex,
        "deployment-" + uuid.uuid4().hex + "@example.invalid",
        str(uuid.uuid4()),
        "192.0.2.1",
    )
    debug_id = str(uuid.uuid4()) + "-1"
    event = {
        "event_id": event_id,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "platform": "native",
        "level": "info",
        "environment": PROBE_ENVIRONMENT,
        "message": "Sentry deployment privacy verification (synthetic data only)",
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
    serialized = json.dumps(event, sort_keys=True)
    removed = sum(marker not in serialized for marker in markers)
    images = event.get("debug_meta", {}).get("images", [])
    debug_preserved = any(isinstance(image, dict)
                          and image.get("debug_id", "").casefold() == debug_id.casefold()
                          for image in images)
    return {"probe_received": True, "probe_marker_count": len(markers),
            "probe_scrubbed_marker_count": removed,
            "debug_identifier_preserved": debug_preserved,
            "probe_verified": removed == len(markers) and debug_preserved}


def verify_probe(client: SentryClient, project: str, settings: dict, *,
                 attempts: int = 12, sleep=time.sleep) -> dict:
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
    client.send_probe(endpoint, public_key, envelope)
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
        if mode in ("apply", "apply-and-verify") and not initial["privacy_ready"]:
            payload = desired_settings(settings)
            old_relay = setting_value(settings, "relayPiiConfig")
            client.api(project_path(project), method="PUT", payload=payload,
                       scope="project:write or project:admin")
            report["settings_changed"] = True
            settings = client.api(project_path(project))
            if (not isinstance(settings, dict) or settings.get("slug") != project
                    or setting_value(settings, "relayPiiConfig") != old_relay):
                raise SafeError("project_or_advanced_rules_changed")
        report.update(safe_settings_report(settings))
        if mode in ("verify", "apply-and-verify"):
            # Do not send even synthetic markers to a project with unconfirmed privacy.
            if not report["privacy_ready"]:
                raise SafeError("privacy_settings_not_ready")
            report.update(verify_probe(client, project, settings))
        report["ok"] = report["privacy_ready"] and report.get("probe_verified", True)
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
        client = SentryClient(os.environ.get("SENTRY_AUTH_TOKEN", ""))
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
