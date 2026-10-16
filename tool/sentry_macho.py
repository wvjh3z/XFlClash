"""Minimal offline Mach-O UUID/architecture/DWARF inventory for symbol checks."""

from __future__ import annotations

import mmap
from pathlib import Path
import struct
import uuid


class MachoError(ValueError):
    pass


THIN = {b"\xce\xfa\xed\xfe": ("<", False), b"\xcf\xfa\xed\xfe": ("<", True),
        b"\xfe\xed\xfa\xce": (">", False), b"\xfe\xed\xfa\xcf": (">", True)}
FAT = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
       b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}
ARCHIVE_MAGIC = b"!<arch>\n"


def is_macho(path: Path) -> bool:
    with path.open("rb") as stream:
        # Keep this a magic probe. App runtime enumeration must send every FAT
        # candidate through strict inspect_macho, including an invalid archive
        # substituted for a formerly dynamic Pod/framework.
        return stream.read(4) in THIN.keys() | FAT.keys()


def _fat_entries(data):
    if len(data) < 8 or data[:4] not in FAT:
        raise MachoError("Invalid universal Mach-O header")
    endian, wide = FAT[data[:4]]
    count = struct.unpack_from(endian + "I", data, 4)[0]
    entry = struct.Struct(endian + ("iiQQII" if wide else "iiIII"))
    end = 8 + count * entry.size
    if not 0 < count <= 64 or end > len(data):
        raise MachoError("Invalid universal Mach-O header")
    result, ranges, cpus = [], [], set()
    for index in range(count):
        info = entry.unpack_from(data, 8 + index * entry.size)
        offset, size, alignment = info[2:5]
        if (offset < end or not size or offset + size > len(data)
                or alignment > 31 or offset % (1 << alignment)):
            raise MachoError("Invalid universal Mach-O slice bounds")
        if any(offset < stop and offset + size > begin for begin, stop in ranges):
            raise MachoError("Overlapping universal Mach-O slices")
        cpu = (info[0], info[1] & 0x00ffffff)
        if cpu in cpus:
            raise MachoError("Duplicate universal Mach-O CPU")
        cpus.add(cpu)
        ranges.append((offset, offset + size))
        result.append((info[0], info[1], offset, size))
    return result


def _archive_architectures(data, start, size, expected_cpu=None):
    stop = start + size
    if size < 8 or stop > len(data) or data[start:start + 8] != ARCHIVE_MAGIC:
        raise MachoError("Invalid static archive header")
    cursor, members, architectures, names = start + 8, 0, set(), b""
    while cursor < stop:
        members += 1
        if members > 100000 or cursor + 60 > stop:
            raise MachoError("Invalid static archive member table")
        header = data[cursor:cursor + 60]
        if header[58:60] != b"`\n" or not header[48:58].strip().isdigit():
            raise MachoError("Invalid static archive member header")
        if (any(field.strip() and not field.strip().isdigit() for field in
                (header[16:28], header[28:34], header[34:40]))
                or any(value not in b"01234567 " for value in header[40:48])):
            raise MachoError("Invalid static archive member metadata")
        width = int(header[48:58].strip())
        payload, end = cursor + 60, cursor + 60 + width
        if end > stop:
            raise MachoError("Invalid static archive member bounds")
        name = header[:16].rstrip(b" ")
        if name.startswith(b"#1/"):
            if not name[3:].isdigit() or int(name[3:]) > width:
                raise MachoError("Invalid BSD archive member name")
            length = int(name[3:])
            name = data[payload:payload + length].rstrip(b"\0 ")
            payload += length
        elif name == b"//":
            names = data[payload:end]
        elif name.startswith(b"/") and name[1:].isdigit():
            index = int(name[1:])
            if index >= len(names) or names.find(b"/\n", index) < 0:
                raise MachoError("Invalid GNU archive member name")
            name = names[index:names.find(b"/\n", index)]
        if name not in {b"/", b"//", b"/SYM64/", b"__.SYMDEF", b"__.SYMDEF SORTED", b"__.SYMDEF_64", b"__.SYMDEF_64 SORTED"}:
            if not name or payload == end:
                raise MachoError("Invalid static archive object member")
            item = _thin(data, payload, end - payload)
            if item["filetype"] != 1:
                raise MachoError("Static archive member is not a relocatable object")
            actual_cpu = (item["cpu_type"], item["cpu_subtype"] & 0x00ffffff)
            if expected_cpu is not None and actual_cpu != (expected_cpu[0], expected_cpu[1] & 0x00ffffff):
                raise MachoError("Universal static archive CPU does not match its member")
            # CPU_SUBTYPE_LIB64 is a capability bit, not a different subtype.
            architectures.add("arm64e" if actual_cpu == (0x0100000c, 2) else item["architecture"])
        cursor = end + (width & 1)
        if cursor > stop:
            raise MachoError("Invalid static archive padding")
    if not architectures:
        raise MachoError("Static archive contains no validated object members")
    return architectures


