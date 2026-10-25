#!/usr/bin/env python3
"""Bounded foreground SwiftPM diagnostics for this macOS Flutter project.

No build, package-policy change, symbol upload or Sentry event is performed.
The default resolve command follows Flutter 3.44's prefetch command exactly;
--explicit-project changes only its container to Runner.xcodeproj for diagnosis.
List targets Runner.xcodeproj and skips package updates only. Plugin and package
signature validation retain Xcode defaults. Both commands use the existing
build/macos/SourcePackages cache, and ARM uses Flutter's arch -arm64e prefix.

Progress uses fixed categories and allowlisted public repository labels. Failed
phases also retain bounded sanitized head/tail output, suppressing sensitive
fields and continuations, URLs and user paths. Raw output is not persisted.
The JSON report includes status, exit/timeout/counters, PIDs and error context.
Version/local-manifest/public-ref diagnostics are independent and never gate
the main resolver. Public HEAD checks establish connectivity, not the revision
selected by the project's actual dependency graph. Optional timeout sampling is
disabled by default; raw stacks stay in bounded memory and only fixed hints leave.
"""

from __future__ import annotations

import argparse
from collections import deque
import json
import os
from pathlib import Path
import platform
import re
import selectors
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import time
from urllib.parse import urlsplit


PUBLIC_REPOSITORIES = frozenset({"getsentry/sentry-cocoa", "sindresorhus/LaunchAtLogin",
                               "sindresorhus/LaunchAtLogin-Legacy", "simolus3/CSQLite"})
CSQLITE_REQUIRED_REVISION = "1ee46d19a4f451a7aa64ffc64fc99b4748131e62"
URL = re.compile(r"(?:https?|ssh)://[^\s<>\"']+|git@[^\s<>\"']+")
PROCESS_NAMES = frozenset({"xcodebuild", "xcrun", "arch", "swift", "swift-frontend", "swift-package",
    "git", "git-remote-https", "git-remote-http", "git-fetch-pack", "ssh", "sandbox-exec",
    "XCBBuildService", "XCBuild", "clang", "clang++", "dsymutil"})
GENERATED_PACKAGE = "FlutterGeneratedPluginSwiftPackage"
MAX_CAPTURE_BYTES = 1024 * 1024
MAX_SAMPLE_BYTES = 128 * 1024
MAX_CACHE_ENTRIES = 5000
CACHE_TIMEOUT_SECONDS = 1.5
SAMPLE_FRAME = re.compile(r"^\s*([+!:|.\s]*?)(\d+)\s+(.+?)\s+\(in\s+([^)]+)\)")
# Exact shipped-image names only. Project/manifest images, the xcodebuild main
# executable and arbitrary image paths must never contribute symbol strings.
SHIPPED_IMAGE_PRIORITY = {
    **dict.fromkeys(("SwiftPM", "libSwiftPM.dylib", "SwiftPMDataModel", "SwiftPMWorkspace", "SwiftPMXcode",
        "IDEPackageSupport", "IDESwiftPackageCore", "DVTSourceControl", "DVTSourceControlCore", "Security", "SecurityFoundation",
        "CFNetwork", "Network", "libnetwork.dylib"), 0),
    **dict.fromkeys(("DVTFoundation", "DVTDeveloperFoundation", "IDEFoundation", "Foundation", "CoreFoundation", "XCBuild", "XCBBuildService",
        "libarchive.2.dylib", "libcompression.dylib", "libcommonCrypto.dylib", "libsqlite3.dylib", "libz.1.dylib"), 1),
    **dict.fromkeys(("libdispatch.dylib", "libsystem_kernel.dylib", "libsystem_pthread.dylib", "libsystem_c.dylib",
        "libsystem_malloc.dylib", "libdyld.dylib", "libobjc.A.dylib", "libswift_Concurrency.dylib", "libswiftCore.dylib"), 2),
}


class DiagnosticError(Exception):
    pass


def child_environment(environment: dict[str, str]) -> dict[str, str]:
    # Do not expose credentials or encoded brand defines to xcodebuild's
    # dependency-resolution diagnostics. Keep the ordinary toolchain environment.
    result = {key: value for key, value in environment.items()
              if not key.startswith(("SENTRY_", "XB_", "DART_DEFINE", "FLUTTER_XCODE_"))
              and not any(word in key.upper() for word in ("TOKEN", "PASSWORD", "SECRET", "AES_KEY", "DSN"))}
    result["GIT_TERMINAL_PROMPT"] = "0"
    return result


