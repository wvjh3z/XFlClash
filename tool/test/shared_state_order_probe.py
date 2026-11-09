"""Plain JVM validation of real ServicePlugin -> ServiceStateMachine ordering.

Only compile on the authorized test host. Platform/Flutter/loader stubs are
unused API scaffolding; dispatch, parsing scheduling and state assignment use
unaltered production files. Gson is replaced with a barrier-controlled adapter.
"""
from pathlib import Path
import argparse
import os
import subprocess
import hashlib
import json

STUBS = {
 'Flutter.kt': '''package io.flutter.embedding.engine.plugins
import io.flutter.plugin.common.BinaryMessenger
interface FlutterPlugin {
 class FlutterPluginBinding(val binaryMessenger: BinaryMessenger)
 fun onAttachedToEngine(binding: FlutterPluginBinding)
 fun onDetachedFromEngine(binding: FlutterPluginBinding)
}
''',
 'Engine.kt': '''package io.flutter.embedding.engine
class FlutterEngine
''',
 'Channels.kt': '''package io.flutter.plugin.common
import java.nio.ByteBuffer
interface BinaryMessenger {
 fun makeBackgroundTaskQueue(): Any = Any()
 fun send(channel: String, data: ByteBuffer) { error("Unexpected event transport") }
}
class MethodCall(val method: String, val arguments: Any?)
class StandardMethodCodec {
 companion object { val INSTANCE = StandardMethodCodec() }
 fun encodeMethodCall(call: MethodCall): ByteBuffer = ByteBuffer.allocate(0)
}
class MethodChannel(messenger: BinaryMessenger, name: String,
 codec: StandardMethodCodec = StandardMethodCodec.INSTANCE, queue: Any? = null) {
 fun interface MethodCallHandler { fun onMethodCall(call: MethodCall, result: Result) }
 interface Result {
  fun success(result: Any?)
  fun error(code: String, message: String?, details: Any?)
  fun notImplemented()
 }
 fun setMethodCallHandler(handler: MethodCallHandler?) {}
 fun invokeMethod(method: String, arguments: Any?) { error("Unexpected outgoing method") }
}
''',
 'Common.kt': '''package com.follow.clash.common
object Components { const val PACKAGE_NAME = "example.fixture" }
object GlobalState { fun log(message: String) {} }
''',
 'Core.kt': '''package com.follow.clash.core
object Core { fun load() {} }
''',
 'Network.kt': '''package com.follow.clash.service
object NetworkObserver { fun start() { error("Network startup forbidden") } }
''',
 'Host.kt': '''package com.follow.clash
import com.follow.clash.models.SharedState
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.VpnOptions
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.*
object ServiceController {
 fun setEventListener(listener: ((ByteArray) -> Unit)?): Result<Unit> = Result.success(Unit)
 fun invokeMethod(data: String, callback: (String) -> Unit): Result<Unit> = error("Core I/O forbidden")
}
internal object AndroidServiceStateHost : ServiceStateHost {
 override val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
 override val runtime: ServiceRuntime? = null
 override val homeDirPath = "/isolated/fixture"
 override val sdkInt = 34
 override fun log(message: String) {}
 override fun showToast(message: String) {}
 override fun updateNotificationParams(params: NotificationParams) {}
 override fun loadSharedState(): SharedState = error("Storage read not expected")
 override fun isVpnPermissionGranted() = true
 override fun isLocalNetworkPermissionGranted() = true
 override fun tile(): TileGateway? = null
 override fun app(): AppGateway? = null
 override fun notifyStopped() {}
 override suspend fun quickSetup(initParams: String, setupParams: String): Result<String> = error("Core setup forbidden")
 override suspend fun startService(options: VpnOptions): Boolean = error("Service startup forbidden")
 override suspend fun stopService() { error("Service stop forbidden") }
 fun attachFlutterEngine(engine: FlutterEngine) {}
 fun detachFlutterEngine(engine: FlutterEngine) {}
}
''',
}

def run(client, output):
    output.mkdir(parents=True, exist_ok=False)
    cache=Path(os.environ['GRADLE_USER_HOME'])/'caches/modules-2/files-2.1'
    def jar(group, name, version):
        files=list((cache/group/name/version).glob('*/*.jar'))
        if len(files)!=1:raise RuntimeError(f'Cached jar unavailable: {name}/{version}')
        return files[0]
    jars=[jar('org.jetbrains.kotlin',n,'2.4.20') for n in ['kotlin-compiler-embeddable','kotlin-stdlib','kotlin-script-runtime']]
    jars += [jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.10.2'),jar('org.jetbrains','annotations','13.0'),jar('com.google.code.gson','gson','2.13.1')]
    cp=os.pathsep.join(map(str,jars))
    host=client/'android/app/src/main/kotlin/com/follow/clash/ServiceStateHost.kt'
    text=host.read_text();declarations=text[text.index('internal data class ServiceRuntime('):text.index('internal object AndroidServiceStateHost')]
    scaffolds=[]
    for name,body in STUBS.items():
        path=output/name;path.write_text(body);scaffolds.append(path)
    path=output/'Contracts.kt';path.write_text('''package com.follow.clash
import com.follow.clash.models.SharedState
import com.follow.clash.service.models.NotificationParams
import com.follow.clash.service.models.VpnOptions
import kotlinx.coroutines.CoroutineScope
'''+declarations);scaffolds.append(path)
    sources=['android/app/src/main/kotlin/com/follow/clash/plugins/ServicePlugin.kt',
      'android/app/src/main/kotlin/com/follow/clash/ServiceState.kt',
      'android/app/src/main/kotlin/com/follow/clash/ServiceStateMachine.kt',
      'android/app/src/main/kotlin/com/follow/clash/models/State.kt',
      'android/common/src/main/java/com/follow/clash/common/RunIntentArbiter.kt',
      'android/common/src/main/java/com/follow/clash/common/Enums.kt',
      'android/service/src/main/java/com/follow/clash/service/models/VpnOptions.kt',
      'android/service/src/main/java/com/follow/clash/service/models/NotificationParams.kt',
      'tool/test/fixtures/shared_state_order/Probe.kt']
    command=['java','-Xmx1g','-cp',cp,'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-jvm-target','17','-classpath',cp,'-d',str(output/'probe.jar'),*map(str,scaffolds),*[str(client/n) for n in sources]]
    p=subprocess.run(command,capture_output=True,text=True,timeout=300)
    (output/'compile.log').write_text(p.stdout+p.stderr)
    report={'compile_exit':p.returncode,'compile_command':command,'cases':[],
      'source_sha256':{n:hashlib.sha256((client/n).read_bytes()).hexdigest() for n in sources},
      'boundary':'Production scheduling/dispatcher/state machine unchanged. Reflective Gson parser barrier; OS/channel/Core loader mocked. Not an Android device or binary messenger test.'}
    if p.returncode==0:
        for mode in ['sequential','reordered','invalid']:
            cmd=['java','-cp',str(output/'probe.jar')+os.pathsep+cp,'com.follow.clash.Probe',mode,str(output/(mode+'.json'))]
            result=subprocess.run(cmd,capture_output=True,text=True,timeout=30)
            (output/(mode+'.log')).write_text(result.stdout+result.stderr)
            report['cases'].append({'mode':mode,'exit_code':result.returncode,'result':json.loads((output/(mode+'.json')).read_text()) if (output/(mode+'.json')).exists() else None})
    (output/'result.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report['cases'] if p.returncode==0 else {'compile_exit':p.returncode,'output':p.stdout+p.stderr}))

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--client',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    args=p.parse_args();run(args.client.resolve(),args.output.resolve())