def static_archive_architectures(path: Path):
    """Return validated object architectures, or None for a non-archive.

    FAT containers may wrap ar archives, not just Mach-O images. LLVM exposes
    these separately as getAsArchive/getAsObjectFile in MachOUniversal.cpp.
    Archives never supply runtime UUID evidence or an empty variants list.
    """
    with path.open("rb") as stream:
        magic = stream.read(8)
        if magic[:4] not in FAT and magic != ARCHIVE_MAGIC:
            return None
        with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            if magic == ARCHIVE_MAGIC:
                return _archive_architectures(data, 0, len(data))
            entries = _fat_entries(data)
            archive_members = [data[offset:offset + 8] == ARCHIVE_MAGIC for _, _, offset, _ in entries]
            if not any(archive_members):
                return None
            if not all(archive_members):
                raise MachoError("Mixed archive and Mach-O universal slices")
            architectures = set()
            for cpu, subtype, offset, size in entries:
                architectures.update(_archive_architectures(data, offset, size, (cpu, subtype)))
            return architectures


def _thin(data, start: int, size: int) -> dict:
    endian, wide = THIN.get(data[start:start + 4], (None, None))
    if endian is None:
        raise MachoError("Unsupported Mach-O slice magic")
    header = struct.Struct(endian + ("IiiIIIII" if wide else "IiiIIII"))
    if size < header.size or start + size > len(data):
        raise MachoError("Invalid Mach-O slice bounds")
    fields = header.unpack_from(data, start)
    architecture = {7: "i386", 12: "arm", 0x01000007: "x86_64", 0x0100000c: "arm64"}.get(fields[1])
    if architecture is None or fields[3] not in (1, 2, 6, 8, 10):
        raise MachoError("Unsupported Mach-O architecture or artifact type")
    count, commands_size = fields[4:6]
    cursor, stop = start + header.size, start + header.size + commands_size
    if count > 100000 or stop > start + size:
        raise MachoError("Invalid Mach-O load-command table")
    identifiers, debug_sections, executable, oso_symbols = set(), set(), False, False
    segment_details, section_details = [], []
    for _ in range(count):
        if cursor + 8 > stop:
            raise MachoError("Truncated Mach-O load command")
        command, width = struct.unpack_from(endian + "II", data, cursor)
        if width < 8 or cursor + width > stop:
            raise MachoError("Invalid Mach-O load command bounds")
        if command == 0x1b:
            if width != 24:
                raise MachoError("Invalid Mach-O UUID command")
            identifiers.add(str(uuid.UUID(bytes=data[cursor + 8:cursor + 24])))
        if command == 2:  # LC_SYMTAB, N_OSO marks a local link debug map.
            if width != 24:
                raise MachoError("Invalid Mach-O symbol-table command")
            symbol_offset, symbol_count, string_offset, string_size = struct.unpack_from(endian + "IIII", data, cursor + 8)
            stride = 16 if wide else 12
            if symbol_offset + symbol_count * stride > size or string_offset + string_size > size:
                raise MachoError("Invalid Mach-O symbol-table bounds")
            oso_symbols = any(data[start + symbol_offset + index * stride + 4] == 0x66
                              for index in range(symbol_count))
        if command in (1, 0x19):
            segment = struct.Struct(endian + ("II16sQQQQiiII" if command == 0x19 else "II16sIIIIiiII"))
            section = struct.Struct(endian + ("16s16sQQIIIIIIII" if command == 0x19 else "16s16sIIIIIIIII"))
            if width < segment.size:
                raise MachoError("Truncated Mach-O segment")
            values = segment.unpack_from(data, cursor)
            file_start, file_size, sections = values[5], values[6], values[9]
            if file_start + file_size > size or segment.size + sections * section.size > width:
                raise MachoError("Invalid Mach-O segment bounds")
            segment_details.append({"name": values[2].rstrip(b"\0").decode("ascii", errors="replace"),
                                    "vmaddr": values[3], "vmsize": values[4],
                                    "fileoff": file_start, "filesize": file_size})
            for index in range(sections):
                info = section.unpack_from(data, cursor + segment.size + index * section.size)
                name, segment_name = info[0].rstrip(b"\0"), info[1].rstrip(b"\0")
                section_size, offset, flags = info[3], info[4], info[8]
                # dSYM keeps virtual __TEXT section sizes with offset=0 while
                # retaining only unwind bytes elsewhere in the same segment.
                has_contents = bool(offset and section_size and file_size and (flags & 0xff) not in (1, 0xc, 0x12))
                if has_contents and (offset < file_start or offset + section_size > file_start + file_size):
                    raise MachoError("Invalid Mach-O section bounds")
                if has_contents and segment_name == b"__DWARF":
                    debug_sections.add(name)
                if has_contents and (name == b"__text" or flags & 0x80000400):
                    executable = True
                section_details.append({"name": name.decode("ascii", errors="replace"),
                                        "segment": segment_name.decode("ascii", errors="replace"),
                                        "offset": start + offset, "size": section_size,
                                        "addr": info[2], "align": info[5], "flags": flags,
                                        "has_contents": has_contents})
        cursor += width
    if cursor != stop or len(identifiers) > 1:
        raise MachoError("Conflicting Mach-O identifiers or command sizes")
    return {"architecture": architecture, "uuid": next(iter(identifiers), ""),
            "filetype": fields[3],
            "has_debug_info": bool({b"__debug_info", b"__zdebug_info"} & debug_sections),
            "has_debug_line": bool({b"__debug_line", b"__zdebug_line"} & debug_sections),
            "has_executable_text": executable, "has_oso_symbols": oso_symbols,
            "cpu_type": fields[1], "cpu_subtype": fields[2],
            "endian": endian, "offset": start, "size": size,
            "segments": segment_details, "sections": section_details}


