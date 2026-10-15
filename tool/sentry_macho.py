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


def is_macho(path: Path) -> bool:
    with path.open("rb") as stream:
        return stream.read(4) in THIN.keys() | FAT.keys()


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
