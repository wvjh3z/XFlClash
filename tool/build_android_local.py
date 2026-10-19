#!/usr/bin/env python3
"""Build, verify and finish a local brand APK without publishing a download site.

Release completion includes matching symbols and Sentry upload processing when
the selected flavor enables Sentry. Explicit diagnostic options are recorded.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import zipfile

from postbuild_sentry_symbols import ReleaseError

ARCHES = {"arm64": ("arm64-v8a", "android-arm64", "arm64", 183),
          "x64": ("x86_64", "android-x64", "amd64", 62)}
CRASHLYTICS_INIT = """gradle.projectsEvaluated {
    allprojects { p ->
        p.tasks.matching { t -> t.name.startsWith('uploadCrashlytics') }.configureEach {
            enabled = false
        }
    }
}
"""


def scalar(path: Path, key: str) -> str:
    """Read a top-level release label, never nested credentials or YAML objects."""
    match = re.search(r"^" + re.escape(key) + r":[ \t]*(.*)$", path.read_text(encoding="utf-8"), re.M)
    if not match:
        raise ReleaseError("Missing release metadata field: " + key)
    value = match.group(1).strip()
    if value.startswith('"'):
        try:
            value, end = json.JSONDecoder().raw_decode(value)
            tail = match.group(1).strip()[end:]
            if tail and not tail.lstrip().startswith("#"):
                raise ValueError()
        except (ValueError, TypeError):
            raise ReleaseError("Unsupported quoted release metadata: " + key) from None
    elif value.startswith("'"):
        match = re.fullmatch(r"'((?:[^']|'')*)'\s*(?:#.*)?", value)
        if not match:
            raise ReleaseError("Unsupported quoted release metadata: " + key)
        value = match.group(1).replace("''", "'")
    else:
        value = value.split(" #", 1)[0].strip()
    if not isinstance(value, str) or not value or value[0] in "[|>{":
        raise ReleaseError("Unsupported release metadata: " + key)
    return value


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    path.chmod(0o600)


def local_counter_path(root: Path, flavor: str) -> Path:
    if flavor not in ("brand_a", "brand_b"):
        raise ReleaseError("Unsupported local counter flavor")
    path = root / ".local-build" / f"build_number.{flavor}.txt"
    if path.parent.is_symlink() or path.is_symlink():
        raise ReleaseError("Local build counter must not use symbolic links")
    return path


def validate_local_number(number: int) -> int:
    if type(number) is not int or not 1 <= number <= 2_100_000_000:
        raise ReleaseError("Local Android build number must be an integer from 1 to 2100000000")
    return number


def write_local_build_number(root: Path, flavor: str, number: int) -> None:
    """Atomically replace only the ignored counter; caller holds the build lock."""
    validate_local_number(number)
    path = local_counter_path(root, flavor)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                         prefix=".counter-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(str(number) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def read_local_build_number(root: Path, flavor: str) -> int:
    """Seed once from the old tracked counter, then never read it again.

    Seeding copies a conservative starting value, not a claim that a build ran.
    A malformed existing local counter must fail rather than silently reset.
    """
    path = local_counter_path(root, flavor)
    missing = not path.exists()
    source = root / "scripts" / f"build_number.{flavor}.txt" if missing else path
    try:
        text = source.read_text(encoding="utf-8").strip()
        if not re.fullmatch(r"[1-9][0-9]{0,9}", text):
            raise ValueError()
        number = validate_local_number(int(text))
    except (OSError, ValueError, UnicodeError):
        raise ReleaseError("Local counter or its one-time migration seed is missing or invalid") from None
    if missing:
        write_local_build_number(root, flavor, number)
    return number


def capture_sources(root: Path, sdk: Path, flavor: str) -> dict:
    """Bind actual compilation inputs, including uncommitted source contents.

    Only hashes and relative names are saved. Generated/private signing files,
    output directories and unrelated integration-test edits are excluded.
    """
    paths = ("lib", "assets", "android", "core", "plugins", "scripts", "tool", "pubspec.yaml",
             "pubspec.lock", "build_config.yaml", "flutter_launcher_icons.yaml")
    generated = {"android/local.properties", "android/app/keystore.jks"}
    snapshot = {}
    repositories = [("client", root, paths), ("sdk", sdk, ("lib", "assets", "pubspec.yaml", "pubspec.lock")),
                    ("core", root / "core/Clash.Meta", ())]
    for name in ("tray_manager", "flutter_distributor"):
        if (root / "plugins" / name).is_dir():
            repositories.append((name, root / "plugins" / name, ()))
    for label, repository, pathspec in repositories:
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repository, text=True, encoding="utf-8").strip()
        if not re.fullmatch(r"[a-fA-F0-9]{40,64}", head):
            raise ReleaseError("Cannot bind a valid source revision for " + label)
        raw = subprocess.check_output(["git", "ls-files", "-z", "--", *pathspec], cwd=repository)
        files = raw.decode("utf-8").split("\0")
        tracked = {}
        for name in sorted(filter(None, files)):
            relative = Path(name)
            if relative.is_absolute() or ".." in relative.parts:
                raise ReleaseError("Invalid tracked build input path")
            if name in generated:
                continue
            path = repository / relative
            if path.is_symlink():
                tracked[name] = hashlib.sha256(os.readlink(path).encode("utf-8")).hexdigest()
            elif path.is_file():
                if label == 'client' and name == 'pubspec.yaml':
                    from check_fallback_assets import canonical_pubspec
                    tracked[name] = hashlib.sha256(canonical_pubspec(path.read_bytes())).hexdigest()
                else:
                    tracked[name] = digest(path)
            elif not path.is_dir():
                # A deleted tracked input is still a meaningful working tree
                # state; later changes must not silently enter this batch.
                tracked[name] = "missing"
        if not tracked:
            raise ReleaseError("No tracked compilation inputs found for " + label)
        snapshot[label] = {"head": head, "files": tracked}
    private = root / "flavors" / flavor
    private_files = [private / "flavor.yaml", private / "assets/fallback.bin"]
    private_files += [path for path in (private / "assets").rglob("*")
                      if path.is_file() and path.name != "fallback.bin"]
    snapshot["selected_flavor"] = {path.relative_to(root).as_posix(): digest(path) for path in private_files}
    return snapshot


def assert_sources(root: Path, sdk: Path, flavor: str, expected: dict) -> None:
    if capture_sources(root, sdk, flavor) != expected:
        raise ReleaseError("Compilation source/HEAD or selected brand input changed; stop this fixed-input release batch")


def archive_android_symbols(root: Path, batch: Path, flavor: str) -> Path | None:
    """Keep final APK inventory plus debug companions for upload after clean.

    Archives are local diagnostic inputs, never the uploader's staging folder.
    A later --reuse-prepared still repeats all identifier/coverage checks.
    """
    native = root / "build/sentry-native/android"
    dart = sorted((root / "build/debug-info").glob("app.android-*.symbols"))
    if not (native / "manifest.json").is_file() or not dart:
        return None
    archive = batch / "sentry-archive"
    archive.mkdir(mode=0o700, exist_ok=True)
    destination = archive / "build/sentry-native/android"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(native, destination, dirs_exist_ok=True)
    debug = archive / "build/debug-info"
    debug.mkdir(parents=True, exist_ok=True)
    for path in dart:
        shutil.copy2(path, debug / path.name)
    defines = json.loads((root / "flavor_defines.json").read_text(encoding="utf-8"))
    # Retain the enabled decision, never the actual DSN, AES or other defines.
    write_json(archive / "symbol-config.json", {"XB_FLAVOR_ID": flavor, "XB_DEBUG": "false",
               "XB_SENTRY_DSN": "enabled" if defines.get("XB_SENTRY_DSN", "").strip() else ""})
    return archive


def retain_verified_apk(apk: Path, batch: Path, inputs: dict, verification: dict) -> Path:
    """Keep the exact verified package before a network-dependent symbol step."""
    destination = batch / "verified-apk.apk"
    temporary = batch / "verified-apk.apk.new"
    expected = digest(apk)
    shutil.copyfile(apk, temporary)
    temporary.chmod(0o600)
    if digest(temporary) != expected:
        temporary.unlink(missing_ok=True)
        raise ReleaseError("The APK changed while saving the verified batch input")
    temporary.replace(destination)
    write_json(batch / "verified-apk.json", {**inputs, "artifact": destination.name,
               "sha256": expected, "sizeBytes": destination.stat().st_size,
               "apkVerification": verification, "stage": "apk_verified_before_symbols"})
    return destination


@contextlib.contextmanager
def temporary_android_configuration(root: Path, gradle_home: Path, *, flavor: str | None = None):
    """Restore complete prior properties/keystore, including any user ABI."""
    paths = [root / "android/local.properties", root / "android/app/keystore.jks"]
    original = {path: (path.read_bytes(), path.stat().st_mode & 0o777) if path.exists() else None
                for path in paths}
    pubspec = root / 'pubspec.yaml'
    original_pubspec = pubspec.read_bytes() if pubspec.is_file() else None
    init_dir = gradle_home / "init.d"
    init_dir.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix="xfl-local-no-crashlytics-", suffix=".gradle", dir=init_dir)
    init = Path(name)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(CRASHLYTICS_INIT)
    try:
        yield
    finally:
        for path, prior in original.items():
            if prior is None:
                path.unlink(missing_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(prior[0])
                path.chmod(prior[1])
        if init.exists() and init.read_text(encoding="utf-8") == CRASHLYTICS_INIT:
            init.unlink()
        if original_pubspec is not None:
            from check_fallback_assets import restore_pubspec_asset_block
            try:
                if pubspec.is_symlink() or not pubspec.is_file():
                    raise ValueError('pubspec_replaced_or_deleted')
                current = pubspec.read_bytes()
                restored = restore_pubspec_asset_block(original_pubspec, current, flavor)
                if restored != current:
                    fd, temporary_name = tempfile.mkstemp(prefix='.xfl-pubspec-', dir=pubspec.parent)
                    temporary = Path(temporary_name)
                    try:
                        with os.fdopen(fd, 'wb') as stream:
                            stream.write(restored)
                        temporary.chmod(pubspec.stat().st_mode & 0o777)
                        # Preserve edits observed after the merge input. Atomic
                        # replacement also avoids truncating the user's file if
                        # writing the merged result fails.
                        if pubspec.is_symlink() or pubspec.read_bytes() != current:
                            raise ValueError('pubspec_changed_during_restore')
                        temporary.replace(pubspec)
                    finally:
                        temporary.unlink(missing_ok=True)
            except (ValueError, OSError):
                raise ReleaseError('pubspec asset restoration conflict; current file preserved, release not promoted') from None


def set_abi(properties: Path, abi: str) -> None:
    text = properties.read_text(encoding="utf-8") if properties.exists() else ""
    kept = [line for line in text.splitlines()
            if line.split("=", 1)[0].strip() != "XB_TARGET_ABI"]
    properties.write_text("\n".join([*kept, "XB_TARGET_ABI=" + abi]) + "\n", encoding="utf-8")
    properties.chmod(0o600)


def elf_code(data: bytes, machine: int) -> dict[str, bytes]:
    if len(data) < 64 or data[:7] != b"\x7fELF\x02\x01\x01" or struct.unpack_from("<H", data, 18)[0] != machine:
        raise ReleaseError("AOT library has an invalid or unexpected ELF64 architecture")
    offset = struct.unpack_from("<Q", data, 40)[0]
    width, count, strings = struct.unpack_from("<HHH", data, 58)
    if width < 64 or not 0 < strings < count or offset < 64 or offset + width * count > len(data):
        raise ReleaseError("AOT ELF section table is invalid")
    headers = [struct.unpack_from("<IIQQQQIIQQ", data, offset + index * width) for index in range(count)]

    def contents(header):
        start, size = header[4:6]
        if header[1] == 8 or start + size > len(data):
            raise ReleaseError("AOT ELF section content is invalid")
        return data[start:start + size]

    if headers[strings][1] != 3:
        raise ReleaseError("AOT ELF section strings are invalid")
    names, result = contents(headers[strings]), {}
    for header in headers[1:]:
        end = names.find(b"\0", header[0])
        if header[0] >= len(names) or end < 0:
            raise ReleaseError("AOT ELF section name is invalid")
        name = names[header[0]:end]
        if name in (b".text", b".rodata"):
            if name.decode() in result or header[1] != 1 or not header[5]:
                raise ReleaseError("AOT ELF code sections are invalid")
            result[name.decode()] = contents(header)
    if set(result) != {".text", ".rodata"}:
        raise ReleaseError("AOT ELF code sections are missing")
    return result


class LocalBuild:
    def __init__(self, root: Path, batch: Path, environment: dict[str, str]):
        self.root, self.batch = root, batch
        self.symbol_environment = {key: value for key, value in environment.items() if key != "SENTRY_MAINTENANCE_TOKEN"}
        self.environment = {key: value for key, value in self.symbol_environment.items() if key != "SENTRY_AUTH_TOKEN"}
        self.steps: list[dict] = []
        self.child: subprocess.Popen | None = None

    def run(self, arguments: list[str], name: str, cwd: Path | None = None) -> None:
        began = time.monotonic()
        print("Starting " + name, flush=True)
        with (self.batch / (name + ".log")).open("wb") as log:
            child_environment = self.symbol_environment if name in {"sentry-preflight", "sentry-symbols"} else self.environment
            self.child = subprocess.Popen(arguments, cwd=cwd or self.root, env=child_environment,
                                          stdout=log, stderr=subprocess.STDOUT,
                                          start_new_session=os.name != "nt")
            try:
                code = self.child.wait()
            finally:
                if self.child.poll() is None:
                    if os.name != "nt":
                        os.killpg(self.child.pid, signal.SIGTERM)
                    else:
                        self.child.terminate()
                    try:
                        self.child.wait(timeout=20)
                    except subprocess.TimeoutExpired:
                        if os.name != "nt":
                            os.killpg(self.child.pid, signal.SIGKILL)
                        else:
                            self.child.kill()
                        self.child.wait()
                self.child = None
        self.steps.append({"step": name, "exitCode": code, "elapsedSeconds": round(time.monotonic() - began, 1)})
        print(name + ": exit " + str(code), flush=True)
        if code:
            raise ReleaseError("Build step failed: " + name + "; inspect the protected batch log")


def android_tools(environment: dict[str, str]) -> Path:
    sdk = environment.get("ANDROID_HOME") or environment.get("ANDROID_SDK_ROOT")
    if not sdk:
        raise ReleaseError("Source the Android environment: ANDROID_HOME is missing")
    choices = [path for path in (Path(sdk) / "build-tools").glob("*")
               if re.fullmatch(r"[0-9]+(?:\.[0-9]+)+", path.name)]
    if not choices:
        raise ReleaseError("Android SDK Build Tools are missing")
    tools = max(choices, key=lambda path: tuple(map(int, path.name.split("."))))
    for name in ("aapt", "apksigner", "zipalign"):
        if not (tools / name).is_file():
            raise ReleaseError("Android SDK verification tool is missing: " + name)
    return tools


def captured(arguments: list[str], environment: dict[str, str]) -> bytes:
    result = subprocess.run(arguments, env=environment, capture_output=True)
    if result.returncode:
        raise ReleaseError("APK verification tool failed; check the original signing input and SDK tools")
    return result.stdout


def verify_apk(root: Path, apk: Path, inputs: dict, tools: Path, environment: dict[str, str]) -> dict:
    from check_fallback_assets import verify as verify_fallback
    verify_fallback(root, inputs['flavor'], 'android', packages=[apk])
    badging = captured([str(tools / "aapt"), "dump", "badging", str(apk)], environment).decode("utf-8")
    package = re.search(r"^package: (.+)$", badging, re.M)
    if not package:
        raise ReleaseError("APK package metadata is missing")
    fields = dict(re.findall(r"([A-Za-z]+)='([^']*)'", package.group(1)))
    if (fields.get("name"), fields.get("versionCode"), fields.get("versionName")) != (
            inputs["packageName"], str(inputs["buildNumber"]), inputs["baseVersion"]):
        raise ReleaseError("APK package/version does not match the fixed release inputs")
    if "application-debuggable" in badging or "application-label:'" + inputs["displayName"] + "'" not in badging:
        raise ReleaseError("APK brand label or release/debug mode is incorrect")
    properties = dict(line.split("=", 1) for line in (root / "android/local.properties").read_text(encoding="utf-8").splitlines() if "=" in line)
    signing_environment = {**environment, "XFL_KEYSTORE_PASSWORD": properties.get("storePassword", "")}
    certificate = captured(["keytool", "-exportcert", "-keystore", str(root / "android/app/keystore.jks"),
                            "-alias", properties.get("keyAlias", ""), "-storepass:env", "XFL_KEYSTORE_PASSWORD"], signing_environment)
    expected_certificate = hashlib.sha256(certificate).hexdigest()
    signed = captured([str(tools / "apksigner"), "verify", "--print-certs", str(apk)], environment).decode("utf-8")
    match = re.search(r"Signer #1 certificate SHA-256 digest:\s*([a-fA-F0-9]{64})", signed)
    if not match or match.group(1).lower() != expected_certificate:
        raise ReleaseError("APK certificate does not match the selected original brand keystore")
    captured([str(tools / "zipalign"), "-c", "-P", "16", "4", str(apk)], environment)
    abi, _, _, machine = ARCHES[inputs["arch"]]
    fresh = root / f"build/app/intermediates/flutter/{inputs['flavor']}Release/jniLibs/{abi}/libapp.so"
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        packaged_abis = {name.split("/")[1] for name in names if name.startswith("lib/") and name.endswith(".so")}
        if packaged_abis != {abi}:
            raise ReleaseError("APK contains unexpected native ABIs")
        for library in ("libapp.so", "libflutter.so", "libclash.so", "libcore.so"):
            if names.count(f"lib/{abi}/{library}") != 1:
                raise ReleaseError("APK is missing a mandatory native library")
        fallback = f"assets/flutter_assets/flavors/{inputs['flavor']}/assets/fallback.bin"
        if names.count(fallback) != 1 or archive.read(fallback) != (root / f"flavors/{inputs['flavor']}/assets/fallback.bin").read_bytes():
            raise ReleaseError("APK fallback does not match the selected brand")
        if any(name.endswith(("flavor.yaml", "keystore.jks", "flavor_defines.json", "local.properties")) for name in names):
            raise ReleaseError("APK contains a private build input as an independent file")
        if elf_code(archive.read(f"lib/{abi}/libapp.so"), machine) != elf_code(fresh.read_bytes(), machine):
            raise ReleaseError("Packaged Dart AOT code differs from this clean Flutter build output")
    return {"signatureVerified": True, "certificateSha256": expected_certificate,
            "alignmentVerified": True, "nativeLibrariesVerified": True, "fallbackVerified": True,
            "privateInputsNotPackagedAsFiles": True, "aotCodeMatchesFlutterOutput": True}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("release", "debug"), nargs="?", default="release")
    parser.add_argument("arch", choices=ARCHES, nargs="?", default="arm64")
    parser.add_argument("flavor", choices=("brand_a", "brand_b"), nargs="?", default="brand_a")
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--batch-dir", type=Path, help="Protected fixed-input batch; pass again to retry it")
    parser.add_argument("--build-number", type=int)
    parser.add_argument("--build-tag")
    diagnostics = parser.add_mutually_exclusive_group()
    diagnostics.add_argument("--audit-only", action="store_true")
    diagnostics.add_argument("--no-sentry", action="store_true")
    args = parser.parse_args(argv)
    os.umask(0o077)
    root, environment = args.project_root.resolve(), dict(os.environ)
    batch, builder = args.batch_dir, None
    lock, lock_owned = root / "android/.xfl-local-build.lock", False
    started, old_sigterm = time.monotonic(), signal.getsignal(signal.SIGTERM)

    def interrupted(_signum, _frame):
        raise KeyboardInterrupt()

    signal.signal(signal.SIGTERM, interrupted)
    try:
        for name in ("flutter", "dart", "git", "bash", "keytool"):
            if not shutil.which(name):
                raise ReleaseError("Required local Android tool is unavailable: " + name)
        if not environment.get("ANDROID_NDK"):
            raise ReleaseError("Source the Android environment: ANDROID_NDK is missing")
        tools = android_tools(environment)
        # Serialize before reading/migrating the counter or writing batch inputs.
        descriptor = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(descriptor)
        lock_owned = True
        flavor_yaml = root / f"flavors/{args.flavor}/flavor.yaml"
        current = read_local_build_number(root, args.flavor)
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True, encoding="utf-8").strip()
        tag = args.build_tag or datetime.datetime.now().strftime("%Y%m%d%H%M")
        base, prefix = scalar(root / "pubspec.yaml", "version").split("+", 1)[0], scalar(flavor_yaml, "updatePackageName")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", prefix) or not re.fullmatch(r"[0-9]{12}", tag):
            raise ReleaseError("Unsafe package prefix or build tag")
        batch = batch.resolve() if batch else root / "dist/local-release" / f"{args.flavor}-{tag}-{args.arch}"
        batch.mkdir(parents=True, exist_ok=True, mode=0o700)
        batch.chmod(0o700)
        previous_inputs = batch / "build-inputs.json"
        previous = json.loads(previous_inputs.read_text(encoding="utf-8")) if previous_inputs.exists() else None
        if previous is not None and not isinstance(previous, dict):
            raise ReleaseError("The existing batch inputs are invalid")
        number = (args.build_number if args.build_number is not None else previous.get("buildNumber")
                  if previous is not None else current + (args.mode == "release"))
        validate_local_number(number)
        if number < current or (args.mode == "release" and number <= current):
            raise ReleaseError("A new release build number must exceed the current successful local counter")
        inputs = {"flavor": args.flavor, "arch": args.arch, "abi": ARCHES[args.arch][0], "buildMode": args.mode,
                  "buildNumber": number, "buildTag": tag, "baseVersion": base,
                  "productVersion": scalar(flavor_yaml, "versionName"), "packageName": scalar(flavor_yaml, "appId"),
                  "displayName": scalar(flavor_yaml, "appName"), "updatePackageName": prefix,
                  "sourceRevision": revision, "diagnosticMode": "no_sentry" if args.no_sentry else "audit_only" if args.audit_only else None}
        if previous is not None:
            if args.build_tag is None:
                inputs["buildTag"] = previous.get("buildTag")
            if previous != inputs:
                raise ReleaseError("The existing batch has different fixed inputs; use a new batch directory")
        else:
            write_json(previous_inputs, inputs)
        sdk = (root / "../Xboard_sdk").resolve()
        lock_paths = [root / "pubspec.lock", sdk / "pubspec.lock"]
        if not all(path.is_file() for path in lock_paths):
            raise ReleaseError("Client and sibling SDK lockfiles are required for a strict local release")
        locks = {path: digest(path) for path in lock_paths}
        sources = capture_sources(root, sdk, args.flavor)
        source_file = batch / "source-state.json"
        if source_file.exists():
            if json.loads(source_file.read_text(encoding="utf-8")) != sources:
                raise ReleaseError("The existing batch was bound to different source contents or revisions")
        else:
            write_json(source_file, sources)
        builder = LocalBuild(root, batch, environment)
        symbol = [sys.executable, str(root / "tool/postbuild_sentry_symbols.py"), "--platform", "android",
                  "--flavor", args.flavor, "--product-version", inputs["productVersion"], "--build-number", str(number),
                  "--source-revision", revision, "--evidence", str(batch / "sentry-symbols-evidence.json")]
        if args.audit_only:
            symbol.append("--audit-only")
        if args.no_sentry:
            symbol.append("--no-sentry")
        gradle_home = Path(environment.get("GRADLE_USER_HOME") or str(Path.home() / ".gradle"))
        with temporary_android_configuration(root, gradle_home, flavor=args.flavor):
            builder.run(["flutter", "pub", "get", "--enforce-lockfile"], "sdk-pub-get", sdk)
            builder.run(["flutter", "clean"], "clean")
            builder.run(["flutter", "pub", "get", "--enforce-lockfile"], "pub-get")
            if any(digest(path) != expected for path, expected in locks.items()):
                raise ReleaseError("Strict dependency resolution changed a lockfile; stop before compiling")
            assert_sources(root, sdk, args.flavor, sources)
            prepare = ["dart", "run", "tool/prepare_flavor.dart", "--flavor", args.flavor, "--target", "prod"]
            if args.mode == "release":
                prepare.append("--android-signing")
            builder.run(prepare, "prepare-flavor")
            if args.mode == "release":
                builder.run([*symbol, "--preflight"], "sentry-preflight")
            set_abi(root / "android/local.properties", inputs["abi"])
            assert_sources(root, sdk, args.flavor, sources)
            builder.run(["bash", "plugins/setup/buildkit/run_build_tool.sh", "android", "--arch", ARCHES[args.arch][2]], "go-core-build")
            command = ["flutter", "build", "apk", "--" + args.mode, "--flavor", args.flavor,
                       "--dart-define-from-file=flavor_defines.json", "--dart-define=APP_ENV=stable", "--dart-define=XB_FORM_A=true",
                       "--dart-define=XB_ANDROID_ABI=" + inputs["abi"], "--dart-define=XB_BUILD_TAG=" + inputs["buildTag"],
                       "--dart-define=XB_PRODUCT_VERSION=" + inputs["productVersion"], "--dart-define=XB_BUILD_NUMBER=" + str(number),
                       "--build-name=" + base, "--build-number=" + str(number), "--target-platform", ARCHES[args.arch][1]]
            if args.mode == "release":
                command.append("--split-debug-info=build/debug-info")
            builder.run(command, "flutter-apk")
            apk = root / f"build/app/outputs/flutter-apk/app-{args.flavor}-{args.mode}.apk"
            if not apk.is_file():
                raise ReleaseError("The successful build did not produce the expected fresh APK")
            report = verify_apk(root, apk, inputs, tools, builder.environment) if args.mode == "release" else {}
            if any(digest(path) != expected for path, expected in locks.items()):
                raise ReleaseError("A dependency lockfile changed; stop before symbol upload")
            assert_sources(root, sdk, args.flavor, sources)
            if args.mode == "release":
                # The retained, verified bytes become the final package input
                # for symbol matching and later promotion. A future clean does
                # not erase the package when an upload needs a retry.
                apk = retain_verified_apk(apk, batch, inputs, report)
                symbol_evidence = batch / "sentry-symbols-evidence.json"
                symbol_evidence.unlink(missing_ok=True)
                try:
                    builder.run([*symbol, "--package", str(apk)], "sentry-symbols")
                finally:
                    if not args.no_sentry:
                        archive = archive_android_symbols(root, batch, args.flavor)
                        if archive:
                            report["sentrySymbolArchive"] = str(archive)
                defines = json.loads((root / "flavor_defines.json").read_text(encoding="utf-8"))
                configured = bool(defines.get("XB_SENTRY_DSN", "").strip())
                if configured and not args.no_sentry:
                    evidence = json.loads(symbol_evidence.read_text(encoding="utf-8"))
                    expected_status = "audited" if args.audit_only else "uploaded_and_processed"
                    expected_metadata = {"status": expected_status, "platform": "android", "flavor": args.flavor,
                                         "product_version": inputs["productVersion"], "build_number": str(number), "source_revision": revision}
                    if not isinstance(evidence, dict) or any(evidence.get(key) != value for key, value in expected_metadata.items()):
                        raise ReleaseError("This batch has no matching Sentry symbol completion evidence")
                report["sentryConfigured"] = configured
                report["sentrySymbolsUploaded"] = configured and not inputs["diagnosticMode"]
                report["sentrySymbolMode"] = inputs["diagnosticMode"] or ("uploaded_and_processed" if configured else "not_configured")
            if any(digest(path) != expected for path, expected in locks.items()):
                raise ReleaseError("A dependency lockfile changed; release output remains unpromoted")
        # Temporary Gradle/signing/ABI state must restore successfully before a
        # verified output replaces any previous release or advances its counter.
        assert_sources(root, sdk, args.flavor, sources)
        suffix = "-debug" if args.mode == "debug" else "-diagnostic" if inputs["diagnosticMode"] else ""
        destination = root / "dist" / f"{prefix}-{inputs['productVersion']}-android-{inputs['abi']}{suffix}.apk"
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_suffix(".apk.new")
        shutil.copy2(apk, temporary)
        temporary.chmod(0o644)
        temporary.replace(destination)
        report.update(inputs, artifact=str(destination), sizeBytes=destination.stat().st_size,
                      sha256=digest(destination), status="verified_diagnostic" if inputs["diagnosticMode"] else "completed",
                      deviceInstallationTested=False, deviceSentryCaptureTested=False)
        write_json(batch / "verification.json", report)
        if args.mode == "release" and not inputs["diagnosticMode"]:
            write_local_build_number(root, args.flavor, number)
        print("Completed local APK: " + str(destination), flush=True)
        print("Verification: " + str(batch / "verification.json"), flush=True)
        return 0
    except (ReleaseError, OSError, ValueError, subprocess.CalledProcessError, KeyboardInterrupt, zipfile.BadZipFile) as error:
        message = str(error) if isinstance(error, ReleaseError) else type(error).__name__
        print("Local APK release failed: " + message, file=sys.stderr)
        return 1
    finally:
        if lock_owned:
            lock.unlink(missing_ok=True)
        if batch and batch.is_dir() and builder:
            write_json(batch / "steps.json", {"steps": builder.steps, "elapsedSeconds": round(time.monotonic() - started, 1)})
        signal.signal(signal.SIGTERM, old_sigterm)


if __name__ == "__main__":
    raise SystemExit(main())
