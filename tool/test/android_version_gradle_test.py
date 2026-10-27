"""Execute production onVariants policy using real AGP; no APK compilation."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import sys
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tool'))
from prepare_test_gradle import prepare

class GradlePolicyTest(unittest.TestCase):
    def test_real_agp_variants_and_negative_controls(self):
        source=(ROOT/'android/app/build.gradle.kts').read_text()
        policy=source[source.index('val androidVersionPolicy ='):source.index('\nkotlin {')]
        sdk=os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT']
        with tempfile.TemporaryDirectory(prefix='android-version-') as tmp:
            root=Path(tmp);project=root/'android';project.mkdir();(root/'tool').mkdir()
            gradle=prepare(root/'gradle')
            (root/'tool/android_version_policy.json').write_bytes((ROOT/'tool/android_version_policy.json').read_bytes())
            (project/'settings.gradle.kts').write_text('pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\n dependencyResolutionManagement { repositories { google(); mavenCentral() } }\nrootProject.name="version-policy"\n')
            (project/'local.properties').write_text('sdk.dir='+sdk+'\n')
            prefix='''import groovy.json.JsonSlurper
plugins { id("com.android.application") version "9.4.1" }
val productBuild = providers.gradleProperty("productBuild").orElse("38").get().toInt()
class FlutterFixture(val versionCode: Int)
val flutter = FlutterFixture(productBuild)
fun androidBrandIdentity(brand: String): Map<String,String>? = mapOf("appId" to "com.example.$brand")
android {
 namespace="com.example.fixture"
 compileSdk=37
 defaultConfig { minSdk=24; versionCode=productBuild }
 flavorDimensions += "brand"
 productFlavors {
  create("brand_a") { dimension="brand"; applicationId="com.example.a" }
  create("brand_b") { dimension="brand"; applicationId="com.example.b" }
 }
 splits { abi { isEnable = providers.gradleProperty("split").get() == "true"; reset(); include("armeabi-v7a","arm64-v8a"); isUniversalApk = false } }
}
val actualVersions = mutableListOf<Pair<String, org.gradle.api.provider.Property<Int>>>()
// Simulate Flutter's earlier callback: policy must win on actual AGP output properties.
androidComponents { onVariants(selector().all()) { variant ->
 variant.outputs.forEach { output -> output.versionCode.set(2000+productBuild) }
} }
'''
            suffix='''
androidComponents { onVariants(selector().all()) { variant ->
 variant.outputs.forEach { output -> actualVersions.add(variant.name to output.versionCode) }
} }
tasks.register("checkVersionPolicy") { doLast {
 check(actualVersions.map { it.first }.toSet().size == 4)
 check(actualVersions.size == if(providers.gradleProperty("split").get()=="true") 8 else 4)
 actualVersions.forEach { check(it.second.get()==1000000+productBuild) { "WRONG_VERSION: ${it.first}: ${it.second.get()}" } }
 println("VERSION_POLICY_OK")
} }
'''
            def run(body, split, build):
                (project/'build.gradle.kts').write_text(prefix+body+suffix)
                return subprocess.run([str(gradle),'-p',str(project),'--no-daemon','--console=plain',f'-Psplit={str(split).lower()}',f'-PproductBuild={build}','checkVersionPolicy'],capture_output=True,text=True,timeout=300)
            for split in [False,True]:
                r=run(policy,split,38);self.assertEqual(r.returncode,0,r.stdout+r.stderr);self.assertIn('VERSION_POLICY_OK',r.stdout)
            r=run('',True,38);self.assertNotEqual(r.returncode,0);self.assertIn('WRONG_VERSION',r.stdout+r.stderr)
            for build in [0,2099000001]:
                r=run(policy,False,build);self.assertNotEqual(r.returncode,0)
                expected = 'should be a positive integer' if build == 0 else 'exceeds the Android installer'
                self.assertIn(expected,r.stdout+r.stderr)
            r=run(policy,True,2099000000);self.assertEqual(r.returncode,0,r.stdout+r.stderr)

if __name__=='__main__':unittest.main()
