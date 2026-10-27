"""Normalize APK archive I/O errors without swallowing verification failures."""
import json
from pathlib import Path
import zipfile
import zlib


class ApkArchiveError(ValueError):
    """A known ZIP/open/decompression failure, safe for per-APK reporting."""


# RuntimeError covers password/encryption errors; NotImplementedError covers
# unsupported compression. Catch only around archive operations, not caller code.
_ARCHIVE_ERRORS = (zipfile.BadZipFile, zipfile.LargeZipFile, zlib.error,
                   EOFError, OSError, RuntimeError, NotImplementedError)


class ApkArchive:
    def __init__(self, path):
        self.path = Path(path)
        self.archive = None

    def _call(self, operation, call, *, entry=None):
        try:
            return call()
        except _ARCHIVE_ERRORS as error:
            detail = {'file': self.path.name, 'operation': operation,
                      'cause': type(error).__module__ + '.' + type(error).__name__}
            if entry is not None:
                detail['entry'] = entry
            # Never include raw library messages or local absolute paths.
            raise ApkArchiveError('APK archive failure: ' + json.dumps(detail, ensure_ascii=True)) from error

    def __enter__(self):
        self.archive = self._call('open', lambda: zipfile.ZipFile(self.path))
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self._call('close', self.archive.close)
        return False

    def namelist(self):
        return self.archive.namelist()

    def read(self, entry):
        return self._call('read', lambda: self.archive.read(entry), entry=entry)