def safe_progress(line: str) -> str | None:
    """Classify child output; never return arbitrary text from that output."""
    lower = line.lower()
    category = next((label for needle, label in (
        ("error:", "dependency_error"), ("warning:", "dependency_warning"),
        ("fetching", "fetching_package"), ("checking out", "checking_out_package"),
        ("creating working copy", "creating_package_checkout"),
        ("resolve package graph", "resolving_package_graph"),
        ("resolved source packages", "packages_resolved"),
        ("updating", "updating_package")) if needle in lower), None)
    if category is None:
        return None
    labels = set()
    for match in URL.finditer(line):
        value = match.group(0)
        try:
            parsed = urlsplit(value)
            repository = parsed.path.strip("/").removesuffix(".git")
            if parsed.hostname == "github.com" and repository in PUBLIC_REPOSITORIES:
                labels.add("github.com/" + repository)
            else:
                labels.add("[redacted-url]")
        except ValueError:
            labels.add("[redacted-url]")
    return category + (" " + " ".join(sorted(labels)) if labels else "")


# Preserve useful failure text rather than only an exit code. Never emit raw
# output: credentials, URLs and user paths are removed before retention.
MAX_ERROR_CONTEXT_LINES = 24
MAX_ERROR_LINE_CHARS = 800

SENSITIVE_FIELD = re.compile(
    r"(?i)\b(?:[a-z0-9]+[_-])*(?:token|password|secret|authorization|dart_defines|aes_key|sentry_dsn)\b[\"']?\s*[:=]")
AUTH_VALUE = re.compile(r"(?i)\b(?:bearer|basic)\s+\S+")
DIAGNOSTIC_START = re.compile(r"(?i)^\s*(?:(?:xcodebuild|swift|git):\s*)?(?:error:|fatal:|warning:|fetching\b|resolved source packages\b)")


def safe_error_context(line: str) -> str:
    if len(line) > MAX_ERROR_LINE_CHARS:
        return "[oversized diagnostic omitted]"
    line = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", line)
    if SENSITIVE_FIELD.search(line) or AUTH_VALUE.search(line):
        return "[sensitive diagnostic omitted]"
    line = URL.sub("[url]", line)
    line = re.sub(r"[\w.+-]+@[\w.-]+", "[identity]", line)
    line = re.sub(r"(?:/Users/|/home/|/private/|/var/|/tmp/|/root/)[^\s\"']+", "[path]", line)
    line = ''.join(c if c >= ' ' else ' ' for c in line).strip()
    return line[:MAX_ERROR_LINE_CHARS]


class ErrorContext:
    """Bounded sanitized head/tail, including causes before a generic error.

    A sensitive field opens a suppressed continuation block. Only a recognizable
    diagnostic boundary resumes capture; blank lines alone are not sufficient.
    """
    def __init__(self):
        self.head = []
        self.tail = deque(maxlen=MAX_ERROR_CONTEXT_LINES - 8)
        self.count = 0
        self.sensitive_block = False
        self.line_truncated = False

    def add(self, text: str):
        if len(text) > MAX_ERROR_LINE_CHARS:
            # Discard before regex work; truncated fragments may be credentials.
            self.line_truncated = True
            self.sensitive_block = True
            safe = "[oversized diagnostic omitted]"
        else:
            text = re.sub(r"\x1b\[[0-?]*[ -/]*[@-~]", "", text)
            if SENSITIVE_FIELD.search(text):
                self.sensitive_block = True
                safe = "[sensitive diagnostic omitted]"
            elif self.sensitive_block and not DIAGNOSTIC_START.search(text):
                safe = "[sensitive continuation omitted]"
            else:
                self.sensitive_block = False
                safe = safe_error_context(text)
        self.count += 1
        if len(self.head) < 8:
            self.head.append(safe)
        else:
            self.tail.append(safe)

    def report(self):
        return {"error_context": self.head + list(self.tail),
                "error_context_truncated": self.count > MAX_ERROR_CONTEXT_LINES or self.line_truncated}


def failure_hint(lines: list[str]) -> str:
    text = '\n'.join(lines).lower()
    if any(x in text for x in ('checksum', 'fingerprint', 'signature verification')):
        return 'integrity_or_trust_failure'
    if any(x in text for x in ('could not resolve host', 'connection reset', 'connection timed out',
                               'network connection was lost', 'failed to connect', 'http 502', 'http 503', 'http 504')):
        return 'possible_transient_network_failure'
    if any(x in text for x in ('version conflict', 'no versions of', 'requires minimum platform',
                               'missing package product', 'could not find package', 'invalid manifest')):
        return 'package_configuration_failure'
    return 'unclassified_dependency_failure'


def commands(root: Path, *, arm: bool, xcrun: str, explicit_project: bool = False,
             scm_provider: str | None = None) -> tuple[list[str], list[str]]:
    cache = str(root / "build/macos/SourcePackages")
    prefix = (["/usr/bin/arch", "-arm64e"] if arm else []) + [xcrun, "xcodebuild",
        "-clonedSourcePackagesDirPath", cache]
    if scm_provider == "system":
        prefix += ["-scmProvider", "system"]
    return (prefix + ["-resolvePackageDependencies"] + (["-project", "Runner.xcodeproj"] if explicit_project else []),
            prefix + ["-skipPackageUpdates", "-list", "-project", "Runner.xcodeproj"])


