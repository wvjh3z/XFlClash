"""Mutate real ZIP member bytes; preserve its directory for read-time failures."""
import struct
import zipfile


def corrupt_zip_entry(path, entry, mode):
    with zipfile.ZipFile(path) as archive:
        info = archive.getinfo(entry)
        start = archive.start_dir
    raw = bytearray(path.read_bytes())
    local = info.header_offset
    name_size, extra_size = struct.unpack_from('<HH', raw, local + 26)
    payload = local + 30 + name_size + extra_size
    central = start
    while raw[central:central + 4] == b'PK\x01\x02':
        name_length, extra_length, comment_length = struct.unpack_from('<HHH', raw, central + 28)
        if struct.unpack_from('<I', raw, central + 42)[0] == local:
            break
        central += 46 + name_length + extra_length + comment_length
    else:
        raise AssertionError('Fixture central directory entry missing')
    if mode == 'deflate':
        assert info.compress_type == zipfile.ZIP_DEFLATED
        raw[payload] = 7  # final block with invalid reserved BTYPE
    elif mode == 'crc':
        bad_crc = info.CRC ^ 1
        struct.pack_into('<I', raw, local + 14, bad_crc)
        struct.pack_into('<I', raw, central + 16, bad_crc)
    elif mode == 'unsupported':
        struct.pack_into('<H', raw, local + 8, 99)
        struct.pack_into('<H', raw, central + 10, 99)
    elif mode == 'encrypted':
        struct.pack_into('<H', raw, local + 6, info.flag_bits | 1)
        struct.pack_into('<H', raw, central + 8, info.flag_bits | 1)
    else:
        raise AssertionError('Unknown corruption fixture')
    path.write_bytes(raw)
