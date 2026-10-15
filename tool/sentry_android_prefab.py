"""Find exact Android Sentry DWARF companions in the local Maven AAR cache.

Only the sentry-native-ndk coordinate and its two prefab libraries are read.
Archive paths are never used as extraction destinations, and failures expose
stable codes rather than cache paths or archive exception details.
"""

from __future__ import annotations

import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import tempfile
import zipfile
import zlib

from sentry_elf import inspect_elf


class PrefabError(RuntimeError):
    pass


SENTRY_ANDROID_TARGETS = frozenset({"libsentry.so", "libsentry-android.so"})
_MODULES = {"libsentry.so": "sentry", "libsentry-android.so": "sentry-android"}
_ARCHITECTURES = {"armeabi-v7a": "arm", "arm64-v8a": "aarch64", "x86_64": "x86_64"}
_MAX_CANDIDATES = 128
_MAX_DIRECTORY_ENTRIES = 4096
_MAX_ARCHIVE_BYTES = 256 * 1024 * 1024
_MAX_ZIP_ENTRIES = 8192
_MAX_MEMBER_BYTES = 64 * 1024 * 1024
_MAX_EXTRACTED_BYTES = 512 * 1024 * 1024


def _redirects(metadata: os.stat_result) -> bool:
    # Windows directory junctions are reparse points but need not be symlinks.
    return (stat.S_ISLNK(metadata.st_mode)
            or bool(getattr(metadata, "st_file_attributes", 0)
                    & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)))


def _safe_path(path: Path, *, directory: bool) -> bool:
    """Reject symlinks in every existing ancestor, including the selected home."""
    # Preserve '..' until every lexical ancestor has been checked: normalizing
    # first could hide a symlink immediately before a parent traversal.
    absolute = path.absolute()
    for part in (*reversed(absolute.parents), absolute):
        try:
            metadata = part.lstat()
        except FileNotFoundError:
            return False
        mode = metadata.st_mode
        if _redirects(metadata) or (part != absolute and not stat.S_ISDIR(mode)):
            raise PrefabError("prefab_unsafe_path")
    if directory and not stat.S_ISDIR(mode):
        raise PrefabError("prefab_unsafe_path")
    if not directory and not stat.S_ISREG(mode):
        raise PrefabError("prefab_unsafe_path")
    return True


def _archives(coordinate: Path) -> list[Path]:
    if not _safe_path(coordinate, directory=True):
        return []
    found = []
    scanned = 0

    def children(folder: Path):
        nonlocal scanned
        with os.scandir(folder) as entries:
            result = []
            for entry in entries:
                scanned += 1
                if scanned > _MAX_DIRECTORY_ENTRIES:
                    raise PrefabError("prefab_cache_limit")
                if _redirects(entry.stat(follow_symlinks=False)):
                    raise PrefabError("prefab_unsafe_path")
                result.append(entry)
        return sorted(result, key=lambda entry: entry.name)

    # The only traversal is <coordinate>/<version>/<hash>/*.aar. There is no
    # latest-version preference, transform-cache fallback or recursive search.
    for version in children(coordinate):
        if not version.is_dir(follow_symlinks=False):
            continue
        for digest in children(Path(version.path)):
            if not digest.is_dir(follow_symlinks=False):
                continue
            for artifact in children(Path(digest.path)):
                if artifact.name.endswith(".aar"):
                    if not artifact.is_file(follow_symlinks=False):
                        raise PrefabError("prefab_unsafe_path")
                    found.append(Path(artifact.path))
                    if len(found) > _MAX_CANDIDATES:
                        raise PrefabError("prefab_cache_limit")
    return found


def _member(archive: zipfile.ZipFile, wanted: str):
    entries = archive.infolist()
    if len(entries) > _MAX_ZIP_ENTRIES:
        raise PrefabError("prefab_zip_limit")
    names, result = set(), None
    for entry in entries:
        name = entry.filename
        parts = name.rstrip("/").split("/")
        if (entry.orig_filename != name or not name or "\\" in name
                or PurePosixPath(name).is_absolute() or ":" in parts[0]
                or any(part in {"", ".", ".."} for part in parts)):
            raise PrefabError("prefab_zip_unsafe_member")
        if name in names:
            raise PrefabError("prefab_zip_duplicate_member")
        names.add(name)
        mode = entry.external_attr >> 16
        kind = stat.S_IFMT(mode)
        if kind not in {0, stat.S_IFREG, stat.S_IFDIR}:
            raise PrefabError("prefab_zip_unsafe_member")
        if entry.flag_bits & 1:
            raise PrefabError("prefab_zip_encrypted")
        if name == wanted:
            if entry.is_dir() or kind == stat.S_IFDIR:
                raise PrefabError("prefab_zip_unsafe_member")
            if not 0 < entry.file_size <= _MAX_MEMBER_BYTES:
                raise PrefabError("prefab_member_limit")
            result = entry
    return result


