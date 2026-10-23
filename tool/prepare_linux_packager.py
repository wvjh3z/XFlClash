#!/usr/bin/env python3
"""Prepare the pinned, locally patched cross-platform distributor without building apps.

Only tracked tool sources and their license are exported. The submodule and all
application/flavor inputs remain untouched. Callers must stop on a nonzero exit
before activating the returned path.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile


REPO = Path(__file__).resolve().parents[1]
PINNED_REVISION = "cdeeef2d8f8325bb6ae0bc86b39f56e4325d1a58"
PATCH = REPO / "tool/patches/flutter_distributor_appimage.patch"
PATCH_SHA256 = "9e96bb884f4cdc6628065b95957dfa5bbe1ad88d4d0d6c4d99417895e128e7da"
OUTPUT = REPO / "build/packaging-tools/flutter_distributor"
# Both sides are intentional: reject changed upstream input and changed patch
# output, including an accidentally partial or already applied patch.
SOURCE_HASHES = {'packages/flutter_app_builder/lib/src/builders/app_builder.dart': ('39340543d89e6b9f5b98ea35bb6575dc355becf45365866c567fe1708b7c6581',
                                                                    '606fdd052397852b20b0ad076ce77c08bc9e79bf5b5c6ce969e58642c5807fa3'),
 'packages/flutter_app_builder/lib/src/builders/linux/build_linux_result.dart': ('154150d8ce1de02f466789825996967a3a537ffa1e5d49d1cb10e5a115323cd4',
                                                                                 'fdba179fe680e0a97586b4458128611015da7a715bff8c4ea38603262df2e4e0'),
 'packages/flutter_app_packager/lib/src/api/app_package_maker.dart': ('4316a046688467d7d998e4844f5e823dc241b0903e2adf46ec9247e801291523',
                                                                      '099b62ccfb7763593e4366e65e8a5f2521ef33e3777ed9df175a03658e2a04e0'),
 'packages/flutter_app_packager/lib/src/api/distribute_options_base.dart': ('c1f3fbe6de6277a059aa2edaa7bb37af56f1e4790e2d3d07f6a519a518796adc',
                                                                            'f82efe4a431c6434714db02452c86ecb764eab537d0e532dfbd168954331731c'),
 'packages/flutter_app_packager/lib/src/api/make_config.dart': ('68bb37f1805dae3a26b4fdb0afe3803ab0c433b84a27d1d65e720a706c7381c9',
                                                                '0ed58bc958cc0369447e371569ba3d9cdf8fd3ae72cdef1ce6ef59a7e14eab4b'),
 'packages/flutter_app_packager/lib/src/makers/appimage/app_package_maker_appimage.dart': ('3ff1a24f3496d1f885ba69b57fbba7fbe77be4ba1a21383c264aab5a79608cdd',
                                                                                           '575b5398facf6aebe24bfbc66437cc33e6c047fa8144ba260a0e400e27997444'),
 'packages/flutter_app_packager/lib/src/makers/deb/app_package_maker_deb.dart': ('d8d497fbb25f4fe132a442e3ae8bc04282222ecd2c737cf0c4d22941f8121678',
                                                                                 '5dd313d14e98e7c8dc12c1ff8bbf2239822b81d621cde62e14feb2b2331759e1'),
 'packages/flutter_app_packager/lib/src/makers/deb/make_deb_config.dart': ('bd4308391d84087937b66febd0623050ec0ceb248480814999275b53e153d22f',
                                                                           'f4f4f0abda0aa13f9583cd0470dd05a186e2836d5ce0256a5bbe35a631dc9595'),
 'packages/flutter_app_packager/lib/src/makers/rpm/app_package_maker_rpm.dart': ('37ec008108ea634cfe26ab771474c0d3470f934b58e11cc0d4645a1f1630c0a7',
                                                                                 '12c81e45952789838e6fdaf6cdd4c9cda6e5fc67bfdb8de6b1a0a7adef711b8e'),
 'packages/flutter_app_packager/lib/src/makers/rpm/make_rpm_config.dart': ('3aadd9f823cbfb640dd1891d130ef4f1a631316840dae261044c2fa51866003c',
                                                                           '9af015cd0e3cf7e60b1d3678c0e3b4ad864f121a11622bf0aa70e96467c52350'),
 'packages/flutter_distributor/lib/src/flutter_distributor.dart': ('02f826c354adf53c4026d4172640d5d2b7c70fb151fd2ae9ca079bc8e1815b25',
                                                                   'b18e39fcf75e907254db661276fd19ed910536e0931ae2008873984800827dc5'),
 'packages/flutter_distributor/lib/src/utils/default_shell_executor.dart': ('b87021fd0fe2efdd8ba5df39fd9d19d35e14bad67d23e3a25d3a07ff1e862366',
                                                                            '925b77f4d3304f5239820051c4f33bed540a86619ace62ed0fe468bbfa2605bb'),
 'packages/flutter_distributor/pubspec.yaml': ('3e4b81d10fbc920795871510c3d34f442c2173a6d376d678cc5ca039d5a3666b',
                                               'd35e99715ff0982b433977baf2eae1adeb3719cdbd411eb5b621ff70b239dcce'),
 'packages/shell_executor/lib/src/shell_executor.dart': ('698185a991c2c1d87f0a3ec82f3aec68771cbccf176ec972c008ded90ca9782c',
                                                         'b648774899064b65850683dab99abd95a2b78a66a80fa205dc28500614bdad72')}


def git(source: Path, *arguments: str) -> bytes:
    # Export bytes deterministically, but let status interpret the real checkout
    # using its own settings (a legitimate Windows CRLF checkout is clean).
    settings = ["-c", "core.autocrlf=false", "-c", "core.eol=lf"] if arguments[0] == "archive" else []
    result = subprocess.run(
        ["git", *settings, "-C", str(source), *arguments], capture_output=True, check=False
    )
    if result.returncode:
        raise RuntimeError(f"git {' '.join(arguments[:2])} failed: {result.stderr.decode('utf-8', errors='replace').strip()}")
    return result.stdout


def verify_hashes(directory: Path, side: int) -> None:
    for name, hashes in SOURCE_HASHES.items():
        actual = hashlib.sha256((directory / name).read_bytes()).hexdigest()
        if actual != hashes[side]:
            raise RuntimeError(f"{'Patched' if side else 'Upstream'} source drift: {name}")


def export_tool_archive(archive: bytes, staged: Path, *, materialize_links: bool | None = None) -> None:
    """Export the pinned Git tree into a fresh directory, then check its links.

    Git archives need only directories, regular files and relative symlinks.
    Write files before creating links so no archive entry can write through a
    symlink. This also avoids the data_filter relative-link bug in Python 3.10.12.
    """
    # Compare physical paths on both sides, including macOS /var aliases and
    # callers that pass a relative directory. The destination must already exist.
    staged = staged.resolve(strict=True)
    with tarfile.open(fileobj=io.BytesIO(archive)) as contents:
        members = {}
        for member in contents.getmembers():
            name = PurePosixPath(member.name)
            if (name.is_absolute() or not name.parts or ".." in name.parts
                    or "\\" in member.name or ":" in member.name or member.name.rstrip("/") != name.as_posix()
                    or name in members
                    or not (member.isdir() or member.isfile() or member.issym())):
                raise RuntimeError(f"Unsafe tool archive member: {member.name}")
            if member.issym() and (not member.linkname or "\\" in member.linkname or ":" in member.linkname
                                  or PurePosixPath(member.linkname).is_absolute()):
                raise RuntimeError(f"Unsafe tool archive link: {member.name}")
            members[name] = member
        for name in members:
            if any(parent in members and not members[parent].isdir() for parent in name.parents):
                raise RuntimeError(f"Unsafe tool archive parent: {name}")

        for name, member in members.items():
            target = staged.joinpath(*name.parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            if member.isdir():
                target.mkdir(exist_ok=True)
            elif member.isfile():
                with contents.extractfile(member) as source, target.open("xb") as destination:
                    shutil.copyfileobj(source, destination)
                # Git tracks only the executable bit. Do not restore owners,
                # setuid/setgid, or archive-supplied writable permission bits.
                target.chmod(0o755 if member.mode & 0o100 else 0o644)

        if materialize_links is None:
            materialize_links = os.name == "nt"
        if materialize_links:
            # Windows does not need symlink privileges just to export README.
            # Only regular-file targets are accepted in this mode; future
            # upstream directory/link chains need explicit review.
            for name, member in members.items():
                if not member.issym():
                    continue
                target = staged.joinpath(*name.parent.parts, member.linkname).resolve()
                if not target.is_relative_to(staged) or not target.is_file():
                    raise RuntimeError(f"Unsafe tool archive link: {name}")
                relative = PurePosixPath(target.relative_to(staged).as_posix())
                if relative not in members or not members[relative].isfile():
                    raise RuntimeError(f"Unsafe tool archive link: {name}")
                shutil.copyfile(target, staged.joinpath(*name.parts))
            return

        for name, member in members.items():
            if member.issym():
                staged.joinpath(*name.parts).symlink_to(member.linkname)
        # Resolve only after every link exists: a later link may change an
        # earlier target's effective destination. Require existing targets so
        # dangling links and cycles fail consistently across Python versions.
        for name, member in members.items():
            if member.issym():
                try:
                    safe = staged.joinpath(*name.parts).resolve(strict=True).is_relative_to(staged)
                except (OSError, RuntimeError) as error:
                    raise RuntimeError(f"Unsafe tool archive link: {name}") from error
                if not safe:
                    raise RuntimeError(f"Unsafe tool archive link: {name}")


def apply_tool_patch(staged: Path, patch: Path) -> None:
    """Apply within a disposable Git root, never the caller's repository/index.

    git apply can silently skip Git-format headers when cwd is below a different
    worktree. An explicit temporary repository makes both patch formats behave
    the same inside/outside the checkout. No commit or global config is written.
    """
    staged = staged.resolve(strict=True)
    patch = patch.resolve(strict=True)
    metadata = staged / ".git"
    if metadata.exists() or metadata.is_symlink():
        raise RuntimeError("Tool staging directory already contains Git metadata")
    environment = {key: value for key, value in os.environ.items()
                   if not key.upper().startswith("GIT_")}
    try:
        result = subprocess.run(
            ["git", "init", "--quiet", "--template=", str(staged)],
            cwd=staged, env=environment, capture_output=True, check=False,
        )
        if result.returncode:
            raise RuntimeError("Cannot initialize isolated tool patch context")
        for arguments in (("--check",), ()):
            result = subprocess.run(
                ["git", "--git-dir=" + str(metadata), "--work-tree=" + str(staged),
                 "-c", "core.autocrlf=false", "apply", "--whitespace=error-all",
                 *arguments, str(patch)],
                cwd=staged, env=environment, capture_output=True, check=False,
            )
            if result.returncode:
                raise RuntimeError(f"Distributor patch rejected: {result.stderr.decode('utf-8', errors='replace').strip()}")
    finally:
        if metadata.is_dir():
            shutil.rmtree(metadata)


def prepare(source: Path, output: Path, patch: Path = PATCH) -> Path:
    source, output, patch = source.resolve(), output.absolute(), patch.resolve()
    if output.is_symlink():
        raise RuntimeError("Output must not be a symlink")
    output = output.resolve()
    if output == source or source in output.parents or output in source.parents:
        raise RuntimeError("Output must be separate from the source submodule")
    if hashlib.sha256(patch.read_bytes()).hexdigest() != PATCH_SHA256:
        raise RuntimeError("Distributor patch drift; review and update the pinned patch checksum")
    revision = git(source, "rev-parse", "HEAD").decode().strip()
    if revision != PINNED_REVISION:
        raise RuntimeError(f"Unexpected distributor revision: {revision}; expected {PINNED_REVISION}")
    if git(source, "status", "--porcelain", "--untracked-files=no").strip():
        raise RuntimeError("Distributor source has tracked changes; refusing source drift")
    archive = git(source, "archive", PINNED_REVISION, "packages", "LICENSE", "README.md")
    output.parent.mkdir(parents=True, exist_ok=True)
    # Build and validate a fresh tree. Re-running never reapplies to old output.
    with tempfile.TemporaryDirectory(prefix=".prepare-linux-packager-", dir=output.parent) as temporary:
        staged = Path(temporary) / "flutter_distributor"
        staged.mkdir()
        export_tool_archive(archive, staged)
        verify_hashes(staged, 0)
        apply_tool_patch(staged, patch)
        verify_hashes(staged, 1)
        # The previous complete output is kept until validation succeeds. The
        # rename keeps partially prepared tools invisible to activation.
        backup = Path(temporary) / "previous"
        if output.exists():
            output.rename(backup)
        try:
            staged.rename(output)
        except BaseException:
            if backup.exists():
                backup.rename(output)
            raise
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()
    try:
        from checkout_distributor import ensure_checkout
        output = prepare(ensure_checkout(REPO), args.output)
    except (OSError, RuntimeError, tarfile.TarError) as error:
        parser.exit(1, f"Packager preparation failed: {error}\n")
    # Human diagnostic only: ASCII escaping preserves the path without making
    # a verified preparation fail on Windows ANSI-codepage stdout pipes.
    print(f"Prepared packager: {str(output / 'packages/flutter_distributor')!a}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