def stale_prefetches(ps_output: str, cache: Path, uid: int) -> tuple[list[int], list[int]]:
    """Match Flutter's exact prefetch argv and same-UID descendant tree.

    Flutter's prefetch argv has no -project, -workspace or -scheme. Its exact
    canonical cache directory uniquely binds it to this caller's project root.
    Extra/reordered flags and different caches are deliberately not matched.
    """
    processes, matched = {}, []
    for line in ps_output.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) != 4:
            continue
        try:
            pid, parent, owner = map(int, fields[:3])
            argv = shlex.split(fields[3])
        except (ValueError, TypeError):
            continue
        if owner != uid or pid in (0, 1, os.getpid()):
            continue
        processes[pid] = parent
        if (len(argv) == 4 and Path(argv[0]).name == "xcodebuild"
                and argv[1] == "-clonedSourcePackagesDirPath"
                and argv[3] == "-resolvePackageDependencies"
                and Path(argv[2]).resolve() == cache.resolve()):
            matched.append(pid)
    tree = set(matched)
    while True:
        children = {pid for pid, parent in processes.items() if parent in tree}
        if children <= tree:
            break
        tree |= children
    return sorted(matched), sorted(tree)


def cleanup_stale(cache: Path, environment: dict[str, str]) -> dict:
    try:
        result = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,uid=,command="],
            env=environment, stdin=subprocess.DEVNULL, capture_output=True, timeout=10, text=True, encoding="utf-8", errors="replace")
        if result.returncode:
            raise DiagnosticError("prefetch_process_inventory_failed")
        matched, tree = stale_prefetches(result.stdout, cache, os.getuid())
    except (OSError, subprocess.TimeoutExpired):
        raise DiagnosticError("prefetch_process_inventory_failed") from None
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in reversed(tree):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                pass
            except PermissionError:
                raise DiagnosticError("prefetch_process_cleanup_failed") from None
        if sig == signal.SIGTERM and tree:
            time.sleep(0.25)
    return {"enabled": True, "matched_prefetch_count": len(matched), "terminated_process_count": len(tree),
            "matched_prefetch_pids": matched, "terminated_process_pids": tree}


def terminate_group(process) -> None:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        if sig == signal.SIGTERM:
            try:
                process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                pass
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        raise DiagnosticError("process_tree_termination_failed") from None


def safe_process_tree(output: str, root_pid: int, uid: int) -> dict:
    """Read ps comm-only records and project a same-user descendant tree."""
    rows = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 5)
        if len(fields) != 6:
            continue
        try:
            pid, parent, owner = map(int, fields[:3])
            cpu, rss = float(fields[3]), int(fields[4])
        except ValueError:
            continue
        if owner != uid or pid <= 1 or not 0 <= cpu <= 100000 or not 0 <= rss <= 2**40:
            continue
        name = Path(fields[5]).name
        rows[pid] = {"pid": pid, "parent_pid": parent, "name": name if name in PROCESS_NAMES else "other",
                     "cpu_percent": cpu, "rss_kib": rss}
    tree = {root_pid} if root_pid in rows else set()
    while True:
        children = {pid for pid, row in rows.items() if row["parent_pid"] in tree}
        if children <= tree:
            break
        tree |= children
    return {"status": "complete", "root_observed": root_pid in rows,
            "process_count": len(tree), "processes": [rows[pid] for pid in sorted(tree)[:64]],
            "omitted_process_count": max(0, len(tree) - 64)}


def process_snapshot(root_pid: int, environment: dict[str, str]) -> dict:
    try:
        result = subprocess.run(["/bin/ps", "-axo", "pid=,ppid=,uid=,%cpu=,rss=,comm="],
            env=environment, stdin=subprocess.DEVNULL, capture_output=True, timeout=5, text=True, encoding="utf-8", errors="replace")
        if result.returncode:
            return {"status": "failed", "reason": "process_inventory_failed"}
        return safe_process_tree(result.stdout, root_pid, os.getuid())
    except (OSError, subprocess.TimeoutExpired):
        return {"status": "failed", "reason": "process_inventory_failed"}


def safe_shipped_symbol(symbol: str, image: str) -> str | None:
    if image not in SHIPPED_IMAGE_PRIORITY or any(ord(character) < 32 or ord(character) >= 127 for character in symbol):
        return None
    # sample usually prints offsets after the image; remove an exact numeric
    # offset before it too. Never retain a fragment of an otherwise unsafe name.
    symbol = re.sub(r"\s+\+\s+(?:0x[0-9a-f]+|[0-9]+)\s*$", "", symbol.strip(), flags=re.IGNORECASE)
    if (not re.fullmatch(r"[A-Za-z0-9_$:.<>\[\]() ,*+&!~#-]{1,160}", symbol)
            or not re.search(r"[A-Za-z_]", symbol)
            or re.search(r"0x[0-9a-f]+|\b(?:https?|ssh|file|smb):|\.(?:swift|mm|m|cc|cpp|cxx|hpp|hxx|h|c)(?::[0-9]+|[ )\]]|$)", symbol, re.IGNORECASE)):
        return None
    return symbol


