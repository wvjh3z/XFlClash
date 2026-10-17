#!/usr/bin/env python3
"""Prepare the pinned, locally patched Linux distributor without building apps.

Only tracked tool sources and their license are exported. The submodule and all
application/flavor inputs remain untouched. Callers must stop on a nonzero exit
before activating the returned path.
"""
from __future__ import annotations

import argparse
import hashlib
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile


REPO = Path(__file__).resolve().parents[1]
PINNED_REVISION = "cdeeef2d8f8325bb6ae0bc86b39f56e4325d1a58"
PATCH = REPO / "tool/patches/flutter_distributor_appimage.patch"
PATCH_SHA256 = "a13987c59fc6660312dcbfa9c0332a337084ed9ee1a39d8153d60b9cd03f7f71"
OUTPUT = REPO / "build/packaging-tools/flutter_distributor"
# Both sides are intentional: reject changed upstream input and changed patch
# output, including an accidentally partial or already applied patch.
SOURCE_HASHES = {
    "packages/flutter_app_builder/lib/src/builders/linux/build_linux_result.dart": (
        "154150d8ce1de02f466789825996967a3a537ffa1e5d49d1cb10e5a115323cd4",
        "fdba179fe680e0a97586b4458128611015da7a715bff8c4ea38603262df2e4e0",
    ),
    "packages/flutter_app_packager/lib/src/makers/appimage/app_package_maker_appimage.dart": (
        "3ff1a24f3496d1f885ba69b57fbba7fbe77be4ba1a21383c264aab5a79608cdd",
        "465f3e38b9f7ef7bc16226f84b377eaf45dc90600f6a63018ae87e1f28419bd6",
    ),
    "packages/flutter_distributor/lib/src/flutter_distributor.dart": (
        "02f826c354adf53c4026d4172640d5d2b7c70fb151fd2ae9ca079bc8e1815b25",
        "b18e39fcf75e907254db661276fd19ed910536e0931ae2008873984800827dc5",
    ),
}


def git(source: Path, *arguments: str) -> bytes:
    result = subprocess.run(
        ["git", "-C", str(source), *arguments], capture_output=True, check=False
    )
    if result.returncode:
        raise RuntimeError(f"git {' '.join(arguments[:2])} failed: {result.stderr.decode().strip()}")
    return result.stdout


def verify_hashes(directory: Path, side: int) -> None:
    for name, hashes in SOURCE_HASHES.items():
        actual = hashlib.sha256((directory / name).read_bytes()).hexdigest()
        if actual != hashes[side]:
            raise RuntimeError(f"{'Patched' if side else 'Upstream'} source drift: {name}")


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
        with tarfile.open(fileobj=io.BytesIO(archive)) as contents:
            for member in contents.getmembers():
                target = (staged / member.name).resolve()
                safe_link = member.issym() and (target.parent / member.linkname).resolve().is_relative_to(staged)
                if not target.is_relative_to(staged) or not (member.isdir() or member.isfile() or safe_link):
                    raise RuntimeError(f"Unsafe tool archive member: {member.name}")
            # All entries were checked above and come from the pinned Git tree.
            if hasattr(tarfile, "data_filter"):
                contents.extractall(staged, filter="data")
            else:
                contents.extractall(staged)
        verify_hashes(staged, 0)
        for arguments in (("--check",), ()):
            result = subprocess.run(
                ["git", "apply", "--whitespace=error-all", *arguments, str(patch)],
                cwd=staged, capture_output=True, check=False,
            )
            if result.returncode:
                raise RuntimeError(f"Distributor patch rejected: {result.stderr.decode().strip()}")
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
        entry = git(REPO, "ls-files", "--stage", "plugins/flutter_distributor").decode().split()
        if entry[:2] != ["160000", PINNED_REVISION]:
            raise RuntimeError("Parent repository distributor gitlink changed; review the pinned patch")
        output = prepare(REPO / "plugins/flutter_distributor", args.output)
    except (OSError, RuntimeError, tarfile.TarError) as error:
        parser.exit(1, f"Linux packager preparation failed: {error}\n")
    print(f"Prepared Linux packager: {output / 'packages/flutter_distributor'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
