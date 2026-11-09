"""Replay Android SharedState on a JVM, then test the real Go decoder/options.

Only run on the authorized test host, under its heavy-work lock. Uses cached
compiler/dependencies; no Gradle app build, network listeners or VPN startup.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def run(client, output):
    output.mkdir(parents=True, exist_ok=False)
    cache = Path(os.environ['GRADLE_USER_HOME'])/'caches/modules-2/files-2.1'
    def jar(group, artifact, version):
        found = list((cache/group/artifact/version).glob('*/*.jar'))
        if len(found) != 1:
            raise RuntimeError(f'Expected one cached jar: {group}/{artifact}/{version}')
        return found[0]
    jars = [jar('org.jetbrains.kotlin', n, '2.4.20') for n in
            ['kotlin-compiler-embeddable', 'kotlin-stdlib', 'kotlin-script-runtime']]
    jars += [jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.10.2'),
             jar('org.jetbrains', 'annotations', '13.0'),
             jar('com.google.code.gson', 'gson', '2.13.1')]
    classpath = os.pathsep.join(map(str, jars))
    host = client/'android/app/src/main/kotlin/com/follow/clash/ServiceStateHost.kt'
    text = host.read_text()
    declarations = text[text.index('internal data class ServiceRuntime('):text.index('internal object AndroidServiceStateHost')]
    # Only AndroidServiceStateHost is excluded: declarations stay byte-for-byte,
    # and the real state machine/model source files are compiled unchanged.
    shim = output/'ServiceStateContracts.kt'
    shim.write_text('''package com.follow.clash
import com.follow.clash.models.SharedState
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.VpnOptions
import kotlinx.coroutines.CoroutineScope
''' + declarations)
    names = [
        'android/app/src/main/kotlin/com/follow/clash/ServiceStateMachine.kt',
        'android/app/src/main/kotlin/com/follow/clash/models/State.kt',
        'android/common/src/main/java/com/follow/clash/common/RunIntentArbiter.kt',
        'android/common/src/main/java/com/follow/clash/common/Enums.kt',
        'android/service/src/main/java/com/follow/clash/service/models/VpnOptions.kt',
        'android/service/src/main/java/com/follow/clash/service/models/NotificationParams.kt',
        'android/tests/app/LegacySetupForwardingProbe.kt',
    ]
    env = {**os.environ, 'GOMAXPROCS': '2', 'GOPROXY': 'off', 'GOTOOLCHAIN': 'local',
           'XB_SHARED_STATE_RECORDS': str(output/'forwarded.json')}
    commands = [
        ['java', '-Xmx1g', '-cp', classpath, 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
         '-no-stdlib', '-no-reflect', '-jvm-target', '17', '-classpath', classpath,
         '-d', str(output/'probe.jar'), str(shim), *[str(client/n) for n in names]],
        ['java', '-cp', str(output/'probe.jar')+os.pathsep+classpath,
         'com.follow.clash.LegacySetupForwardingProbe', str(output/'forwarded.json')],
        ['go', 'test', '-p', '2', '-vet=off', '-count=1', '-timeout=120s', '-json',
         '-run', '^TestV093', '.'],
    ]
    results=[]
    for i,command in enumerate(commands):
        r=subprocess.run(command,cwd=client/'core' if i==2 else client,
                         env=env,capture_output=True,text=True,timeout=900)
        (output/f'step-{i}.log').write_text(r.stdout+r.stderr)
        results.append({'step':i,'command':command,'exit_code':r.returncode})
        if r.returncode and i<2:break
    source_names=names+['android/app/src/main/kotlin/com/follow/clash/ServiceStateHost.kt',
        'core/protocol.go','core/config.go','core/delay.go','core/lib.go',
        'core/legacy_setup_validation_test.go']
    report={'steps':results,'source_sha256':{n:hashlib.sha256((client/n).read_bytes()).hexdigest() for n in source_names},
            'jar_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in jars},
            'boundary':'Real Kotlin models/state machine and real Go SetupParams/applyOptions; host storage/OS/QuickSetup JNI are controlled, no device/VPN/listener launched.'}
    (output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(results,indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--client',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();run(a.client.resolve(),a.output.resolve())
