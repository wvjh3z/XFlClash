#!/usr/bin/env python3
"""Choose a real built native instruction and its locally resolved source line.

Consumes uploaded build evidence and the original native manifest. No event is
sent. The output contains only module identity, a relative address, and expected
function/source basename/line; local artifact and source paths stay private.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import signal
import struct
import subprocess
import sys
import time

from sentry_macho import inspect_macho


class ProbeError(RuntimeError):
    pass


def _bounded_native_run(argv, *, timeout, max_output_bytes, observations=None):
    """Darwin/POSIX native lookups: raw output stays in bounded memory only."""
    process = None
    output, errors = bytearray(), bytearray()
    observation = {"status": "failed", "exit_code": None, "timed_out": False,
                   "output_limit": False, "stdout_bytes": 0, "stderr_bytes": 0, "stderr_categories": [],
                   "positive_evidence_only": True}
    if observations is not None:
        observations.append(observation)
    try:
        process = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, (output, max_output_bytes))
            selector.register(process.stderr, selectors.EVENT_READ, (errors, 65536))
            while selector.get_map() or process.poll() is None:
                if time.monotonic() >= deadline:
                    observation["timed_out"] = True
                    raise ProbeError("native_lookup_timeout")
                for key, _ in selector.select(min(.1, max(0, deadline - time.monotonic()))):
                    buffer, limit = key.data
                    chunk = os.read(key.fileobj.fileno(), min(65536, limit - len(buffer) + 1))
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    available = limit - len(buffer)
                    buffer.extend(chunk[:available])
                    if len(chunk) > available:
                        observation["output_limit"] = True
                        raise ProbeError("native_lookup_output_limit")
        observation["exit_code"] = process.poll()
        if process.returncode:
            raise ProbeError("native_lookup_tool_failed")
        observation["status"] = "complete"
        return output.decode("utf-8", errors="replace")
    except (OSError, ValueError):
        raise ProbeError("native_lookup_tool_failed") from None
    finally:
        if process is not None:
            for signum in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(process.pid, signum)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=.5)
                except subprocess.TimeoutExpired:
                    pass
            observation["exit_code"] = process.poll()
            process.stdout.close()
            process.stderr.close()
        lower = bytes(errors).lower()
        observation.update(stdout_bytes=len(output), stderr_bytes=len(errors), stderr_categories=[
            name for name, needles in (
                ("architecture_mismatch", (b"architecture", b"arch not found")),
                ("file_unavailable", (b"no such file", b"cannot open", b"unable to open")),
                ("debug_info_unavailable", (b"no debug", b"debug information", b"no symbols")),
                ("usage_error", (b"usage:", b"unrecognized option", b"unknown argument")),
                ("permission_denied", (b"permission denied", b"operation not permitted")))
            if any(needle in lower for needle in needles)])


def run(argv: list[str], *, timeout=120, max_output_bytes=None, observations=None) -> str:
    if max_output_bytes is not None:
        return _bounded_native_run(argv, timeout=timeout, max_output_bytes=max_output_bytes, observations=observations)
    try:
        result = subprocess.run(argv, capture_output=True, text=True,
                                encoding="utf-8", errors="replace", timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ProbeError("native_lookup_tool_failed") from error
    if result.returncode:
        raise ProbeError("native_lookup_tool_failed")
    return result.stdout


def find_tool(name: str, *, timeout=120) -> str:
    """Use installed native tools only, including Apple/Visual Studio LLVM."""
    executable = shutil.which(name)
    if executable:
        return executable
    if sys.platform == "darwin":
        try:
            found = run(["xcrun", "--find", name], timeout=timeout, max_output_bytes=65536).strip()
            if found and Path(found).is_file():
                return found
        except ProbeError:
            pass
    if os.name == "nt":
        roots = [Path(os.environ[key]) for key in ("ProgramFiles", "ProgramFiles(x86)")
                 if os.environ.get(key)]
        candidates = [root / "LLVM/bin" / (name + ".exe") for root in roots]
        for root in roots:
            vswhere = root / "Microsoft Visual Studio/Installer/vswhere.exe"
            if vswhere.is_file():
                for installation in run([str(vswhere), "-all", "-products", "*",
                                         "-property", "installationPath"]).splitlines():
                    for subdir in ("VC/Tools/Llvm/bin", "VC/Tools/Llvm/x64/bin"):
                        candidates.append(Path(installation) / subdir / (name + ".exe"))
        for candidate in candidates:
            if candidate.is_file():
                return str(candidate)
    raise ProbeError("required_native_tool_unavailable_" + name)


def basename(value: str) -> str:
    return value.replace("\\", "/").rsplit("/", 1)[-1]


def source_location(function: str, location: str) -> dict | None:
    match = re.match(r"^(.*?):(\d+)(?::\d+)?(?:\s.*)?$", location.strip())
    if not match or int(match[2]) < 1 or function.strip() in ("", "??", "?"):
        return None
    filename = basename(match[1])
    if filename in ("", "??", "?"):
        return None
    # CLI function names can contain source paths (e.g. Swift context). Avoid
    # carrying private paths into evidence, even if local tools include them.
    function = function.strip()
    if "/" in function or "\\" in function or "\n" in function:
        return None
    return {"function": function, "filename": filename, "lineno": int(match[2])}


def symbols(output: str) -> list[tuple[int, str]]:
    result = []
    for line in output.splitlines():
        match = re.match(r"^\s*([0-9a-fA-F]+)\s+[tT]\s+(.+?)\s*$", line)
        if match:
            result.append((int(match[1], 16), match[2]))
    def rank(item):
        name = item[1].lstrip("_")
        if name in ("main", "wWinMain", "WinMain"):
            return 0
        if any(word in name for word in ("MainFlutterWindow", "AppDelegate", "RegisterWithRegistrar")):
            return 1
        return 2
    return sorted(result, key=rank)


def elf_layout(path: Path) -> tuple[int, list[tuple[int, int]], int]:
    """Return unslid image base and executable virtual ranges from PT_LOAD."""
    with path.open("rb") as stream:
        head = stream.read(64)
        if head[:4] != b"\x7fELF" or head[4] not in (1, 2) or head[5] not in (1, 2):
            raise ProbeError("invalid_final_elf")
        endian = "<" if head[5] == 1 else ">"
        wide = head[4] == 2
        header = struct.unpack_from(endian + ("HHIQQQIHHHHHH" if wide else "HHIIIIIHHHHHH"), head, 16)
        phoff, stride, count = header[4], header[8], header[9]
        fmt = struct.Struct(endian + ("IIQQQQQQ" if wide else "IIIIIIII"))
        if stride < fmt.size or not 0 < count < 65536:
            raise ProbeError("invalid_final_elf_segments")
        loads, executable, ends = [], [], []
        for index in range(count):
            stream.seek(phoff + index * stride)
            values = fmt.unpack(stream.read(fmt.size))
            if values[0] != 1:
                continue
            flags, address, size = (values[1], values[3], values[6]) if wide else (values[6], values[2], values[5])
            loads.append(address & ~0xfff)
            ends.append(address + size)
            if flags & 1:
                executable.append((address, address + size))
    if not loads or not executable:
        raise ProbeError("final_elf_has_no_executable_load")
    return min(loads), executable, max(ends) - min(loads)


def in_ranges(address: int, ranges: list[tuple[int, int]]) -> bool:
    return any(start <= address < stop for start, stop in ranges)


def pick_elf(binary: Path, debug: Path) -> tuple[int, dict]:
    base, ranges, _ = elf_layout(binary)
    candidates = symbols(run([find_tool("nm"), "-n", "-C", str(debug)]))
    addr2line = find_tool("addr2line")
    # Symbol starts are actual instruction boundaries; do not invent offsets.
    for address, _ in candidates[:1000]:
        if not in_ranges(address, ranges):
            continue
        output = run([addr2line, "-f", "-C", "-e", str(debug), hex(address)]).splitlines()
        if len(output) >= 2:
            expected = source_location(output[0], output[1])
            if expected:
                return address - base, expected
    raise ProbeError("no_native_instruction_with_source_line")


def atos_output_shape(output: str) -> str:
    """Classify only; never carry local tool text into diagnostic evidence."""
    value = output.strip()
    if not value:
        return "empty_output"
    if len(value.splitlines()) != 1:
        return "multiple_lines"
    if re.fullmatch(r"0x[0-9a-fA-F]+", value):
        return "address_only"
    if re.fullmatch(r".*? \(in .*?\) \(.*?:\d+(?::\d+)?\)(?: \+ \d+)?", value):
        if re.search(r"\) \+ \d+$", value):
            return "source_location_with_offset"
        if re.search(r":\d+:\d+\)$", value):
            return "source_location_with_column"
        return "source_location"
    if re.fullmatch(r".*? \(in .*?\) \+ \d+", value):
        return "symbol_offset_only"
    if re.fullmatch(r".*? \(in .*?\)", value):
        return "symbol_without_source"
    return "unclassified_output"


def nm_output_shapes(output: str) -> dict:
    return {"text_rows": len(symbols(output)),
            "stab_function_rows": sum(bool(re.search(r"\s-\s+[0-9a-fA-F]{2}\s+[0-9a-fA-F]{4}\s+FUN\s", line))
                                      for line in output.splitlines()),
            "header_rows": sum(line.rstrip().endswith(":") for line in output.splitlines())}


def parse_atos_source(output: str) -> dict | None:
    match = re.fullmatch(r"(.*?) \(in .*?\) \((.*?:\d+(?::\d+)?)\)(?: \+ \d+)?", output.strip())
    return source_location(match[1], match[2]) if match else None


def pick_macho(binary: Path, debug: Path, architecture: str, *, diagnostics=None,
               candidate_limit=1000, lookup_timeout=120, total_timeout=120) -> tuple[int, dict]:
    deadline = time.monotonic() + total_timeout
    details = diagnostics if diagnostics is not None else {}
    details.update(stage="layout", nm_line_count=0, nm_candidate_count=0, in_range_candidate_count=0,
                   candidate_limit=candidate_limit, attempts=0, atos_output_shapes={}, native_calls=[],
                   candidate_sources=[], selected_candidate_source=None, deadline_exhausted=False)
    def remaining_timeout():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            details.update(stage="lookup_deadline_exhausted", deadline_exhausted=True)
            raise ProbeError("native_lookup_deadline_exhausted")
        return min(remaining, lookup_timeout)
    variant = next((item for item in inspect_macho(binary)["variants"]
                    if item["architecture"] == architecture), None)
    if not variant:
        raise ProbeError("final_macho_architecture_missing")
    text = next((segment for segment in variant["segments"] if segment["name"] == "__TEXT"), None)
    if not text:
        raise ProbeError("final_macho_text_missing")
    base = text["vmaddr"]
    ranges = [(section["addr"], section["addr"] + section["size"])
              for section in variant["sections"] if section["segment"] == "__TEXT"
              and (section["name"] == "__text" or section["flags"] & 0x80000400)]
    details["executable_range_count"] = len(ranges)
    details["stage"] = "nm_tool_lookup"
    nm = find_tool("nm", timeout=remaining_timeout())
    details["stage"] = "atos_tool_lookup"
    atos = find_tool("atos", timeout=remaining_timeout())
    seen = set()
    # The final image's symbol table supplies actual function boundaries even
    # when nm renders dSYM entries as STABS or omits a conventional T table.
    # Stripped images can still fall back to their fingerprint-matched dSYM.
    for candidate_source, symbol_file in (("runtime", binary), ("dsym", debug)):
        details["stage"] = "nm_" + candidate_source + "_lookup"
        try:
            output = run([nm, "-n", "-arch", architecture, str(symbol_file)], timeout=remaining_timeout(),
                         max_output_bytes=8 * 1024 * 1024, observations=details["native_calls"])
        except ProbeError as error:
            if candidate_source != "runtime" or str(error) != "native_lookup_tool_failed":
                raise
            details["candidate_sources"].append(dict(source="runtime", status="failed",
                failure="native_lookup_tool_failed", candidate_count=0, in_range_count=0))
            continue
        candidates = symbols(output)
        details["candidate_sources"].append(dict(source=candidate_source, line_count=len(output.splitlines()),
            candidate_count=len(candidates), in_range_count=sum(in_ranges(address, ranges) for address, _ in candidates),
            output_shapes=nm_output_shapes(output)))
        details["nm_line_count"] += len(output.splitlines())
        details["nm_candidate_count"] += len(candidates)
        details["in_range_candidate_count"] += sum(in_ranges(address, ranges) for address, _ in candidates)
        for address, _ in candidates:
            if address in seen or not in_ranges(address, ranges):
                continue
            if details["attempts"] >= candidate_limit:
                break
            call_timeout = remaining_timeout()
            seen.add(address)
            details["stage"] = "atos_lookup"
            details["attempts"] += 1
            output = run([atos, "-o", str(debug), "-arch", architecture,
                          "-l", hex(base), hex(address)], timeout=call_timeout,
                         max_output_bytes=65536, observations=details["native_calls"]).strip()
            shape = atos_output_shape(output)
            details["atos_output_shapes"][shape] = details["atos_output_shapes"].get(shape, 0) + 1
            expected = parse_atos_source(output)
            if expected:
                details.update(stage="source_line_selected", selected_candidate_source=candidate_source)
                return address - base, expected
        if details["attempts"] >= candidate_limit:
            break
    details["stage"] = "source_line_unavailable"
    raise ProbeError("no_native_instruction_with_source_line")


def dwarf_positive_line_rows(output: str) -> list[tuple[int, int]]:
    """Read actual line-table PCs, excluding zero rows and end_sequence marks."""
    rows = set()
    for line in output.splitlines():
        match = re.match(r"^\s*0x([0-9a-fA-F]+)\s+(\d+)\s+\d+\s+\d+\s+", line)
        if match and int(match[2]) > 0 and "end_sequence" not in line:
            rows.add((int(match[1], 16), int(match[2])))
    return sorted(rows)


def diagnose_macho_line_rows(binary: Path, debug: Path, architecture: str, *, candidate_limit=12,
                              lookup_timeout=10) -> dict:
    """A diagnostic only: compare real line PCs with entries, never invent offsets."""
    details = dict(status="failed", stage="layout", native_calls=[], positive_row_count=0,
                   in_range_row_count=0, runtime_entry_positive_rows=0, attempts=0,
                   source_line_resolutions=0, line_number_matches=0, atos_output_shapes={})
    try:
        variant = next(item for item in inspect_macho(binary)["variants"] if item["architecture"] == architecture)
        base = next(segment["vmaddr"] for segment in variant["segments"] if segment["name"] == "__TEXT")
        ranges = [(section["addr"], section["addr"] + section["size"]) for section in variant["sections"]
                  if section["segment"] == "__TEXT" and (section["name"] == "__text" or section["flags"] & 0x80000400)]
        details["stage"] = "line_table_lookup"
        output = run([find_tool("dwarfdump"), "--debug-line", "--arch=" + architecture, str(debug)],
                     timeout=lookup_timeout, max_output_bytes=2 * 1024 * 1024, observations=details["native_calls"])
        rows = dwarf_positive_line_rows(output)
        executable = [(address, line) for address, line in rows if in_ranges(address, ranges)]
        details.update(positive_row_count=len(rows), in_range_row_count=len(executable))
        details["stage"] = "runtime_entry_lookup"
        entries = symbols(run([find_tool("nm"), "-n", "-arch", architecture, str(binary)], timeout=lookup_timeout,
                              max_output_bytes=8 * 1024 * 1024, observations=details["native_calls"]))
        entry_set = {address for address, _ in entries}
        details["runtime_entry_positive_rows"] = sum(address in entry_set for address, _ in executable)
        details["stage"] = "line_pc_atos_lookup"
        atos = find_tool("atos")
        for address, line in executable[:candidate_limit]:
            details["attempts"] += 1
            output = run([atos, "-o", str(debug), "-arch", architecture, "-l", hex(base), hex(address)],
                         timeout=lookup_timeout, max_output_bytes=65536, observations=details["native_calls"])
            shape = atos_output_shape(output)
            details["atos_output_shapes"][shape] = details["atos_output_shapes"].get(shape, 0) + 1
            source = parse_atos_source(output)
            if source:
                details["source_line_resolutions"] += 1
                details["line_number_matches"] += source["lineno"] == line
                break
        details.update(status="complete", stage="line_pc_diagnostic_complete")
    except Exception:
        # Stage and bounded command observations retain evidence without
        # emitting tool text or pretending a missing category excludes a cause.
        details["reason"] = "line_pc_diagnostic_failed"
    return details


def pe_exports(path: Path) -> list[tuple[int, str]]:
    """Read actual PE export RVAs, rejecting forwarders/non-code sections."""
    data = path.read_bytes()
    pe = struct.unpack_from("<I", data, 0x3c)[0]
    if data[:2] != b"MZ" or data[pe:pe+4] != b"PE\0\0":
        raise ProbeError("invalid_final_pe")
    count, optional_size = struct.unpack_from("<H12xH", data, pe + 6)
    optional = pe + 24
    magic = struct.unpack_from("<H", data, optional)[0]
    directory = optional + {0x10b: 96, 0x20b: 112}.get(magic, 0)
    if directory == optional:
        raise ProbeError("invalid_pe_optional_header")
    export_rva, export_size = struct.unpack_from("<II", data, directory)
    sections = []
    for index in range(count):
        row = optional + optional_size + index * 40
        vsize, rva, rawsize, offset = struct.unpack_from("<IIII", data, row + 8)
        flags = struct.unpack_from("<I", data, row + 36)[0]
        sections.append((rva, max(vsize, rawsize), offset, rawsize, flags))
    def offset(rva: int) -> int:
        for start, _, fileoff, rawsize, _ in sections:
            if start <= rva < start + rawsize:
                return fileoff + rva - start
        raise ProbeError("invalid_pe_export_rva")
    if not export_rva:
        return []
    table = offset(export_rva)
    functions, names, ordinals = struct.unpack_from("<III", data, table + 28)
    name_count = struct.unpack_from("<I", data, table + 24)[0]
    if name_count > 100000:
        raise ProbeError("invalid_pe_exports")
    result = []
    for index in range(name_count):
        name_rva = struct.unpack_from("<I", data, offset(names) + index * 4)[0]
        name_start = offset(name_rva)
        name_end = data.find(b"\0", name_start, name_start + 4096)
        if name_end < 0:
            raise ProbeError("invalid_pe_export_name")
        name = data[name_start:name_end].decode("ascii")
        ordinal = struct.unpack_from("<H", data, offset(ordinals) + index * 2)[0]
        address = struct.unpack_from("<I", data, offset(functions) + ordinal * 4)[0]
        if export_rva <= address < export_rva + export_size:
            continue
        if any(start <= address < start + size and flags & 0x20000000
               for start, size, _, _, flags in sections):
            result.append((address, name))
    return sorted(result, key=lambda item: "RegisterWithRegistrar" not in item[1])


def pick_pe(binary: Path, debug: Path) -> tuple[int, dict]:
    try:
        symbolizer = find_tool("llvm-symbolizer")
    except ProbeError:
        symbolizer = None
    # LLVM follows the PE CodeView reference to its PDB; match is established
    # by the audited manifest, fingerprints and the PDB ID in uploaded evidence.
    # Build PDB and PE remain in their original build locations.
    for address, name in pe_exports(binary):
        if symbolizer is None:
            if name == "FlutterInappwebviewWindowsPluginCApiRegisterWithRegistrar":
                # The export is defined by this project dependency source file.
                # Zero explicitly means no local line oracle: server must return
                # a positive source line; never claim a fabricated exact line.
                return address, {"function": name,
                                 "filename": "flutter_inappwebview_windows_plugin_c_api.cpp",
                                 "lineno": 0}
            continue
        output = run([symbolizer, "--obj=" + str(binary), "--relative-address",
                      "--no-inlines", hex(address)]).splitlines()
        if len(output) >= 2:
            expected = source_location(output[0], output[1])
            if expected:
                return address, expected
    raise ProbeError("no_pe_export_with_matching_pdb_source_line")


def image_layout(binary: Path, platform: str, architecture: str) -> tuple[int, int]:
    if platform == "linux":
        base, _, size = elf_layout(binary)
        return base, size
    if platform == "macos":
        variant = next(item for item in inspect_macho(binary)["variants"]
                       if item["architecture"] == architecture)
        base = next(item["vmaddr"] for item in variant["segments"] if item["name"] == "__TEXT")
        return base, max(item["vmaddr"] + item["vmsize"] for item in variant["segments"]) - base
    with binary.open("rb") as stream:
        stream.seek(0x3c)
        pe = struct.unpack("<I", stream.read(4))[0]
        stream.seek(pe + 24)
        optional = stream.read(64)
    magic = struct.unpack_from("<H", optional)[0]
    if magic == 0x20b:
        base = struct.unpack_from("<Q", optional, 24)[0]
    elif magic == 0x10b:
        base = struct.unpack_from("<I", optional, 28)[0]
    else:
        raise ProbeError("invalid_pe_optional_header")
    return base, struct.unpack_from("<I", optional, 56)[0]


def fingerprint_matches(path: Path, expected: dict) -> bool:
    if not path.is_file() or path.name != expected.get("name") or path.stat().st_size != expected.get("bytes"):
        return False
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest() == expected.get("sha256")


def safe_path(root: Path, value: str) -> Path:
    path = (root / value).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ProbeError("artifact_escaped_build_root")
    return path


def select(evidence: dict, build_root: Path, architecture: str | None = None,
           target: str | None = None) -> dict:
    platform = evidence.get("platform")
    if evidence.get("status") != "uploaded_and_processed" or platform not in ("linux", "macos", "windows"):
        raise ProbeError("uploaded_desktop_symbol_evidence_required")
    native = evidence.get("native", [])
    if platform == "windows":
        manifests = list((build_root / "windows").glob("**/sentry-symbols/Release/targets.tsv"))
        if len(manifests) != 1:
            raise ProbeError("one_windows_native_manifest_required")
        records = []
        for row in manifests[0].read_text(encoding="utf-8").splitlines():
            fields = row.split("\t")
            if len(fields) != 3:
                raise ProbeError("invalid_windows_native_manifest")
            records.append(dict(target=fields[0], binary=fields[1], debug_file=fields[2]))
        # The source-built plugin's C export has an exact instruction RVA.
        records.sort(key=lambda item: item["target"] != "flutter_inappwebview_windows_plugin")
    else:
        manifest = json.loads((build_root / "sentry-native" / platform / "manifest.json").read_text(encoding="utf-8"))
        if manifest.get("platform") != platform or manifest.get("schema_version") != 1:
            raise ProbeError("invalid_native_manifest")
        records = [item for item in manifest.get("artifacts", []) if item.get("source") in ("cmake", "runner", "source", "spm", "pods")]
        records.sort(key=lambda item: (item["target"].lower() not in ("flclash", "runner"), item["target"]))
    if target is not None:
        records = [record for record in records if record["target"] == target
                   and (platform != "windows" or target == "flutter_inappwebview_windows_plugin")]
        if not records:
            raise ProbeError("requested_source_built_target_unavailable")
    errors = []
    for record in records:
        # Never probe a separately executing Go helper or a vendor module.
        if platform == "windows" and record["target"] != "flutter_inappwebview_windows_plugin":
            continue
        matches = [item for item in native if item.get("target") == record["target"]
                   and (not record.get("architecture") or item.get("architecture") == record["architecture"])]
        for item in matches:
            arch = item.get("architecture") or next(iter(item.get("architectures", [])), None)
            if not arch or (architecture and arch != architecture):
                continue
            binary, debug = (safe_path(build_root, record[key]) for key in ("binary", "debug_file"))
            if not fingerprint_matches(binary, item.get("binary", {})) or not fingerprint_matches(debug, item.get("symbols", {})):
                raise ProbeError("artifact_changed_since_symbol_upload")
            identifiers = item.get("debug_ids", [])
            if len(identifiers) != 1 or not re.fullmatch(r"[a-fA-F0-9-]+", identifiers[0]):
                raise ProbeError("one_native_debug_id_required")
            try:
                if platform == "linux":
                    address, expected = pick_elf(binary, debug)
                elif platform == "macos":
                    address, expected = pick_macho(binary, debug, arch)
                else:
                    address, expected = pick_pe(binary, debug)
            except ProbeError as error:
                errors.append(str(error))
                continue
            base, image_size = image_layout(binary, platform, arch)
            return {"schema_version": 1, "platform": platform,
                    "module": {"target": record["target"], "architecture": arch,
                               "debug_id": identifiers[0], "code_file": binary.name,
                               "debug_file": debug.name, "image_size": image_size,
                               "image_vmaddr": hex(base) if platform != "windows" else "0x0",
                               "binary_path": binary.relative_to(build_root.resolve()).as_posix(),
                               "symbols_path": debug.relative_to(build_root.resolve()).as_posix()},
                    "frame": {"instruction_addr": hex(address), "addr_mode": "rel:0"},
                    "expected": expected}
    raise ProbeError(errors[0] if errors else "requested_source_built_target_unavailable"
                     if target is not None else "no_uploaded_source_built_module_available")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, default=Path("build/sentry-symbols-evidence.json"))
    parser.add_argument("--build-root", type=Path, default=Path("build"))
    parser.add_argument("--architecture")
    parser.add_argument("--target", help="Require this audited source-built target; never select another target")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
        selection = select(evidence, args.build_root, args.architecture, args.target)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(selection, indent=2) + "\n", encoding="utf-8")
    except (OSError, ValueError, KeyError, TypeError, struct.error, ProbeError) as error:
        reason = str(error) if isinstance(error, ProbeError) else "invalid_symbol_artifact_or_evidence"
        print("Native probe selection failed: " + reason, file=sys.stderr)
        return 1
    print("Native probe selection written; no event sent")
    return 0


if __name__ == "__main__":
    sys.exit(main())