def inspect_macho(path: Path) -> dict:
    with path.open("rb") as stream:
        if path.stat().st_size < 4:
            raise MachoError("Truncated Mach-O header")
        with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            magic = data[:4]
            if magic in THIN:
                return {"variants": [_thin(data, 0, len(data))], "is_fat": False}
            if magic not in FAT or len(data) < 8:
                raise MachoError("Unsupported Mach-O header")
            endian, wide = FAT[magic]
            count = struct.unpack_from(endian + "I", data, 4)[0]
            entry = struct.Struct(endian + ("iiQQII" if wide else "iiIII"))
            if not 0 < count <= 64 or 8 + count * entry.size > len(data):
                raise MachoError("Invalid universal Mach-O header")
            variants, ranges = [], []
            for index in range(count):
                info = entry.unpack_from(data, 8 + index * entry.size)
                offset, size = info[2:4]
                if offset < 8 + count * entry.size or not size or offset + size > len(data):
                    raise MachoError("Invalid universal Mach-O slice bounds")
                if any(offset < end and offset + size > begin for begin, end in ranges):
                    raise MachoError("Overlapping universal Mach-O slices")
                ranges.append((offset, offset + size))
                variant = _thin(data, offset, size)
                if variant["cpu_type"] != info[0] or variant["cpu_subtype"] != info[1]:
                    raise MachoError("Universal Mach-O CPU metadata does not match its slice")
                if variant["architecture"] in {item["architecture"] for item in variants}:
                    raise MachoError("Duplicate universal Mach-O architecture")
                variants.append(variant)
            return {"variants": variants, "is_fat": True}


def read_slices(path: Path) -> list[dict]:
    """Internal section locations for debug-only extraction; contains no payload."""
    return inspect_macho(path)["variants"]