def _usable(info: dict) -> bool:
    sections = info["code_sections"]
    return (bool(info["build_id"]) and set(sections) == {".text", ".rodata"}
            and all(section["size"] > 0 for section in sections.values()))


def prefab_candidates(runtime: Path, abi: str, target: str, temporary_root: Path,
                      gradle_user_home: Path | None = None) -> list[Path]:
    """Extract matching DWARF libraries under the caller's temporary directory.

    Missing caches, missing allowlisted members and valid nonmatching versions
    yield no candidates. Corrupt or dangerous sources fail the whole lookup,
    even if another cache version would have matched.
    """
    if target not in SENTRY_ANDROID_TARGETS or abi not in _ARCHITECTURES:
        raise PrefabError("prefab_invalid_request")
    created = []
    try:
        try:
            runtime_info = inspect_elf(runtime)
        except (OSError, ValueError):
            raise PrefabError("prefab_invalid_runtime") from None
        if runtime_info["architecture"] != _ARCHITECTURES[abi] or not _usable(runtime_info):
            raise PrefabError("prefab_invalid_runtime")
        if not _safe_path(temporary_root, directory=True):
            raise PrefabError("prefab_invalid_temporary_root")
        home = gradle_user_home
        if home is None:
            home = Path(os.environ.get("GRADLE_USER_HOME") or Path.home() / ".gradle")
        coordinate = Path(home) / "caches/modules-2/files-2.1/io.sentry/sentry-native-ndk"
        archives = _archives(coordinate)
        wanted = f"prefab/modules/{_MODULES[target]}/libs/android.{abi}/{target}"
        matched, extracted = [], 0
        for path in archives:
            if not _safe_path(path, directory=False):
                raise PrefabError("prefab_cache_changed")
            if not path.resolve(strict=True).is_relative_to(coordinate.resolve(strict=True)):
                raise PrefabError("prefab_unsafe_path")
            # O_NOFOLLOW also protects the final path between checking and open.
            descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            with os.fdopen(descriptor, "rb") as stream:
                metadata = os.fstat(stream.fileno())
                if not stat.S_ISREG(metadata.st_mode):
                    raise PrefabError("prefab_unsafe_path")
                if not 0 < metadata.st_size <= _MAX_ARCHIVE_BYTES:
                    raise PrefabError("prefab_archive_limit")
                with zipfile.ZipFile(stream) as archive:
                    member = _member(archive, wanted)
                    if member is None:
                        continue
                    folder = Path(tempfile.mkdtemp(prefix="sentry-prefab-", dir=temporary_root))
                    created.append(folder)
                    output = folder / target
                    size = 0
                    with archive.open(member) as source, output.open("xb") as destination:
                        while chunk := source.read(1024 * 1024):
                            size += len(chunk)
                            extracted += len(chunk)
                            if size > _MAX_MEMBER_BYTES or extracted > _MAX_EXTRACTED_BYTES:
                                raise PrefabError("prefab_member_limit")
                            destination.write(chunk)
                    if size != member.file_size:
                        raise PrefabError("prefab_zip_invalid")
                    try:
                        info = inspect_elf(output)
                    except ValueError:
                        raise PrefabError("prefab_invalid_elf") from None
                    if (_usable(info) and info["architecture"] == runtime_info["architecture"]
                            and info["build_id"] == runtime_info["build_id"]
                            and info["has_debug_info"] and info["has_debug_line"]
                            and info["code_sections"] == runtime_info["code_sections"]):
                        matched.append(output)
                    else:
                        shutil.rmtree(folder)
                        created.remove(folder)
        return matched
    except PrefabError:
        for folder in created:
            shutil.rmtree(folder, ignore_errors=True)
        raise
    except (OSError, ValueError, RuntimeError, EOFError, zipfile.BadZipFile,
            zipfile.LargeZipFile, zlib.error):
        for folder in created:
            shutil.rmtree(folder, ignore_errors=True)
        raise PrefabError("prefab_source_invalid") from None