def shipped_sample_symbols(output: bytes) -> dict:
    observed, rejected, in_callgraph = {}, 0, False
    for line in output.decode("utf-8", errors="replace").splitlines():
        if line.strip() == "Call graph:":
            in_callgraph = True
            continue
        if line.strip().startswith(("Binary Images:", "Total number in stack", "Sort by top of stack")):
            in_callgraph = False
        if not in_callgraph:
            continue
        frame = SAMPLE_FRAME.match(line)
        if frame is None:
            continue
        symbol = safe_shipped_symbol(frame[3], frame[4])
        if symbol is None:
            rejected += 1
            continue
        identity = frame[4], symbol
        observed[identity] = observed.get(identity, 0) + 1
    selected, per_image = [], {}
    for (image, symbol), count in sorted(observed.items(), key=lambda item: (
            SHIPPED_IMAGE_PRIORITY[item[0][0]], -item[1], item[0][0], item[0][1])):
        if len(selected) >= 32:
            break
        if per_image.get(image, 0) >= 8:
            continue
        per_image[image] = per_image.get(image, 0) + 1
        selected.append({"image": image, "symbol": symbol, "observed_count": count})
    return {"shipped_symbols": selected, "shipped_symbol_summary": {
        "output_count": len(selected), "eligible_unique_count": len(observed),
        "omitted_unique_count": len(observed) - len(selected), "rejected_frame_count": rejected,
        "positive_evidence_only": True, "absence_excludes_cause": False}}


def classify_sample(output: bytes) -> dict:
    """Return fixed counts/hints from recognized public frame contexts only.

    Sample's indentation describes call graph branches. Context from a sibling
    branch or another thread must not combine with a wait primitive. These are
    diagnostic hints, never a conclusion about a keychain or repository lock.
    """
    counts = {"parsed_frames": 0, "security_frames": 0, "manifest_compiler_frames": 0,
              "file_lock_frames": 0, "network_frames": 0, "generic_wait_frames": 0}
    hints = {"security_wait": False, "manifest_compiler_wait": False, "file_lock_wait": False, "network_wait": False}
    path = []
    frame = SAMPLE_FRAME
    for line in output.decode("utf-8", errors="replace").splitlines():
        if "Thread_" in line or line.strip() == "Call graph:":
            path.clear()
        match = frame.match(line)
        if not match:
            continue
        counts["parsed_frames"] += 1
        depth = len(match[1].expandtabs(2))
        while path and path[-1][0] >= depth:
            path.pop()
        symbol, image = match[3], match[4]
        security = (image in {"Security", "SecurityFoundation"}
                    and re.search(r"\b(?:SecItem\w*|SecKeychain\w*|SecAccessControl\w*)\b", symbol) is not None)
        manifest = (re.search(r"\b(?:ManifestLoader|PackageLoading|PackageDescription|CompilerInstance|performFrontend)\b", symbol) is not None
                    and any(name in image for name in ("SwiftPM", "Package", "swift-frontend", "swiftFrontend")))
        file_lock = (re.search(r"\bflock(?:\$\w+)?\b", symbol) is not None
                     and image == "libsystem_kernel.dylib")
        network = (image in {"CFNetwork", "Foundation", "Network", "libnetwork.dylib"}
                   and re.search(r"(?:NSURLSession|URLSession|NSCFURL|CFReadStream|CFWriteStream|nw_(?:connection|endpoint|path|protocol|socket|url))", symbol) is not None)
        wait = (image in {"libsystem_kernel.dylib", "libdispatch.dylib", "libsystem_pthread.dylib"}
                and re.search(r"\b(?:semaphore_wait_trap|mach_msg2?_trap|__psynch_mutexwait|__psynch_cvwait|__ulock_wait|_dispatch_semaphore_wait_slow|poll|select|kevent|connect|recvfrom|recvmsg)\b", symbol) is not None)
        facts = {"security": security, "manifest_compiler": manifest, "file_lock": file_lock, "network": network, "wait": wait}
        path.append((depth, facts))
        for key, present in (("security_frames", security), ("manifest_compiler_frames", manifest),
                             ("file_lock_frames", file_lock), ("generic_wait_frames", wait)):
            counts[key] += int(present)
        counts["network_frames"] += int(network)
        if any(facts["wait"] for _, facts in path):
            for key in ("security", "manifest_compiler", "file_lock", "network"):
                hints[key + "_wait"] |= any(facts[key] for _, facts in path)
    return {"classification_status": "known_frames_observed" if any(counts[key] for key in counts if key != "parsed_frames") else "unknown",
            "frame_counts": counts, "wait_hints": hints, "root_cause_established": False,
            "absence_excludes_cause": False, **shipped_sample_symbols(output)}


