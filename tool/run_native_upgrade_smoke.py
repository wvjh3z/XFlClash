#!/usr/bin/env python3
"""Run the v0.9.1 native chain on Linux with isolated data and loopback fixtures.

This is a local diagnostic, not a release/brand packaging or Sentry upload entry.
Requires Xvfb, xauth, dbus-run-session, and the explicitly selected toolchains.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import shlex
import re
from contextlib import contextmanager
import subprocess
import tempfile


def compiler_environment(root: Path, toolchains: Path) -> dict[str, str]:
    env = dict(os.environ)
    env.update({
        "FLUTTER_ROOT": str(toolchains / "flutter-3.47.6"),
        "FLUTTER_SUPPRESS_ANALYTICS": "true",
        "PUB_CACHE": str(toolchains / "cache/pub"),
        "CARGO_HOME": str(toolchains / "rust/cargo"),
        "RUSTUP_HOME": str(toolchains / "rust/rustup"),
        "RUSTUP_TOOLCHAIN": "1.99.0",
        "CARGO_BUILD_JOBS": "2",
        "CMAKE_BUILD_PARALLEL_LEVEL": "2",
        "GOPATH": str(toolchains / "cache/go"),
        "GOMODCACHE": str(toolchains / "cache/go/pkg/mod"),
        "GOCACHE": str(toolchains / "cache/go-build"),
        "GOFLAGS": "-p=2", "GOMAXPROCS": "2",
        "CC": "/usr/bin/clang", "CXX": "/usr/bin/clang++",
    })
    for key in list(env):
        if any(part in key.upper() for part in ("TOKEN", "PASSWORD", "SECRET")):
            env.pop(key)
    forwarded = {key: env[key] for key in (
        "CARGO_HOME", "RUSTUP_HOME", "RUSTUP_TOOLCHAIN", "CARGO_BUILD_JOBS",
        "GOPATH", "GOMODCACHE", "GOCACHE", "GOFLAGS", "GOMAXPROCS", "CC", "CXX",
    )}
    # Hooks preserve PATH, but filter custom Rust/cache variables. Compiler
    # launchers supply an explicit, non-secret allowlist. A changed environment
    # produces a different PATH and invalidates the hook cache.
    identity = hashlib.sha256(json.dumps(forwarded, sort_keys=True).encode()).hexdigest()[:16]
    launchers = root / ".dart_tool/xboard-toolchain-launchers" / identity
    launchers.mkdir(parents=True, exist_ok=True)
    for name in ("go", "rustup", "cargo", "rustc"):
        real = toolchains / ("go-1.27.1/bin/go" if name == "go" else "rust/cargo/bin/" + name)
        if not real.is_file():
            raise RuntimeError(f"Missing compiler: {real}")
        target = launchers / name
        target.write_text(
            "#!/usr/bin/python3\nimport os,sys\nenv=dict(os.environ)\n"
            f"env.update({forwarded!r})\nos.execve({str(real)!r},[{str(real)!r},*sys.argv[1:]],env)\n"
        )
        target.chmod(0o700)
    env["PATH"] = ":".join((str(launchers), str(toolchains / "flutter-3.47.6/bin"),
                             str(toolchains / "go-1.27.1/bin"), str(toolchains / "rust/cargo/bin"),
                             "/usr/bin", "/bin", env.get("PATH", "")))
    return env



@contextmanager
def fixture_assets(root: Path, flavor: str, port: int):
    # Never overwrite a production fallback in a developer checkout.
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    fallback = root / "flavors" / flavor / "assets/fallback.bin"
    if fallback.exists():
        raise RuntimeError("Use an isolated checkout without a production fallback.bin")
    pubspec = root / "pubspec.yaml"
    icon = root / "assets/images/icon.png"
    original_pubspec, original_icon = pubspec.read_bytes(), icon.read_bytes()
    selected_icon = (root / "flavors" / flavor / "assets/icons" / (flavor + ".png")).read_bytes()
    replacement = f"# xboard-fallback-assets:begin\n    - flavors/{flavor}/assets/\n    # xboard-fallback-assets:end"
    rewritten, count = re.subn(r"# xboard-fallback-assets:begin.*?# xboard-fallback-assets:end", replacement,
                               original_pubspec.decode(), flags=re.DOTALL)
    if count != 1:
        raise RuntimeError("Expected exactly one fallback asset block")
    origin = f"http://127.0.0.1:{port}"
    payload = json.dumps({"api_endpoints": [origin], "subscription_endpoints": [origin]}).encode()
    key = bytes((i * 7 + 3) % 256 for i in range(32))
    nonce = os.urandom(12)
    encrypted = AESGCM(key).encrypt(nonce, payload, b"xboard-bootstrap-v1")
    try:
        fallback.write_text(json.dumps({"schema_version": 1, "encrypted": base64.b64encode(nonce + encrypted).decode()}))
        pubspec.write_text(rewritten)
        icon.write_bytes(selected_icon)
        yield hashlib.sha256(selected_icon).hexdigest()
    finally:
        pubspec.write_bytes(original_pubspec)
        icon.write_bytes(original_icon)
        fallback.unlink(missing_ok=True)


def isolate_directories(batch: Path, env: dict[str, str]) -> None:
    for key, folder in (("XDG_CONFIG_HOME", "config"), ("XDG_DATA_HOME", "user-data"),
                        ("XDG_CACHE_HOME", "cache"), ("XDG_RUNTIME_DIR", "runtime")):
        target = batch / folder
        target.mkdir(mode=0o700)
        env[key] = str(target)
    # path_provider's Documents lookup uses xdg-user-dir, not XDG_DATA_HOME.
    documents = batch / "documents"
    documents.mkdir(mode=0o700)
    (batch / "config/user-dirs.dirs").write_text(
        "XDG_DOCUMENTS_DIR=" + shlex.quote(str(documents)) + "\n", encoding="utf-8"
    )


def main() -> int:
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--toolchains", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--flavor", choices=("brand_a", "brand_b"), required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    batch = Path(tempfile.mkdtemp(prefix=args.flavor + "-", dir=output))
    env = compiler_environment(root, args.toolchains.resolve())
    isolate_directories(batch, env)
    env.update({"XB_NATIVE_SMOKE_DIR": str(batch), "APPIMAGE": str(batch / "direct-launch-fixture"),
                "LIBGL_ALWAYS_SOFTWARE": "1", "GDK_BACKEND": "x11", "FLUTTER_LINUX_RENDERER": "software"})
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 31991 if args.flavor == "brand_a" else 31992))
        port = reservation.getsockname()[1]
    key = base64.b64encode(bytes((i * 7 + 3) % 256 for i in range(32))).decode()
    cmd = ["xvfb-run", "--auto-servernum", "--server-args=-screen 0 1600x1000x24 -nolisten tcp",
           "dbus-run-session", "--", "/usr/bin/python3", str(root / "tool/native_smoke_session.py"),
           str(args.toolchains.resolve() / "flutter-3.47.6/bin/flutter"),
           "--suppress-analytics", "drive", "--no-pub", "--no-enable-impeller", "--driver=test_driver/native_upgrade_chain.dart", "-d", "linux",
           "--dart-define=XB_FORM_A=true", f"--dart-define=XB_FLAVOR_ID={args.flavor}",
           "--dart-define=XB_APP_NAME=" + ("OmoFly" if args.flavor == "brand_a" else "袋鼠加速"),
           f"--dart-define=XB_AES_KEY_B64={key}", "--dart-define=XB_SENTRY_DSN=",
           f"--dart-define=XB_FIXTURE_PORT={port}", "--target=integration_test/native_upgrade_chain_test.dart"]
    print(f"Native diagnostic batch: {batch}", flush=True)
    with fixture_assets(root, args.flavor, port) as icon_hash:
        cmd.insert(-1, f"--dart-define=XB_FIXTURE_ICON_SHA256={icon_hash}")
        with (batch / "run.log").open("w") as log:
            process = subprocess.Popen(cmd, cwd=root, env=env, stdout=log, stderr=subprocess.STDOUT,
                                       start_new_session=True)
            try:
                code = process.wait(timeout=1200)
            except BaseException:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=15)
                raise
    result = batch / "result.json"
    if code == 0 and not result.is_file():
        raise RuntimeError(f"Test runner exited without native acceptance evidence: {batch}")
    if code == 0:
        evidence = json.loads(result.read_text())
        if evidence.get("passed") is not True or evidence.get("brand") != args.flavor:
            raise RuntimeError("Native acceptance evidence does not match the requested brand")
    print(f"Exit {code}; log: {batch / 'run.log'}", flush=True)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
