#!/usr/bin/env python3
"""Collect allowlisted tool versions, never environment variables or credentials."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys

from release_pipeline import write_json

ROOT = Path(__file__).resolve().parents[1]


def command_version(command):
    try:
        result = subprocess.run(command,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=15)
        text = result.stdout+'\n'+result.stderr
        # Preserve only numeric version tokens, not arbitrary process output/paths.
        versions = re.findall(r'(?<![A-Za-z0-9.])(?:go|v)?(\d+\.\d+(?:\.\d+){0,2}(?:[-+][A-Za-z0-9.-]+)?)',text)
        return {'status':'ok' if result.returncode == 0 else 'failed', 'versions':versions[:8]}
    except (OSError,subprocess.TimeoutExpired):
        return {'status':'unavailable','versions':[]}


def collect(target, root=ROOT):
    data = {'schema_version':1,'target':target,'host':platform.system(),'machine':platform.machine(),
            'python':platform.python_version(),'tools':{},
            'runner_image':{k:os.environ[k] for k in ('ImageOS','ImageVersion','RUNNER_OS','RUNNER_ARCH')
                            if re.fullmatch(r'[A-Za-z0-9_.-]{1,80}',os.environ.get(k,''))}}
    for name,args in [('git',['--version']),('go',['version']),('cmake',['--version']),
                      ('node',['--version']),('sentry-cli',['--version'])]:
        executable=shutil.which(name)
        data['tools'][name]=command_version([executable,*args]) if executable else {'status':'unavailable','versions':[]}
    flutter_root = Path(os.environ.get('FLUTTER_ROOT',''))
    dart = flutter_root/('bin/cache/dart-sdk/bin/dart.exe' if os.name=='nt' else 'bin/cache/dart-sdk/bin/dart')
    data['tools']['dart'] = command_version([str(dart),'--version']) if dart.is_file() else command_version(['dart','--version'])
    # Flutter's machine output is parsed to a fixed set of public fields.
    flutter = [str(dart),str(flutter_root/'bin/cache/flutter_tools.snapshot')] if dart.is_file() else ['flutter']
    try:
        result=subprocess.run([*flutter,'--version','--machine'],capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=20)
        value=json.loads(result.stdout)
        if result.returncode != 0 or not isinstance(value,dict): raise ValueError('invalid_flutter_version_output')
        data['flutter']={key:value[key] for key in ('frameworkVersion','frameworkRevision','engineRevision','dartSdkVersion','channel') if isinstance(value.get(key),str)}
    except (OSError,ValueError,subprocess.TimeoutExpired):
        data['flutter']={'status':'unavailable'}
    if target=='macos':
        data['tools']['appdmg']=command_version(['appdmg','--version'])
        data['tools']['xcode']=command_version(['xcodebuild','-version'])
    if target=='windows':
        compiler=Path(r'C:\Program Files (x86)\Inno Setup 6\ISCC.exe')
        data['tools']['inno']=command_version([str(compiler),'/?'])
        versions=set()
        for path in (root/'build/windows').glob('**/CMakeCXXCompiler.cmake'):
            text=path.read_text(encoding='utf-8',errors='replace')
            versions.update(re.findall(r'set\(CMAKE_CXX_COMPILER_VERSION "([0-9.]+)"\)',text))
        data['msvc']=sorted(versions)
    if target=='android':
        ndk=Path(os.environ.get('ANDROID_NDK_HOME',os.environ.get('ANDROID_NDK_ROOT','')))/'source.properties'
        if ndk.is_file():
            value=re.search(r'^Pkg.Revision\s*=\s*([0-9.]+)',ndk.read_text(encoding="utf-8"),re.M)
            if value:data['ndk']=value[1]
    return data


def main(argv=None):
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--platform',choices=['windows','android','macos','linux'])
    p.add_argument('--output',default='build/toolchain-versions.json')
    p.add_argument('--print-appdmg-pin',action='store_true')
    a=p.parse_args(argv)
    pin=json.loads((ROOT/'tool/build-tools.json').read_text(encoding="utf-8"))['appdmg']
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+',pin):return 1
    if a.print_appdmg_pin:
        print(pin);return 0
    if not a.platform:p.error('--platform required')
    data=collect(a.platform)
    write_json(a.output,data)
    if a.platform=='macos' and (data['tools']['appdmg']['status']!='ok' or pin not in [v.lstrip('v') for v in data['tools']['appdmg']['versions']]):
        print('Expected appdmg '+pin+'; see toolchain version inventory for the installed version',file=sys.stderr);return 1
    print('Toolchain version inventory recorded (no environment dump)')
    return 0


if __name__=='__main__':
    raise SystemExit(main())