def sample_classification(output: bytes, *, complete: bool) -> dict:
    if not complete:
        output = output.rsplit(b"\n", 1)[0] if b"\n" in output else b""
    result = classify_sample(output)
    result.update(sample_complete=complete, classification_scope="complete_sample" if complete else "partial_prefix",
                  positive_evidence_only=not complete)
    if not complete:
        result["frame_counts"] = {key: value for key, value in result["frame_counts"].items() if value > 0}
        result["wait_hints"] = {key: value for key, value in result["wait_hints"].items() if value}
    return result


def bounded_sample_output(command: list[str], environment: dict[str, str]) -> tuple[dict, bytes]:
    """Capture at most 128 KiB in memory; the sample process has its own group."""
    summary = {"status": "failed", "duration_seconds": 1, "timeout_seconds": 5,
               "raw_stack_saved": False, "output_capped": False, "timed_out": False, "exit_code": None}
    try:
        process = subprocess.Popen(command, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, bufsize=0)
    except OSError:
        return {**summary, "reason": "sample_start_failed"}, b""
    data, started = bytearray(), time.monotonic()
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map() or process.poll() is None:
                if time.monotonic() - started >= 5:
                    summary.update(timed_out=True, reason="sample_timeout")
                    terminate_group(process)
                    break
                ready = selector.select(0.1)
                for key, _ in ready:
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if len(data) + len(chunk) > MAX_SAMPLE_BYTES:
                        summary.update(output_capped=True, reason="sample_output_limit")
                        terminate_group(process)
                        break
                    data.extend(chunk)
                if summary["output_capped"]:
                    break
        if process.poll() is None:
            terminate_group(process)
        summary["exit_code"] = process.returncode
        summary["output_bytes"] = len(data)
        if not summary.get("reason"):
            summary.update(status="complete" if process.returncode == 0 else "failed",
                           reason="sample_completed" if process.returncode == 0 else "sample_nonzero_exit")
    except (OSError, ValueError, DiagnosticError):
        try:
            terminate_group(process)
        except (OSError, DiagnosticError):
            pass
        summary["reason"] = "sample_capture_failed"
    finally:
        process.stdout.close()
    return summary, bytes(data)


def timeout_sample(process, environment: dict[str, str]) -> dict:
    """Sample only this still-live Popen PID after confirming its Darwin UID."""
    unavailable = {"status": "unavailable", "raw_stack_saved": False, "root_cause_established": False}
    if sys.platform != "darwin":
        return {**unavailable, "reason": "sample_requires_darwin"}
    if process.poll() is not None:
        return {**unavailable, "reason": "sample_target_exited"}
    try:
        owner = subprocess.run(["/bin/ps", "-p", str(process.pid), "-o", "uid="],
            env=environment, stdin=subprocess.DEVNULL, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=1)
        if owner.returncode or not owner.stdout.strip().isdigit() or int(owner.stdout.strip()) != os.getuid():
            return {**unavailable, "reason": "sample_target_uid_unconfirmed"}
        if process.poll() is not None:
            return {**unavailable, "reason": "sample_target_exited"}
    except (OSError, subprocess.TimeoutExpired):
        return {**unavailable, "reason": "sample_target_uid_unconfirmed"}
    # -file /dev/stdout prevents sample's default raw report file. The argument
    # vector contains only our numeric PID and fixed collection options.
    summary, raw = bounded_sample_output(["/usr/bin/sample", str(process.pid), "1", "10",
        "-file", "/dev/stdout"], environment)
    summary.update(sampled_pid=process.pid, same_uid_confirmed=True, root_cause_established=False)
    if raw:
        summary.update(sample_classification(raw, complete=summary["status"] == "complete"))
    return summary


