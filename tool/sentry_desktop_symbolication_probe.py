#!/usr/bin/env python3
"""Check server symbolication of a known address in an uploaded desktop build.

This sends a CONTROLLED ADDRESS EVENT, NOT a native crash or device-capture test.
It does not run the app, capture a dump, connect a VPN, change Sentry settings,
upload symbols, or inspect user events. The caller obtains a module-relative
address and expected function/source line from the exact local PDB/DWARF file.
ELF/Mach-O decoder virtual addresses must first have the preferred image load
address subtracted; PE input is an RVA, not a file offset or absolute VA.

emit reads a DSN only from generated production defines. It requires successful
upload evidence and verifies the supplied final module and debug companion hashes.
The event contains an UNSYMBOLICATED native frame; expected function/file/line
are retained only in the safe report and are never sent in the event.
verify reads SENTRY_MAINTENANCE_TOKEN only from its environment and polls only the
new event ID in that report. SENTRY_AUTH_TOKEN is never read or used as fallback.
Run verify in the runner step that is explicitly granted the maintenance secret.
The raw-event JSON endpoint is experimental and requires event:read; an API/schema
change fails explicitly. No response body, DSN, token, source contents, local
absolute path, or arbitrary server-provided value is printed or saved.

Example (the address and line must come from the current local debug companion):
  python tool/sentry_desktop_symbolication_probe.py emit \
    --evidence build/sentry-symbols-evidence.json --defines flavor_defines.json \
    --target FlClash --architecture x86_64 --binary <final-module> \
    --symbols <matching-debug-companion> --relative-address 0x1234 \
    --image-size 0x40000 --expected-function my_application_activate \
    --expected-file my_application.cc --expected-line 123 \
    --report build/sentry-symbolication-probe.json
  python tool/sentry_desktop_symbolication_probe.py verify \
    --report build/sentry-symbolication-probe.json

Protocol references:
https://getsentry.github.io/relay/relay_event_schema/protocol/struct.NativeDebugImage.html
https://getsentry.github.io/relay/relay_event_schema/protocol/struct.Frame.html
https://develop.sentry.dev/sdk/envelopes/
https://docs.sentry.io/api/events/retrieve-an-event-for-a-project/
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, build_opener
import uuid

from configure_sentry_projects import (
    NoRedirect, ORGANIZATION, SafeError, SentryClient, parse_public_dsn, project_path,
)


ENVIRONMENT = "sentry-desktop-symbolication-check"
PROBE_KIND = "controlled-native-address-not-crash"
PROJECTS = {"brand_a": "omofly", "brand_b": "daishu"}
FORMATS = {"linux": "elf", "macos": "dsym", "windows": "pdb"}
IMAGE_TYPES = {"elf": "elf", "dsym": "macho", "pdb": "pe"}
ARCHITECTURES = {"x64": "x86_64", "amd64": "x86_64", "x86_64": "x86_64",
                 "arm64": "arm64", "aarch64": "arm64", "x86": "x86",
                 "i386": "x86"}
MAX_INPUT_BYTES = 4 * 1024 * 1024
MAX_ADDRESS = 2**64 - 1
IMAGE_ADDRESS = 0x100000000


def read_json(path: Path) -> dict:
    try:
        with path.open("rb") as stream:
            data = stream.read(MAX_INPUT_BYTES + 1)
        if len(data) > MAX_INPUT_BYTES:
            raise SafeError("input_too_large")
        value = json.loads(data)
    except (OSError, ValueError, UnicodeError):
        raise SafeError("input_json_unavailable_or_invalid") from None
    if not isinstance(value, dict):
        raise SafeError("input_must_be_json_object")
    return value


def label(value, field: str) -> str:
    if (not isinstance(value, str)
            or not re.fullmatch(r"[A-Za-z0-9_.+-]{1,120}", value)
            or value in (".", "..")):
        raise SafeError("invalid_" + field)
    return value


def debug_id(value) -> str:
    if (not isinstance(value, str)
            or not re.fullmatch(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}(?:-[a-fA-F0-9]{1,8})?", value)
            or not value[:36].replace("-", "").strip("0")):
        raise SafeError("invalid_debug_identifier")
    # A zero PDB age and an omitted age identify the same debug information.
    return value.lower().removesuffix("-0")


def address(value) -> int:
    try:
        result = int(value, 0) if isinstance(value, str) else value
    except ValueError:
        raise SafeError("invalid_address") from None
    if type(result) is not int or not 0 <= result <= MAX_ADDRESS:
        raise SafeError("invalid_address")
    return result


def architecture(value) -> str:
    if not isinstance(value, str) or value not in ARCHITECTURES:
        raise SafeError("unsupported_architecture")
    return ARCHITECTURES[value]


def fingerprint(path: Path) -> dict:
    digest = hashlib.sha256()
    count = 0
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                count += len(chunk)
                digest.update(chunk)
    except OSError:
        raise SafeError("artifact_unavailable") from None
    return {"name": path.name, "bytes": count, "sha256": digest.hexdigest()}


def checked_fingerprint(path: Path, expected) -> dict:
    actual = fingerprint(path)
    if not isinstance(expected, dict) or actual != expected:
        raise SafeError("artifact_does_not_match_uploaded_evidence")
    safe_basename(actual["name"])
    return actual


def safe_basename(value) -> str:
    if (not isinstance(value, str) or not 1 <= len(value) <= 255
            or value in (".", "..") or any(c in value for c in "/\\:")
            or any(ord(c) < 32 for c in value)):
        raise SafeError("invalid_artifact_basename")
    return value


def expected_location(function, source_file, line) -> dict:
    if (not isinstance(function, str) or not 1 <= len(function) <= 256
            or not function.strip() or any(ord(c) < 32 for c in function)
            or "/" in function or "\\" in function):
        raise SafeError("invalid_expected_function")
    label(source_file, "expected_file_basename")
    if type(line) is not int or not 0 <= line <= 10000000:
        raise SafeError("invalid_expected_line")
    return {"function_contains": function, "file_basename": source_file, "line": line}


def selection_arguments(args):
    if args.selection is None:
        required = ("target", "architecture", "binary", "symbols", "relative_address", "image_size",
                    "expected_function", "expected_file", "expected_line")
        if any(getattr(args, key, None) is None for key in required):
            raise SafeError("selection_or_explicit_module_arguments_required")
        return None
    selected = read_json(args.selection)
    module, frame, expected = (selected.get(key) for key in ("module", "frame", "expected"))
    if (selected.get("schema_version") != 1 or selected.get("platform") not in FORMATS
            or not all(isinstance(value, dict) for value in (module, frame, expected))
            or frame.get("addr_mode") != "rel:0"):
        raise SafeError("invalid_symbolication_selection")
    args.target, args.architecture = module.get("target"), module.get("architecture")
    args.relative_address = frame.get("instruction_addr")
    args.image_size, args.image_vmaddr = module.get("image_size"), module.get("image_vmaddr", "0x0")
    args.expected_function, args.expected_file = expected.get("function"), expected.get("filename")
    args.expected_line = expected.get("lineno")
    root = args.build_root.resolve()
    for key in ("binary", "symbols"):
        value = selected.get(key + "_path", module.get(key + "_path"))
        if not isinstance(value, str) or not value or Path(value).is_absolute():
            raise SafeError("selection_relative_artifact_path_required")
        path = (root / value).resolve()
        if not path.is_relative_to(root) or not path.is_file():
            raise SafeError("selection_artifact_outside_build_root_or_missing")
        setattr(args, key, path)
    return selected


def make_report(args) -> dict:
    selected = selection_arguments(args)
    evidence = read_json(args.evidence)
    if (evidence.get("schema_version") != 1
            or evidence.get("status") != "uploaded_and_processed"
            or evidence.get("platform") not in FORMATS
            or evidence.get("flavor") not in PROJECTS):
        raise SafeError("successful_desktop_symbol_upload_evidence_required")
    arch = architecture(args.architecture)
    native = evidence.get("native")
    if not isinstance(native, list):
        raise SafeError("native_symbol_inventory_missing")
    candidates = []
    for item in native:
        if not isinstance(item, dict) or item.get("target") != args.target:
            continue
        item_arches = item.get("architectures", [])
        if "architecture" in item:
            item_arches = [item["architecture"]]
        if not isinstance(item_arches, list):
            raise SafeError("invalid_native_architecture_inventory")
        if arch in {architecture(value) for value in item_arches}:
            candidates.append(item)
    if len(candidates) != 1:
        raise SafeError("native_target_architecture_not_unique")
    item = candidates[0]
    if item.get("format") != FORMATS[evidence["platform"]]:
        raise SafeError("unexpected_desktop_symbol_format")
    identifiers = item.get("debug_ids")
    if not isinstance(identifiers, list) or len(identifiers) != 1:
        raise SafeError("exactly_one_native_debug_identifier_required")
    binary = checked_fingerprint(args.binary, item.get("binary"))
    symbols = checked_fingerprint(args.symbols, item.get("symbols"))
    offset, size, vmaddr = map(address, (args.relative_address, args.image_size, args.image_vmaddr))
    if not 0 < offset < size or IMAGE_ADDRESS + size > MAX_ADDRESS:
        raise SafeError("address_outside_module")
    image = {"type": IMAGE_TYPES[item["format"]], "debug_id": debug_id(identifiers[0]),
             "code_file": binary["name"], "debug_file": symbols["name"], "arch": arch,
             "image_addr": hex(IMAGE_ADDRESS), "image_size": size, "image_vmaddr": hex(vmaddr)}
    if selected is not None:
        module = selected["module"]
        if (selected["platform"] != evidence["platform"]
                or debug_id(module.get("debug_id")) != image["debug_id"]
                or module.get("code_file") != image["code_file"]
                or module.get("debug_file") != image["debug_file"]):
            raise SafeError("selection_does_not_match_uploaded_module")
    if image["type"] == "elf":
        build_id = item.get("build_id")
        if not isinstance(build_id, str) or not re.fullmatch(r"[0-9a-fA-F]{8,128}", build_id):
            raise SafeError("elf_build_identifier_missing")
        image["code_id"] = build_id.lower()
    elif image["type"] == "macho":
        image["code_id"] = image["debug_id"].replace("-", "")
    # PE code_id is optional for an address event (no stack walking). Do not
    # invent a PE timestamp/SizeOfImage absent from the audited evidence.
    report = {"schema_version": 1, "kind": PROBE_KIND, "native_crash_test": False,
              "device_capture_verified": False, "status": "prepared", "sent": False,
              "organization": ORGANIZATION, "project": PROJECTS[evidence["flavor"]],
              "flavor": evidence["flavor"], "platform": evidence["platform"],
              "environment": ENVIRONMENT, "event_id": uuid.uuid4().hex,
              "created_at": datetime.now(timezone.utc).isoformat(), "target": label(args.target, "target"),
              "symbol_evidence_sha256": fingerprint(args.evidence)["sha256"],
              "binary": binary, "symbols": symbols, "image": image,
              "relative_address": hex(offset), "instruction_address": hex(IMAGE_ADDRESS + offset),
              "expected": expected_location(args.expected_function, args.expected_file, args.expected_line)}
    for field in ("product_version", "build_number", "source_revision"):
        if field in evidence:
            report[field] = label(evidence[field], field)
    return report


def make_event(report: dict) -> dict:
    # Expected symbol names/source locations MUST NOT appear here. The server
    # must resolve them from the previously uploaded debug information.
    return {
        "event_id": report["event_id"], "timestamp": report["created_at"],
        "platform": "native", "level": "error", "environment": ENVIRONMENT,
        "message": "Controlled desktop native address symbolication check (not a crash)",
        "tags": {"xflclash.probe_kind": PROBE_KIND, "xflclash.probe_id": report["event_id"],
                 "xflclash.probe_platform": report["platform"]},
        "fingerprint": [PROBE_KIND, report["platform"], report["image"]["debug_id"]],
        "debug_meta": {"images": [dict(report["image"])]},
        "exception": {"values": [{"type": "ControlledNativeAddressProbe",
            "value": "Synthetic address event; native capture and stack walking are not tested",
            "mechanism": {"type": "generic", "handled": True, "synthetic": True},
            "stacktrace": {"frames": [{"platform": "native", "in_app": True,
                "instruction_addr": report["instruction_address"],
                "image_addr": report["image"]["image_addr"],
                "package": report["image"]["code_file"], "trust": "context"}]}}]},
    }


def send_event(defines_path: Path, report: dict, *, opener=None) -> None:
    defines = read_json(defines_path)
    if (defines.get("XB_FLAVOR_ID") != report["flavor"]
            or str(defines.get("XB_DEBUG", "")).lower() != "false"):
        raise SafeError("matching_production_defines_required")
    dsn = defines.get("XB_SENTRY_DSN")
    if not isinstance(dsn, str):
        raise SafeError("production_dsn_missing")
    # Project ID is not exposed in the safe report. parse_public_dsn rejects
    # arbitrary hosts, password credentials, redirects and non-Sentry DSNs.
    project_id = dsn.rsplit("/", 1)[-1]
    endpoint, public_key = parse_public_dsn(dsn, project_id)
    event = make_event(report)
    envelope = "\n".join((json.dumps({"event_id": report["event_id"], "sent_at": report["created_at"]}),
        json.dumps({"type": "event", "content_type": "application/json"}),
        json.dumps(event), "")).encode("utf-8")
    request = Request(endpoint, data=envelope, method="POST", headers={
        "Content-Type": "application/x-sentry-envelope",
        "X-Sentry-Auth": f"Sentry sentry_version=7, sentry_key={public_key}, "
                         "sentry_client=xflclash-native-address-probe/1.0",
    })
    try:
        with (opener or build_opener(NoRedirect())).open(request, timeout=30) as response:
            if response.geturl() != endpoint:
                raise SafeError("unexpected_ingest_redirect")
            # Do not print, save or parse arbitrary ingest response contents.
            response.read(4096)
    except HTTPError as error:
        status = error.code
        error.close()
        raise SafeError("ingest_http_error", status=status) from None
    except (URLError, TimeoutError, OSError, ValueError):
        raise SafeError("ingest_network_error") from None


def validate_report(report: dict) -> None:
    required = {"schema_version", "kind", "native_crash_test", "device_capture_verified", "status", "sent",
                "organization", "project", "flavor", "platform", "environment", "event_id", "created_at",
                "target", "symbol_evidence_sha256", "binary", "symbols", "image", "relative_address",
                "instruction_address", "expected"}
    optional = {"product_version", "build_number", "source_revision", "verification", "verified_at", "error"}
    if not required <= report.keys() or report.keys() - required - optional:
        raise SafeError("unexpected_probe_report_fields")
    if (report.get("schema_version") != 1 or report.get("kind") != PROBE_KIND
            or report.get("native_crash_test") is not False
            or report.get("device_capture_verified") is not False
            or report.get("organization") != ORGANIZATION
            or report.get("flavor") not in PROJECTS
            or report.get("project") != PROJECTS[report["flavor"]]
            or report.get("environment") != ENVIRONMENT
            or report.get("platform") not in FORMATS
            or not re.fullmatch(r"[0-9a-f]{32}", str(report.get("event_id", "")))
            or report.get("status") not in ("sent", "emit_failed", "verification_failed", "verified")):
        raise SafeError("invalid_probe_report")
    if type(report["sent"]) is not bool:
        raise SafeError("invalid_probe_report")
    for field in ("created_at", "verified_at"):
        if field not in report:
            continue
        try:
            timestamp = datetime.fromisoformat(report[field])
            if timestamp.tzinfo is None:
                raise ValueError
        except (ValueError, TypeError):
            raise SafeError("invalid_probe_timestamp") from None
    label(report.get("target"), "target")
    if not re.fullmatch(r"[0-9a-f]{64}", str(report.get("symbol_evidence_sha256", ""))):
        raise SafeError("invalid_symbol_evidence_fingerprint")
    for field in ("binary", "symbols"):
        value = report[field]
        if (not isinstance(value, dict) or set(value) != {"name", "bytes", "sha256"}
                or type(value["bytes"]) is not int or value["bytes"] <= 0
                or not re.fullmatch(r"[0-9a-f]{64}", str(value["sha256"]))):
            raise SafeError("invalid_artifact_fingerprint")
        safe_basename(value["name"])
    patterns = {"product_version": r"[0-9]+\.[0-9]+\.[0-9]+(?:[.+-][A-Za-z0-9.-]+)?",
                "build_number": r"[0-9]+", "source_revision": r"[0-9a-fA-F]{7,64}"}
    for field, pattern in patterns.items():
        if field in report and (not isinstance(report[field], str) or not re.fullmatch(pattern, report[field])):
            raise SafeError("invalid_safe_build_metadata")
    expected, image = report.get("expected"), report.get("image")
    if not isinstance(expected, dict) or not isinstance(image, dict):
        raise SafeError("invalid_probe_report")
    if set(expected) != {"function_contains", "file_basename", "line"}:
        raise SafeError("unexpected_expected_location_fields")
    image_required = {"type", "debug_id", "code_file", "debug_file", "arch", "image_addr", "image_size", "image_vmaddr"}
    if not image_required <= image.keys() or image.keys() - image_required - {"code_id"}:
        raise SafeError("unexpected_debug_image_fields")
    if "code_id" in image and (not isinstance(image["code_id"], str)
            or not re.fullmatch(r"[0-9a-fA-F]{8,128}", image["code_id"])):
        raise SafeError("invalid_image_code_identifier")
    expected_location(expected.get("function_contains"), expected.get("file_basename"), expected.get("line"))
    debug_id(image.get("debug_id"))
    architecture(image.get("arch"))
    if image.get("type") != IMAGE_TYPES[FORMATS[report["platform"]]]:
        raise SafeError("unexpected_report_image_format")
    safe_basename(image.get("code_file"))
    safe_basename(image.get("debug_file"))
    if image["code_file"] != report["binary"]["name"] or image["debug_file"] != report["symbols"]["name"]:
        raise SafeError("inconsistent_report_artifact_names")
    address(image.get("image_vmaddr"))
    offset = address(report.get("relative_address"))
    if not 0 < offset < address(image.get("image_size")):
        raise SafeError("address_outside_module")
    if address(report.get("instruction_address")) != address(image.get("image_addr")) + offset:
        raise SafeError("inconsistent_report_addresses")
    if "verification" in report:
        value = report["verification"]
        bools = {"probe_received", "debug_image_matches_uploaded_module", "server_symbolication_verified"}
        if (not isinstance(value, dict) or set(value) != bools | {"resolved_expected_frame_count"}
                or any(type(value[key]) is not bool for key in bools)
                or type(value["resolved_expected_frame_count"]) is not int
                or not 0 <= value["resolved_expected_frame_count"] <= 100000):
            raise SafeError("invalid_safe_verification_summary")
    if "error" in report:
        value = report["error"]
        if (not isinstance(value, dict) or "code" not in value or value.keys() - {"code", "http_status"}
                or not isinstance(value["code"], str) or not re.fullmatch(r"[a-z_]{1,100}", value["code"])
                or ("http_status" in value and (type(value["http_status"]) is not int or not 100 <= value["http_status"] <= 599))):
            raise SafeError("invalid_safe_error_summary")


def safe_report(report: dict) -> dict:
    """Validate first, then construct output; never serialize raw report input."""
    validate_report(report)
    # Input summaries are disposable. Only locally computed new verification or
    # error summaries may enter the output artifact.
    result = {key: report[key] for key in (
        "schema_version", "kind", "native_crash_test", "device_capture_verified", "status", "sent",
        "organization", "project", "flavor", "platform", "environment", "event_id", "created_at",
        "target", "symbol_evidence_sha256", "relative_address", "instruction_address")}
    for field in ("product_version", "build_number", "source_revision"):
        if field in report:
            result[field] = report[field]
    result["binary"] = {key: report["binary"][key] for key in ("name", "bytes", "sha256")}
    result["symbols"] = {key: report["symbols"][key] for key in ("name", "bytes", "sha256")}
    result["image"] = {key: report["image"][key] for key in (
        "type", "debug_id", "code_file", "debug_file", "arch", "image_addr", "image_size", "image_vmaddr")}
    if "code_id" in report["image"]:
        result["image"]["code_id"] = report["image"]["code_id"]
    result["expected"] = expected_location(report["expected"]["function_contains"],
        report["expected"]["file_basename"], report["expected"]["line"])
    return result


def basename(value) -> str:
    return value.replace("\\", "/").rsplit("/", 1)[-1] if isinstance(value, str) else ""


def function_matches(function, report: dict) -> bool:
    if not isinstance(function, str):
        return False
    expected = report["expected"]["function_contains"]
    if expected in function:
        return True
    # Symbolic's official name_only Swift demangling disables parameter
    # rendering. Accept only the observed empty-() presentation difference,
    # using exact equality; argument-bearing/generic/prefixed names stay strict.
    # https://github.com/getsentry/symbolic/blob/master/symbolic-demangle/src/lib.rs#L109-L114
    return bool(report["platform"] == "macos"
                and report["expected"]["file_basename"].endswith(".swift")
                and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+\(\)", expected)
                and function == expected[:-2])


def check_event(event: dict, report: dict) -> dict:
    if (not isinstance(event, dict) or event.get("event_id") != report["event_id"]
            or event.get("environment") != ENVIRONMENT or event.get("platform") != "native"):
        raise SafeError("unexpected_probe_event")
    tags = event.get("tags", [])
    if isinstance(tags, list):
        tags = {item[0]: item[1] for item in tags
                if isinstance(item, (list, tuple)) and len(item) == 2
                and isinstance(item[0], str) and isinstance(item[1], str)}
    if (not isinstance(tags, dict) or tags.get("xflclash.probe_kind") != PROBE_KIND
            or tags.get("xflclash.probe_id") != report["event_id"]):
        raise SafeError("probe_identity_not_preserved")
    wanted = report["image"]
    metadata = event.get("debug_meta")
    images = metadata.get("images", []) if isinstance(metadata, dict) else []
    matched_image = False
    for item in images if isinstance(images, list) else []:
        if not isinstance(item, dict):
            continue
        try:
            matched_image = (debug_id(item.get("debug_id")) == wanted["debug_id"]
                and item.get("type") == wanted["type"]
                and architecture(item.get("arch")) == wanted["arch"]
                and basename(item.get("code_file")) == wanted["code_file"]
                and address(item.get("image_addr")) == address(wanted["image_addr"]))
        except SafeError:
            continue
        if matched_image:
            break
    matches = 0
    exception_value = event.get("exception")
    exceptions = exception_value.get("values", []) if isinstance(exception_value, dict) else []
    expected = report["expected"]
    for exception in exceptions if isinstance(exceptions, list) else []:
        if not isinstance(exception, dict):
            continue
        stacktrace = exception.get("stacktrace")
        frames = stacktrace.get("frames", []) if isinstance(stacktrace, dict) else []
        for frame in frames if isinstance(frames, list) else []:
            if not isinstance(frame, dict):
                continue
            try:
                same_address = address(frame.get("instruction_addr")) == address(report["instruction_address"])
            except SafeError:
                continue
            function = frame.get("function")
            if (same_address and function_matches(function, report)
                    and basename(frame.get("filename") or frame.get("abs_path")) == expected["file_basename"]
                    and type(frame.get("lineno")) is int and frame["lineno"] > 0
                    and (expected["line"] == 0 or frame["lineno"] == expected["line"])):
                matches += 1
    return {"probe_received": True, "debug_image_matches_uploaded_module": matched_image,
            "resolved_expected_frame_count": matches,
            "server_symbolication_verified": matched_image and matches > 0}


def write_report(path: Path, report: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def verify(report: dict, *, attempts: int, interval: int, client=None, sleep=time.sleep) -> None:
    validate_report(report)
    if client is None:
        token = os.environ.get("SENTRY_MAINTENANCE_TOKEN", "")
        if not token.strip():
            raise SafeError("maintenance_token_environment_required")
        client = SentryClient(token)
    path = project_path(report["project"]) + "events/" + report["event_id"] + "/json/"
    for attempt in range(attempts):
        try:
            event = client.api(path, scope="event:read")
            report["verification"] = check_event(event, report)
            if report["verification"]["server_symbolication_verified"]:
                report["status"] = "verified"
                report.pop("error", None)
                report["verified_at"] = datetime.now(timezone.utc).isoformat()
                return
        except SafeError as error:
            if error.code != "http_error" or error.status not in (404, 429, 502, 503, 504):
                raise
        if attempt + 1 < attempts:
            sleep(interval)
    raise SafeError("server_symbolication_not_verified_before_timeout")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_subparsers(dest="mode", required=True)
    emit = modes.add_parser("emit", help="Send one unsymbolicated address event; no management token")
    emit.add_argument("--evidence", type=Path, required=True)
    emit.add_argument("--defines", type=Path, required=True)
    emit.add_argument("--selection", type=Path, help="Safe selection produced by pick_sentry_symbolication_probe.py")
    emit.add_argument("--build-root", type=Path, default=Path("build"))
    emit.add_argument("--target")
    emit.add_argument("--architecture", choices=ARCHITECTURES)
    emit.add_argument("--binary", type=Path)
    emit.add_argument("--symbols", type=Path)
    emit.add_argument("--relative-address", help="RVA: decoder VA minus preferred module load address")
    emit.add_argument("--image-size", help="Mapped module size from the native image headers")
    emit.add_argument("--image-vmaddr", default="0x0", help="Preferred load address in ELF/Mach-O/PE headers")
    emit.add_argument("--expected-function", help="Required substring of the server-resolved function")
    emit.add_argument("--expected-file", help="Source filename basename only")
    emit.add_argument("--expected-line", type=int, help="Exact resolved source line; 0 requires any positive line")
    emit.add_argument("--report", type=Path, required=True)
    emit.add_argument("--dry-run", action="store_true", help="Build a safe report without reading DSN or sending event")
    check = modes.add_parser("verify", help="Read only this new event, using the maintenance token from environment")
    check.add_argument("--report", type=Path, required=True)
    check.add_argument("--output", type=Path, help="Write safe result separately; raw report input is never copied")
    check.add_argument("--attempts", type=int, default=30)
    check.add_argument("--interval", type=int, default=10)
    args = parser.parse_args(argv)
    destination = getattr(args, "output", None) or args.report
    report = None
    try:
        if args.mode == "emit":
            if args.report.exists():
                raise SafeError("report_exists_refusing_duplicate_emission")
            report = make_report(args)
            write_report(args.report, report)
            if args.dry_run:
                report["status"] = "prepared_offline"
            else:
                send_event(args.defines, report)
                report.update(status="sent", sent=True)
        else:
            if not 1 <= args.attempts <= 120 or not 1 <= args.interval <= 60:
                raise SafeError("invalid_polling_limits")
            report = safe_report(read_json(args.report))
            verify(report, attempts=args.attempts, interval=args.interval)
        write_report(destination, report)
        print("Controlled address probe: " + report["status"] + "; native crash/device capture not tested")
        return 0
    except SafeError as error:
        if report is not None:
            report["status"] = "emit_failed" if args.mode == "emit" else "verification_failed"
            report["error"] = {"code": error.code}
            if error.status is not None:
                report["error"]["http_status"] = error.status
            write_report(destination, report)
        elif args.mode == "verify" and args.output is not None:
            write_report(destination, {"schema_version": 1, "kind": PROBE_KIND,
                "native_crash_test": False, "device_capture_verified": False,
                "status": "verification_failed", "error": {"code": error.code}})
        print("Controlled address probe failed: " + error.code, file=sys.stderr)
        return 1
    except OSError:
        print("Controlled address probe failed: report_io_error", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
