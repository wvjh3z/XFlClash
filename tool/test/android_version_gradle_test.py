"""Real Flutter Gradle plugin + AGP output policy, no client/APK compilation."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import sys
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))
from prepare_test_gradle import prepare


class GradlePolicyTest(unittest.TestCase):
    def test_real_agp_variants_and_negative_controls(self):
        source = (ROOT / 'android/app/build.gradle.kts').read_text(encoding='utf-8')
        policy = source[source.index('val androidVersionPolicy ='):source.index('\nkotlin {')]
        sdk = os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT']
        flutter = Path(os.environ['FLUTTER_ROOT']) if os.environ.get('FLUTTER_ROOT') else Path(shutil.which('flutter')).resolve().parents[1]
        self.assertTrue((flutter / 'packages/flutter_tools/gradle').is_dir())
        with tempfile.TemporaryDirectory(prefix='android-version-') as tmp:
            root = Path(tmp)
            project = root / 'android'
            app = project / 'app'
            app.mkdir(parents=True)
            (root / 'tool').mkdir()
            gradle = prepare(root / 'gradle')
            (root / 'tool/android_version_policy.json').write_bytes((ROOT / 'tool/android_version_policy.json').read_bytes())
            (root / 'pubspec.yaml').write_text('name: version_fixture\nversion: 1.0.0+38\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n', encoding='utf-8')
            (project / 'settings.gradle.kts').write_text('''pluginManagement {
 includeBuild(FLUTTER_GRADLE)
 repositories { google(); mavenCentral(); gradlePluginPortal() }
}
plugins {
 id("com.android.application") version "9.4.1" apply false
 id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}
rootProject.name="version-policy"
include(":app")
'''.replace('FLUTTER_GRADLE', json.dumps(str(flutter / 'packages/flutter_tools/gradle'))), encoding='utf-8')
            (project / 'build.gradle.kts').write_text('allprojects { repositories { google(); mavenCentral() } }\n', encoding='utf-8')
            prefix = '''import groovy.json.JsonSlurper
plugins {
 id("com.android.application")
 id("dev.flutter.flutter-gradle-plugin")
}
val productBuild = flutter.versionCode
fun androidBrandIdentity(brand: String): Map<String,String>? = mapOf("appId" to "com.example.$brand")
android {
 namespace="com.example.fixture"
 compileSdk=37
 defaultConfig { minSdk=24; versionCode=productBuild; versionName="0.9.1" }
 flavorDimensions += "brand"
 productFlavors {
  create("brand_a") { dimension="brand"; applicationId="com.cloud.app.omofly" }
  create("brand_b") { dimension="brand"; applicationId="com.cloud.app.daishu" }
 }
}
flutter { source="../.." }
'''
            suffix = '''
// Keep providers live: inspect only after ALL real Flutter callbacks have run.
val actualVersions = mutableListOf<Pair<String, org.gradle.api.provider.Property<Int>>>()
androidComponents { onVariants(selector().all()) { variant ->
 variant.outputs.forEach { output -> actualVersions.add(variant.name to output.versionCode) }
} }
tasks.register("checkVersionPolicy") { doLast {
 check(actualVersions.map { it.first }.toSet().size == 6)
 check(actualVersions.size == if(providers.gradleProperty("split-per-abi").get()=="true") 12 else 6)
 actualVersions.forEach {
  println("OBSERVED_VERSION: ${it.first}: ${it.second.get()}")
 }
 val wrong = actualVersions.filter { it.second.get()!=1000000+productBuild }
 check(wrong.isEmpty()) { "WRONG_VERSION: " + wrong.map { "${it.first}: ${it.second.get()}" } }
 println("VERSION_POLICY_OK")
} }
'''
            properties = (ROOT / 'android/gradle.properties').read_text(encoding='utf-8')
            def run(body, split, build, *, disable_offset=True):
                (project / 'local.properties').write_text(f'sdk.dir={sdk}\nflutter.sdk={flutter}\nflutter.versionCode={build}\nflutter.versionName=0.9.1\n', encoding='utf-8')
                selected = properties if disable_offset else '\n'.join(x for x in properties.splitlines() if not x.startswith('force-version-code-ignoring-abi='))
                (project / 'gradle.properties').write_text(selected, encoding='utf-8')
                (app / 'build.gradle.kts').write_text(prefix + body + suffix, encoding='utf-8')
                command = [str(gradle), '-p', str(project), '--no-daemon', '--console=plain',
                           f'-Psplit-per-abi={str(split).lower()}',
                           '-Ptarget-platform=' + ('android-arm,android-arm64' if split else 'android-arm64'),
                           ':app:checkVersionPolicy']
                r = subprocess.run(command, capture_output=True, text=True, timeout=300)
                log = r.stdout + r.stderr
                print(f'Flutter policy split={split} build={build} disable_offset={disable_offset} exit={r.returncode}', flush=True)
                for line in log.splitlines():
                    if 'OBSERVED_VERSION:' in line or 'WRONG_VERSION:' in line:
                        print(line, flush=True)
                return r, log
            for split in [False, True]:
                r, log = run(policy, split, 38)
                self.assertEqual(r.returncode, 0, log)
                self.assertIn('VERSION_POLICY_OK', log)
                for brand in ['brand_a', 'brand_b']:
                    self.assertIn(f'OBSERVED_VERSION: {brand}Release: 1000038', log)
            # Restore the exact old bug: actual Flutter legacy ABI override wins.
            r, log = run(policy, True, 38, disable_offset=False)
            self.assertNotEqual(r.returncode, 0, log)
            self.assertIn('WRONG_VERSION', log)
            for brand in ['brand_a', 'brand_b']:
                self.assertIn(f'OBSERVED_VERSION: {brand}Release:', log)
            # Removing our migration policy must fail even with the Flutter switch.
            r, log = run('', True, 38)
            self.assertNotEqual(r.returncode, 0, log)
            self.assertIn('WRONG_VERSION', log)
            for build in [0, 2099000001]:
                r, log = run(policy, False, build)
                self.assertNotEqual(r.returncode, 0, log)
                self.assertIn('should be a positive integer' if build == 0 else 'exceeds the Android installer', log)
            r, log = run(policy, True, 2099000000)
            self.assertEqual(r.returncode, 0, log)


if __name__ == '__main__':
    unittest.main()