def bounded_cache_metadata(anchor: Path, relative: str, *, entry_limit=MAX_CACHE_ENTRIES,
                           time_limit=CACHE_TIMEOUT_SECONDS) -> dict:
    """Count fixed-cache metadata via directory FDs; no paths/names leave here."""
    result = {"status": "complete", "exists": False, "entry_count": 0, "file_count": 0,
              "directory_count": 0, "regular_bytes": 0, "symlink_count": 0,
              "xcframework_count": 0, "zip_file_count": 0, "temporary_suffix_file_count": 0,
              "error_count": 0, "truncated": False}
    if os.open not in os.supports_dir_fd or os.scandir not in os.supports_fd or not hasattr(os, "O_NOFOLLOW"):
        return {**result, "status": "unavailable", "reason": "directory_fd_unsupported"}
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = None
    started = time.monotonic()
    try:
        descriptor = os.open(anchor, flags)
        for part in Path(relative).parts:
            next_fd = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_fd
        result["exists"] = True

        def walk(directory_fd, depth):
            if depth > 32:
                result.update(truncated=True, reason="cache_depth_limit")
                return
            with os.scandir(directory_fd) as entries:
                for entry in entries:
                    if result["entry_count"] >= entry_limit or time.monotonic() - started >= time_limit:
                        result.update(truncated=True, reason="cache_entry_limit" if result["entry_count"] >= entry_limit else "cache_time_limit")
                        return
                    result["entry_count"] += 1
                    try:
                        metadata = entry.stat(follow_symlinks=False)
                        if stat.S_ISLNK(metadata.st_mode):
                            result["symlink_count"] += 1
                        elif stat.S_ISDIR(metadata.st_mode):
                            result["directory_count"] += 1
                            result["xcframework_count"] += int(entry.name.endswith(".xcframework"))
                            child = os.open(entry.name, flags, dir_fd=directory_fd)
                            try:
                                walk(child, depth + 1)
                            finally:
                                os.close(child)
                        elif stat.S_ISREG(metadata.st_mode):
                            result["file_count"] += 1
                            result["regular_bytes"] += metadata.st_size
                            result["zip_file_count"] += int(entry.name.endswith(".zip"))
                            result["temporary_suffix_file_count"] += int(entry.name.endswith((".tmp", ".partial", ".download", ".crdownload")))
                    except OSError:
                        result["error_count"] += 1
                    if result["truncated"]:
                        return
        walk(descriptor, 0)
        if result["truncated"] or result["error_count"]:
            result["status"] = "partial"
    except FileNotFoundError:
        result.update(status="missing", reason="cache_missing")
    except OSError:
        result.update(status="unavailable", reason="cache_inaccessible_or_symlink")
    finally:
        if descriptor is not None:
            os.close(descriptor)
    result["elapsed_seconds"] = round(time.monotonic() - started, 2)
    return result


def cache_snapshot(root: Path) -> dict:
    result = {label: bounded_cache_metadata(root, "build/macos/SourcePackages/" + suffix)
              for label, suffix in (("project_artifacts", "artifacts"), ("project_checkouts", "checkouts"),
                                    ("project_repositories", "repositories"))}
    try:
        result["user_artifacts"] = bounded_cache_metadata(Path.home(), "Library/Caches/org.swift.swiftpm/artifacts")
    except (OSError, RuntimeError):
        result["user_artifacts"] = {"status": "unavailable", "reason": "home_directory_unavailable"}
    return result


def run_stage(name: str, argv: list[str], cwd: Path, environment: dict[str, str],
              timeout: float, *, heartbeat: float = 30, emit=print,
              capture: bytearray | None = None, observer=None, sampler=None) -> dict:
    emit(name + ": started", flush=True)
    started = time.monotonic()
    summary = {"phase": name, "status": "running", "timeout_seconds": timeout,
               "timed_out": False, "exit_code": None, "output_lines": 0,
               "progress_messages": 0, "warning_lines": 0, "error_lines": 0, "heartbeats": 0}
    try:
        process = subprocess.Popen(argv, cwd=cwd, env=environment, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, bufsize=0)
    except OSError:
        summary.update(status="failed", reason="process_start_failed", elapsed_seconds=0)
        return summary
    summary["pid"] = process.pid
    pending = bytearray()
    discarding_long_line = False
    next_heartbeat = started + heartbeat

    def observe():
        if observer is not None:
            snapshot = observer(process.pid, environment)
            snapshot["elapsed_seconds"] = round(time.monotonic() - started, 2)
            summary.setdefault("process_snapshots", []).append(snapshot)
            emit(name + ": process_snapshot " + json.dumps(snapshot, sort_keys=True), flush=True)

    context = ErrorContext()

    def consume(line: bytes):
        summary["output_lines"] += 1
        text = line.decode("utf-8", errors="replace")
        lower = text.lower()
        summary["warning_lines"] += int("warning:" in lower)
        summary["error_lines"] += int("error:" in lower)
        context.add(text)
        safe = safe_progress(text)
        if safe is not None:
            summary["progress_messages"] += 1
            emit(name + ": " + safe, flush=True)

    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while selector.get_map() or process.poll() is None:
                now = time.monotonic()
                if now - started >= timeout:
                    summary.update(timed_out=True, status="timed_out", reason="phase_timeout")
                    observe()
                    if sampler is not None:
                        try:
                            summary["timeout_sample"] = sampler(process, environment)
                        except Exception:
                            # Diagnostic sampling must never replace the original
                            # resolver timeout, or echo exception/stack contents.
                            summary["timeout_sample"] = {"status": "failed", "reason": "sample_unavailable",
                                "raw_stack_saved": False, "root_cause_established": False}
                    terminate_group(process)
                    break
                if now >= next_heartbeat:
                    summary["heartbeats"] += 1
                    emit(name + ": waiting (" + str(int(now - started)) + "s)", flush=True)
                    observe()
                    next_heartbeat = now + heartbeat
                for key, _ in selector.select(min(0.25, timeout - (now - started))):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    if capture is not None and len(capture) < MAX_CAPTURE_BYTES:
                        capture.extend(chunk[:MAX_CAPTURE_BYTES - len(capture)])
                    if discarding_long_line:
                        _, newline, chunk = chunk.partition(b"\n")
                        if not newline:
                            continue
                        discarding_long_line = False
                    pending.extend(chunk)
                    while b"\n" in pending:
                        line, _, rest = pending.partition(b"\n")
                        consume(line)
                        pending = bytearray(rest)
                    if len(pending) > 65536:
                        # Unbounded/no-newline output is discarded wholesale;
                        # partial credentials must not be emitted across chunks.
                        summary["output_lines"] += 1
                        context.add("x" * (MAX_ERROR_LINE_CHARS + 1))
                        discarding_long_line = True
                        pending.clear()
            if pending:
                consume(bytes(pending))
        if not summary["timed_out"]:
            process.wait(timeout=5)
        summary["exit_code"] = process.returncode
        if not summary["timed_out"]:
            summary.update(status="complete" if process.returncode == 0 else "failed",
                           reason="phase_completed" if process.returncode == 0 else "process_nonzero_exit")
    except (OSError, ValueError, DiagnosticError):
        terminate_group(process)
        summary.update(status="failed", reason="process_output_or_cleanup_failed", exit_code=process.returncode)
    finally:
        process.stdout.close()
    if summary["status"] != "complete":
        summary.update(context.report())
        lines = summary["error_context"]
        summary["failure_hint"] = failure_hint(lines)
        summary["root_cause_established"] = False
        for line in lines:
            emit(name + ": diagnostic " + line, flush=True)
    summary["elapsed_seconds"] = round(time.monotonic() - started, 2)
    emit(name + ": " + summary["status"], flush=True)
    return summary


