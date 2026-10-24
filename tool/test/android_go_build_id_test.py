#!/usr/bin/env python3
"""Real NDK/Go c-shared fixtures; no application or network build.

Use gomobile's clang --target form (not the target-specific clang wrapper).
The latter hides the ARM32 linker feature-probe failure observed in #123.
"""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tool'))
from sentry_elf import inspect_elf


def production_flags():
    source = (ROOT/'android/core/build.gradle.kts').read_text(encoding='utf-8')
    match = re.search(r'val flags =[^\n]*\+ listOf\(([^)]*)\)', source)
    if not match:
        raise ValueError('Android Go linker policy not found')
    flags = json.loads('[' + match[1] + ']')
    if not all(isinstance(flag, str) for flag in flags):
        raise ValueError('Invalid Android Go linker policy')
    return flags


class AndroidGoBuildIdTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.go = shutil.which('go')
        ndk = os.environ.get('ANDROID_NDK') or os.environ.get('ANDROID_NDK_HOME')
        if not cls.go or not ndk:
            raise RuntimeError('Real Go and pinned Android NDK are required (do not skip this CI gate)')
        hosts = list((Path(ndk)/'toolchains/llvm/prebuilt').glob('*'))
        cls.bin = next((p/'bin' for p in hosts if (p/'bin/clang').is_file()), None)
        if cls.bin is None:
            raise RuntimeError('NDK clang unavailable')
        cls.flags = production_flags()
        cls.api = re.search(r'(?m)^minSdk\s*=\s*"(\d+)"',
                            (ROOT/'android/gradle/libs.versions.toml').read_text()).group(1)

    def test_gomobile_link_and_strip_both_abis_with_old_arm32_negative_control(self):
        with tempfile.TemporaryDirectory(prefix='go-symbol-contract-') as folder:
            root = Path(folder)
            source = root/'fixture.go'
            source.write_text('package main\nimport "C"\n//export Probe\nfunc Probe(v C.int) C.int { return v+1 }\nfunc main(){}\n')
            for arch, triple, expected in [('arm','armv7a-linux-androideabi','arm'),
                                           ('arm64','aarch64-linux-android','aarch64')]:
                with self.subTest(arch=arch):
                    env = {**os.environ, 'GOOS':'android', 'GOARCH':arch, 'GOARM':'7',
                           'CGO_ENABLED':'1', 'CGO_CFLAGS':'-O2 -g',
                           'CC':str(self.bin/'clang')+' --target='+triple+self.api,
                           'GOPROXY':'off', 'GOSUMDB':'off', 'GOTOOLCHAIN':'local'}
                    def build(name, flags):
                        binary=root/(arch+'-'+name+'.so')
                        # Legacy strip flags must be overridden by the production policy.
                        command=[self.go,'build','-buildmode=c-shared',
                                 '-ldflags=-s -w '+' '.join(flags),'-o',str(binary),str(source)]
                        run=subprocess.run(command,env=env,capture_output=True,text=True,timeout=240)
                        self.assertEqual(run.returncode,0,run.stderr)
                        return binary
                    binary=build('fixed',self.flags)
                    info=inspect_elf(binary)
                    self.assertEqual(info['architecture'],expected)
                    self.assertTrue(info['build_id'])
                    self.assertTrue(info['has_debug_info'] and info['has_debug_line'])
                    runtime=root/(arch+'-runtime.so')
                    debug=root/(arch+'-debug.so')
                    subprocess.run([str(self.bin/'llvm-objcopy'),'--strip-unneeded',str(binary),str(runtime)],check=True)
                    subprocess.run([str(self.bin/'llvm-objcopy'),'--only-keep-debug',str(binary),str(debug)],check=True)
                    for path in [runtime,debug]:
                        self.assertEqual(inspect_elf(path)['build_id'],info['build_id'])
                        self.assertEqual(inspect_elf(path)['architecture'],expected)
                    self.assertTrue(inspect_elf(debug)['has_debug_info'])
                    self.assertFalse(inspect_elf(debug)['has_executable_text'])
                    if arch=='arm':
                        old=build('old',[x for x in self.flags if not x.startswith('-extldflags=')])
                        self.assertFalse(inspect_elf(old)['build_id'],
                                         'Pinned Go/NDK old-policy control changed; review the probe assumption')


if __name__=='__main__': unittest.main()
