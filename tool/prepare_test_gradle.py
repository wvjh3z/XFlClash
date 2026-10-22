"""Pinned Gradle for the isolated brand DSL preflight (no Android build).

Only archives are cached. A verified archive is extracted into each fixture's
private directory, so no ignored project wrapper or mutable installed tree is
needed. Uses the same default path on CI and development machines.
"""
from __future__ import annotations
import hashlib
import os
from pathlib import Path
import stat
import tempfile
import zipfile

from fetch_build_asset import download_asset

VERSION = '9.8.0'
SHA256 = 'bafd5ce9cfaea0fbccfdc8439a1ac42fbd4cd9c89dc9a988228d8a2639a58e6c'
URL = 'https://github.com/gradle/gradle-distributions/releases/download/v9.8.0/gradle-9.8.0-bin.zip'
SIZE_LIMIT = 200_000_000
ROOT = Path(__file__).resolve().parents[1]


def verified(path):
    if not path.is_file() or path.is_symlink() or path.stat().st_size > SIZE_LIMIT:
        return False
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() == SHA256


def prepare(destination: Path, *, cache: Path | None = None, download=None) -> Path:
    cache = cache or Path(os.environ.get('XFLCLASH_TEST_GRADLE_CACHE',
                                        str(ROOT / '.dart_tool/test-gradle')))
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f'gradle-{VERSION}-bin.zip'
    if not verified(archive):
        # A failed download never replaces a complete cache; concurrent writers
        # publish only the same checksum-verified bytes via an atomic replace.
        with tempfile.TemporaryDirectory(prefix='download-', dir=cache) as temp:
            fresh = Path(temp) / 'gradle.zip'
            (download or download_asset)(fresh, URL, SIZE_LIMIT)
            if not verified(fresh):
                raise RuntimeError('Gradle archive SHA256 mismatch')
            os.replace(fresh, archive)
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as bundle:
        total = 0
        for member in bundle.infolist():
            path = destination / member.filename
            total += member.file_size
            mode = member.external_attr >> 16
            if (not member.filename.startswith(f'gradle-{VERSION}/')
                    or '\\' in member.filename
                    or not path.resolve().is_relative_to(destination.resolve())
                    or stat.S_ISLNK(mode) or total > 600_000_000):
                raise RuntimeError('Unsafe Gradle archive entry')
        bundle.extractall(destination)
    launcher = destination / f'gradle-{VERSION}/bin/gradle'
    launcher.chmod(0o755)
    if not (launcher.parent / 'gradle.bat').is_file():
        raise RuntimeError('Incomplete Gradle distribution')
    return launcher.parent / 'gradle.bat' if os.name == 'nt' else launcher