def diagnostic_metadata(kind: str, output: bytes) -> dict:
    """Project numeric versions, the fixed generated package or public ref SHAs."""
    text = output.decode("utf-8", errors="replace")
    if kind in ("xcode_version", "swift_version"):
        pattern = r"(?m)^Xcode ([0-9]+(?:\.[0-9]+){0,3})\s*$" if kind == "xcode_version" else r"\bSwift version ([0-9]+(?:\.[0-9]+){0,3})(?:\s|$)"
        match = re.search(pattern, text)
        if not match:
            return {"metadata_status": "unavailable"}
        return {"metadata_status": "complete", "version": match[1]}
    if kind == "generated_package_dump":
        try:
            start = re.search(r"(?m)^\s*\{", text)
            if start is None:
                raise ValueError
            value, _ = json.JSONDecoder().raw_decode(text[start.start():].lstrip())
            if (not isinstance(value, dict) or value.get("name") != GENERATED_PACKAGE
                    or not all(isinstance(value.get(key), list) for key in ("targets", "dependencies", "products"))):
                raise ValueError
            safe = {"metadata_status": "complete", "schema": "swift-package-dump", "name": GENERATED_PACKAGE,
                    "target_count": len(value["targets"]), "dependency_count": len(value["dependencies"]),
                    "product_count": len(value["products"])}
            version = value.get("toolsVersion", {}).get("_version", "")
            if isinstance(version, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,3}", version):
                safe["tools_version"] = version
            return safe
        except (ValueError, TypeError, AttributeError):
            return {"metadata_status": "unavailable"}
    refs = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([0-9a-f]{40,64})\s+(HEAD|refs/heads/main)", line.strip())
        if match:
            refs["head_sha" if match[2] == "HEAD" else "main_sha"] = match[1]
    return {"metadata_status": "complete" if refs else "unavailable", **refs}


