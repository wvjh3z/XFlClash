#!/usr/bin/env python3
"""Prepare versioned native build inputs; never compile/package the client."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
import re
import shutil
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile
from fetch_build_asset import download_asset

ROOT = Path(__file__).resolve().parents[1]
PINS = json.loads((ROOT / 'tool/native_toolchain.json').read_text(encoding='utf-8'))


def targets(target, architecture):
    if target == 'android':
        return ['armv7-linux-androideabi','aarch64-linux-android','x86_64-linux-android']
    arch = {'amd64':'x86_64','x64':'x86_64','x86_64':'x86_64','arm64':'aarch64','aarch64':'aarch64'}.get(architecture)
    if not arch: raise RuntimeError('Unsupported native architecture')
    suffix = {'linux':'unknown-linux-gnu','macos':'apple-darwin','windows':'pc-windows-msvc'}[target]
    return [arch+'-'+suffix]


def prepare_ca(root, *, downloader=download_asset):
    output = root / 'core/Clash.Meta/component/ca/ca-certificates.crt'
    if not output.parent.is_dir() or output.is_symlink():
        raise RuntimeError('Initialize the pinned Core submodule before native preparation')
    expected = PINS['ca_sha256']
    if output.is_file() and hashlib.sha256(output.read_bytes()).hexdigest() == expected:
        return
    with tempfile.TemporaryDirectory(prefix='.ca-', dir=output.parent) as temporary:
        candidate = Path(temporary) / 'cacert.pem'
        downloader(candidate, PINS['ca_url'], 1024*1024)
        data = candidate.read_bytes()
        if hashlib.sha256(data).hexdigest() != expected or b'BEGIN CERTIFICATE' not in data:
            raise RuntimeError('Pinned Core CA bundle checksum mismatch')
        os.replace(candidate, output)


def prepare_macos_renderer(root, architecture):
    path = root / 'macos/Runner/Info.plist'
    with path.open('rb') as stream:
        value = plistlib.load(stream)
    if architecture in ('amd64','x64','x86_64'):
        value['FLTEnableImpeller'] = False
    elif architecture in ('arm64','aarch64'):
        # Clear a preceding local Intel build's workaround on architecture switch.
        value.pop('FLTEnableImpeller', None)
    else:
        raise RuntimeError('Unsupported macOS architecture')
    path.write_bytes(plistlib.dumps(value, sort_keys=False))


def prepare_android_names(root):
    # Windows brand outputs must not leak into a subsequent Android build.
    path = root / 'build_config.yaml'
    if not path.is_file():
        return  # Upstream defaults already use these names.
    source = path.read_text(encoding='utf-8')
    for key, value in (('core_name','FlClashCore'),('helper_name','FlClashHelperService')):
        pattern = re.compile(r'^'+key+r':[^\r\n]*',re.M)
        if len(pattern.findall(source)) != 1:
            raise RuntimeError('Native output identity missing or ambiguous')
        source = pattern.sub(key+': "'+value+'"',source)
    path.write_text(source,encoding='utf-8')


def resolve_rustup(environment=None):
    environment = os.environ if environment is None else environment
    executable = shutil.which('rustup', path=environment.get('PATH', ''))
    if not executable:
        raise RuntimeError('rustup unavailable on the native preparation PATH')
    return str(Path(executable).absolute())


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--platform', required=True, choices=('android','linux','macos','windows'))
    p.add_argument('--architecture', default=platform.machine().lower())
    p.add_argument('--install-rust-targets', action='store_true')
    args = p.parse_args()
    if args.platform == 'android':
        prepare_android_names(ROOT)
    prepare_ca(ROOT)
    if args.platform == 'macos':
        prepare_macos_renderer(ROOT, args.architecture)
    if args.install_rust_targets:
        rustup = resolve_rustup()
        subprocess.run([rustup,'toolchain','install',PINS['rust'],'--profile','minimal'],check=True,timeout=600)
        subprocess.run([rustup,'target','add','--toolchain',PINS['rust'],*targets(args.platform,args.architecture)],check=True,timeout=600)
    print('Native inputs ready for '+args.platform+' (fixed CA checksum and Rust target policy)')


if __name__ == '__main__': main()
