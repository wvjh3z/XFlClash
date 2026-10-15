"""Read the ELF facts needed for companion matching without executing binaries.

This parser exposes identifiers, architecture, section presence and code hashes.
It never emits source paths, symbols, process environment or section contents.
"""

from __future__ import annotations

import hashlib
import mmap
from pathlib import Path
import struct


class ElfError(ValueError):
    pass


def inspect_elf(path: Path) -> dict:
    """Inspect GNU build ID and DWARF sections in one ELF file, entirely offline."""
    with path.open("rb") as stream:
        if path.stat().st_size < 52:
            raise ElfError("Invalid ELF header")
        with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as data:
            if data[:4] != b"\x7fELF" or data[4] not in (1, 2) or data[5] not in (1, 2):
                raise ElfError("Unsupported ELF header")
            bits, endian = data[4], "<" if data[5] == 1 else ">"
            header = struct.Struct(endian + ("HHIIIIIHHHHHH" if bits == 1 else "HHIQQQIHHHHHH"))
            if 16 + header.size > len(data):
                raise ElfError("Truncated ELF header")
            fields = header.unpack_from(data, 16)
            architecture = {3: "i386", 40: "arm", 62: "x86_64", 183: "aarch64"}.get(fields[1])
            if architecture is None or fields[0] not in (2, 3):
                raise ElfError("Unsupported ELF architecture or artifact type")
            section = struct.Struct(endian + ("IIIIIIIIII" if bits == 1 else "IIQQQQIIQQ"))
            offset, width, count, strings_index = fields[5], fields[10], fields[11], fields[12]
            if width < section.size or offset < 16 + header.size or offset + width > len(data):
                raise ElfError("Invalid ELF section table")
            first = section.unpack_from(data, offset)
            if count == 0:
                count = first[5]
            if strings_index == 0xffff:
                strings_index = first[6]
            if not 0 < count <= 100000 or offset + width * count > len(data) or strings_index >= count:
                raise ElfError("Invalid ELF section table bounds")
            sections = [section.unpack_from(data, offset + index * width) for index in range(count)]
            strings = sections[strings_index]
            if strings[4] + strings[5] > len(data):
                raise ElfError("Invalid ELF section name table")
            names = data[strings[4]:strings[4] + strings[5]]
            present, build_ids, executable_text = set(), set(), False
            code_sections, code_names = {}, set()
            for entry in sections:
                name_offset, kind, flags, address, start, size = entry[:6]
                if name_offset >= len(names):
                    raise ElfError("Invalid ELF section name")
                end = names.find(b"\0", name_offset)
                if end < 0:
                    raise ElfError("Invalid ELF section name terminator")
                name = names[name_offset:end]
                if kind != 8 and start + size > len(data):  # SHT_NOBITS has no file content.
                    raise ElfError("Truncated ELF section")
                if name in {b".text", b".rodata"}:
                    if name in code_names:
                        raise ElfError("Duplicate ELF code section")
                    code_names.add(name)
                    if kind == 1:  # Only SHT_PROGBITS carries comparable bytes.
                        code_sections[name.decode("ascii")] = {
                            "sha256": hashlib.sha256(data[start:start + size]).hexdigest(),
                            "size": size,
                            "address": address,
                        }
                if kind != 8 and size:
                    present.add(name)
                if kind == 1 and flags & 4 and size:  # executable SHT_PROGBITS
                    executable_text = True
                if kind != 7:  # SHT_NOTE
                    continue
                cursor, stop = start, start + size
                while cursor + 12 <= stop:
                    name_size, value_size, note_type = struct.unpack_from(endian + "III", data, cursor)
                    cursor += 12
                    name_end = cursor + name_size
                    value_start = (name_end + 3) & ~3
                    value_end = value_start + value_size
                    if name_end > stop or value_end > stop:
                        raise ElfError("Invalid ELF note bounds")
                    if note_type == 3 and data[cursor:name_end].rstrip(b"\0") == b"GNU":
                        if not 4 <= value_size <= 64:
                            raise ElfError("Invalid GNU build identifier")
                        build_ids.add(data[value_start:value_end].hex())
                    cursor = (value_end + 3) & ~3
            if len(build_ids) > 1:
                raise ElfError("Conflicting GNU build identifiers")
            return {
                "build_id": next(iter(build_ids), ""),
                "architecture": architecture,
                "code_sections": code_sections,
                "has_debug_info": bool({b".debug_info", b".zdebug_info"} & present),
                "has_debug_line": bool({b".debug_line", b".zdebug_line"} & present),
                "has_executable_text": executable_text,
                "unwind_sections": sorted(name.decode("ascii") for name in
                                          {b".eh_frame", b".eh_frame_hdr", b".ARM.exidx", b".ARM.extab"} & present),
            }