def preflight_diagnostics(root: Path, xcrun_prefix: list[str], environment: dict[str, str]) -> list[dict]:
    package = root / "macos/Flutter/ephemeral/Packages" / GENERATED_PACKAGE
    specifications = [
        ("xcode_version", [*xcrun_prefix, "xcodebuild", "-version"], root / "macos", 30),
        ("swift_version", [*xcrun_prefix, "swift", "--version"], root / "macos", 30),
        ("generated_package_dump", [*xcrun_prefix, "swift", "package", "dump-package"], package, 60),
        ("launch_at_login_remote", ["git", "ls-remote", "--exit-code",
            "https://github.com/sindresorhus/LaunchAtLogin.git", "HEAD", "refs/heads/main"], root, 30),
        ("sentry_cocoa_remote", ["git", "ls-remote", "--exit-code",
            "https://github.com/getsentry/sentry-cocoa.git", "HEAD"], root, 30),
        ("csqlite_remote", ["git", "ls-remote", "--exit-code",
            "https://github.com/simolus3/CSQLite.git", "HEAD"], root, 30),
    ]
    summaries = []
    for name, command, cwd, timeout in specifications:
        if name == "generated_package_dump" and not (package / "Package.swift").is_file():
            summary = {"phase": name, "status": "failed", "reason": "generated_package_missing",
                       "timed_out": False, "exit_code": None}
        else:
            capture = bytearray()
            try:
                summary = run_stage(name, command, cwd, environment, timeout, capture=capture)
                summary.update(diagnostic_metadata(name, bytes(capture)))
            except (DiagnosticError, OSError, ValueError):
                summary = {"phase": name, "status": "failed", "reason": "diagnostic_unavailable",
                           "timed_out": False, "exit_code": None}
            finally:
                capture.clear()
        if name == "csqlite_remote":
            # Context from sqlite3_flutter_libs 0.5.42's manifest. A successful
            # HEAD lookup does not prove this pinned revision was fetched or
            # selected by Xcode; the resolver's own result remains independent.
            summary["required_revision"] = CSQLITE_REQUIRED_REVISION
        summaries.append(summary)
        # Failed summaries may include bounded sanitized diagnostic context.
        print("diagnostic: " + json.dumps(summary, sort_keys=True), flush=True)
    return summaries


def write_report(path: Path, report: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path("."))
    parser.add_argument("--report", type=Path, default=Path("build/sentry-package-resolution.json"))
    parser.add_argument("--resolve-timeout", type=int, default=600)
    parser.add_argument("--list-timeout", type=int, default=120)
    parser.add_argument("--cleanup-stale-prefetch", action="store_true")
    parser.add_argument("--explicit-project", action="store_true", help="Diagnose explicit project selection instead of Flutter's implicit container")
    parser.add_argument("--sample-on-timeout", action="store_true", help="Optional same-UID 1s sample; fixed safe hints only")
    parser.add_argument("--scm-provider", choices=("system",), help="Optional explicit SCM provider; default leaves Xcode unchanged")
    args = parser.parse_args(argv)
    report = {"schema_version": 1, "kind": "macos_foreground_package_resolution", "status": "not_started",
              "build_performed": False, "stages": [], "diagnostics": [],
              "sample_on_timeout": args.sample_on_timeout, "stack_sample_performed": False,
              "explicit_project": args.explicit_project,
              "scm_provider": args.scm_provider or "default", "cache_snapshots": [],
              "cleanup": {"enabled": args.cleanup_stale_prefetch}}
    try:
        if sys.platform != "darwin":
            raise DiagnosticError("darwin_required")
        if not 1 <= args.resolve_timeout <= 3600 or not 1 <= args.list_timeout <= 600:
            raise DiagnosticError("invalid_timeout")
        root = args.project_root.resolve()
        if not (root / "macos/Runner.xcodeproj/project.pbxproj").is_file():
            raise DiagnosticError("runner_project_missing")
        xcrun = shutil.which("xcrun")
        if not xcrun:
            raise DiagnosticError("xcrun_unavailable")
        environment = child_environment(dict(os.environ))
        if args.cleanup_stale_prefetch:
            try:
                report["cleanup"] = cleanup_stale(root / "build/macos/SourcePackages", environment)
            except DiagnosticError as error:
                report["cleanup"] = {"enabled": True, "status": "failed", "reason": str(error)}
        resolve, listing = commands(root, arm=platform.machine().lower() in ("arm64", "aarch64"), xcrun=xcrun,
                                   explicit_project=args.explicit_project, scm_provider=args.scm_provider)
        report["diagnostics"] = preflight_diagnostics(root, resolve[:resolve.index("xcodebuild")], environment)
        write_report(args.report, report)
        for name, command, timeout in (("resolve", resolve, args.resolve_timeout), ("list", listing, args.list_timeout)):
            if name == "resolve":
                report["cache_snapshots"].append({"point": "before_resolve", "caches": cache_snapshot(root)})
                write_report(args.report, report)
            summary = run_stage(name, command, root / "macos", environment, timeout, observer=process_snapshot,
                                sampler=timeout_sample if args.sample_on_timeout else None)
            report["stages"].append(summary)
            if name == "resolve":
                report["cache_snapshots"].append({"point": "after_resolve", "caches": cache_snapshot(root)})
            report["stack_sample_performed"] |= "sampled_pid" in summary.get("timeout_sample", {})
            write_report(args.report, report)
            if summary["status"] != "complete":
                raise DiagnosticError(name + "_phase_failed")
        report["status"] = "complete"
        write_report(args.report, report)
        print("macOS package diagnostics: complete; build not performed", flush=True)
        return 0
    except DiagnosticError as error:
        report.update(status="failed", reason=str(error))
        write_report(args.report, report)
        print("macOS package diagnostics: " + str(error), flush=True)
        return 1
    except OSError:
        print("macOS package diagnostics: report_io_failed", flush=True)
        return 1


if __name__ == "__main__":
    sys.exit(main())
