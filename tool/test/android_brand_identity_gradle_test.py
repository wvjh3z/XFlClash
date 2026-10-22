#!/usr/bin/env python3
"""Real prepare_flavor CLI -> Gradle Kotlin DSL identity regression.

Runs isolated Gradle identity checks and actual AGP resource generation;
does not compile Flutter, native code or an APK.
Needs prepared Dart packages and Java 17. Prepares checksum-pinned Gradle matching the tracked wrapper
in a private fixture; public inputs only, never reads real flavor secrets.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from urllib.parse import urljoin, urlparse, unquote

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))
from pub_get_retry import execute
from prepare_test_gradle import prepare, VERSION
sys.path.insert(0, str(Path(__file__).parent))
from windows_title_encoding_test import dart_executable


def run(command, cwd, timeout=180, environment=None):
    lines = []
    code, _ = execute(list(map(str, command)), cwd, environment or os.environ, attempts=1,
                      attempt_timeout=timeout, total_timeout=timeout, emit=lines.append)
    if code:
        raise AssertionError('\n'.join(lines))
    return '\n'.join(lines)


def block(source, name):
    start = re.search(r'\b' + re.escape(name) + r'\s*\{', source).start()
    # This DSL block contains only braces, plain quoted keys and identifiers.
    tokens = re.finditer(r'"(?:\\.|[^"\\])*"|[{}]', source[start:])
    depth = 0
    for match in tokens:
        if match[0] == '{':
            depth += 1
        elif match[0] == '}':
            depth -= 1
            if depth == 0:
                return source[start:start + match.end()]
    raise AssertionError('Unclosed flavor DSL')


def check_gradle_identity(project, root):
    # Same default in CI and locally; never rely on an ignored wrapper or a
    # manually installed distribution. Always start with an empty user cache.
    gradle = prepare(root / 'verified-gradle')
    environment = {**os.environ, 'GRADLE_USER_HOME': str(root / 'empty-gradle-home')}
    version = run([gradle, '--version'], project, environment=environment)
    if not re.search(r'(?m)^(?:\[pub-get output\]\s*)?Gradle ' + re.escape(VERSION) + r'\s*$', version):
        raise RuntimeError('Unexpected Gradle version')
    return run([gradle, '--offline', '--no-daemon', '--console=plain',
                '-p', project, 'checkBrandIdentity'], project,
               timeout=240, environment=environment)


class AndroidIdentityGradleTests(unittest.TestCase):
    def test_java8_plugin_with_upstream_java17_tasks_needs_early_dsl(self):
        settings = (ROOT / 'android/settings.gradle.kts').read_text()
        agp = re.search(r'id\("com.android.application"\) version "([^"]+)"', settings)[1]
        helper = (ROOT / 'tool/gradle/android_plugin_compat.gradle').read_text()
        early = helper.split('// XBOARD_ANDROID_JVM_DSL_BEGIN\n')[1].split('// XBOARD_ANDROID_JVM_DSL_END')[0]
        with tempfile.TemporaryDirectory(prefix='android-jvm-dsl-') as temporary:
            root = Path(temporary)
            gradle = prepare(root / 'verified-gradle')
            project = root / 'project'; project.mkdir()
            base_settings = ('pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\n'
                             'rootProject.name = "java8-plugin"\n')
            (project / 'settings.gradle').write_text(base_settings)
            (project / 'early.gradle').write_text(early)
            (project / 'gradle.properties').write_text('android.builtInKotlin=false\nandroid.newDsl=false\n')
            (project / 'build.gradle').write_text(f'''plugins {{ id 'com.android.library' version '{agp}' }}
android {{
 namespace 'com.example.java8'
 compileSdk 36
 defaultConfig {{ minSdk 24 }}
 compileOptions {{ sourceCompatibility JavaVersion.VERSION_1_8; targetCompatibility JavaVersion.VERSION_1_8 }}
}}
gradle.projectsEvaluated {{
 tasks.withType(JavaCompile).configureEach {{ sourceCompatibility = '17'; targetCompatibility = '17' }}
}}
''')
            java = project / 'src/main/java/com/example/java8/Probe.java'
            java.parent.mkdir(parents=True)
            java.write_text('package com.example.java8; public class Probe { public void log() { android.util.Log.i("test", "ok"); } }')
            command = [gradle, '--no-daemon', '--console=plain', '-p', project, 'compileReleaseJavaWithJavac']
            with self.assertRaisesRegex(AssertionError, 'package android.util does not exist'):
                run(command, project, timeout=300)
            (project / 'settings.gradle').write_text(base_settings + 'apply from: "early.gradle"\n')
            run(command, project, timeout=180)
            classes = list((project / 'build').rglob('Probe.class'))
            self.assertEqual(len(classes), 1)
            self.assertEqual(int.from_bytes(classes[0].read_bytes()[6:8], 'big'), 61)

    def test_locked_tutorial_plugin_overlay_with_actual_agp(self):
        config = ROOT / '.dart_tool/package_config.json'
        package = next(p for p in json.loads(config.read_text())['packages']
                       if p['name'] == 'flutter_inappwebview_android')
        uri = urljoin(config.as_uri(), package['rootUri'])
        self.assertEqual(urlparse(uri).scheme, 'file')
        plugin = Path(unquote(urlparse(uri).path)) / 'android'
        source_hash = hashlib.sha256((plugin / 'build.gradle').read_bytes()).hexdigest()
        source = (ROOT / 'android/settings.gradle.kts').read_text()
        agp = re.search(r'id\("com.android.application"\) version "([^"]+)"', source)[1]
        with tempfile.TemporaryDirectory(prefix='android-webview-') as temporary:
            root = Path(temporary)
            gradle = prepare(root / 'verified-gradle')
            project = root / 'android'; project.mkdir()
            original = root / 'public-plugin'
            shutil.copytree(plugin, original, ignore=shutil.ignore_patterns('build', '.gradle'))
            helper = root / 'tool/gradle/android_plugin_compat.gradle'
            helper.parent.mkdir(parents=True)
            shutil.copyfile(ROOT / 'tool/gradle/android_plugin_compat.gradle', helper)
            settings = '''pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
rootProject.name = "tutorial-agp-regression"
include(":flutter_inappwebview_android")
project(":flutter_inappwebview_android").projectDir = file("../public-plugin")
'''
            entry = 'apply(from = file("../tool/gradle/android_plugin_compat.gradle"))\n'
            self.assertIn(entry.strip(), source)
            (project / 'settings.gradle.kts').write_text(settings + entry)
            (project / 'build.gradle.kts').write_text(
                f'plugins {{ id("com.android.library") version "{agp}" apply false }}\n')
            (project / 'gradle.properties').write_text('android.builtInKotlin=false\nandroid.newDsl=false\n')
            command = [gradle, '--no-daemon', '--console=plain', '-p', project, 'help']
            run(command, project, timeout=300)
            staged = root / '.dart_tool/xboard/android-plugins/flutter_inappwebview_android-1.1.3/android'
            self.assertEqual((staged / 'build.gradle').read_text().count("getDefaultProguardFile('proguard-android-optimize.txt')"), 2)
            timestamp = (staged / 'build.gradle').stat().st_mtime_ns
            (staged / 'proguard-rules.pro').unlink()
            (staged / 'stale.txt').write_text('stale')
            run(command, project, timeout=180)
            self.assertEqual((staged / 'build.gradle').stat().st_mtime_ns, timestamp)
            self.assertEqual((staged / 'proguard-rules.pro').read_bytes(), (original / 'proguard-rules.pro').read_bytes())
            self.assertFalse((staged / 'stale.txt').exists())
            self.assertEqual(hashlib.sha256((original / 'build.gradle').read_bytes()).hexdigest(), source_hash)
            self.assertEqual(hashlib.sha256((plugin / 'build.gradle').read_bytes()).hexdigest(), source_hash)
            (project / 'settings.gradle.kts').write_text(settings)
            with self.assertRaisesRegex(AssertionError, 'proguard-android.txt.*no longer supported'):
                run(command, project, timeout=180)
            (project / 'settings.gradle.kts').write_text(settings + entry)
            with (original / 'build.gradle').open('a') as stream:
                stream.write('\n// changed upstream input\n')
            with self.assertRaisesRegex(AssertionError, 'plugin build input changed'):
                run(command, project, timeout=180)

    def test_actual_agp_generates_both_brand_names_and_rejects_disabled_feature(self):
        source = (ROOT / 'android/app/build.gradle.kts').read_text(encoding='utf-8')
        features = block(source, 'buildFeatures')
        flavors = block(source, 'productFlavors')
        settings = (ROOT / 'android/settings.gradle.kts').read_text(encoding='utf-8')
        agp = re.search(r'id\("com.android.application"\) version "([^"]+)"', settings)[1]
        versions = (ROOT / 'android/gradle/libs.versions.toml').read_text(encoding='utf-8')
        sdk = re.search(r'compileSdk = "(\d+)"', versions)[1]
        with tempfile.TemporaryDirectory(prefix='android-resvalues-') as temporary:
            root = Path(temporary)
            gradle = prepare(root / 'verified-gradle')
            project = root / 'project'; project.mkdir()
            (project / 'settings.gradle.kts').write_text(
                'pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }\n'
                'dependencyResolutionManagement { repositories { google(); mavenCentral() } }\n'
                'rootProject.name = "brand-resource-regression"\n', encoding='utf-8')
            (project / 'gradle.properties').write_text(
                'android.builtInKotlin=false\nandroid.newDsl=false\n', encoding='utf-8')
            script = f'''plugins {{ id("com.android.application") version "{agp}" }}
fun androidBrandIdentity(flavor: String): Map<String, String> = mapOf(
    "appName" to if (flavor == "brand_a") "OmoFly" else "袋鼠加速",
    "appId" to "com.example.$flavor")
android {{
    namespace = "com.example.regression"
    compileSdk = {sdk}
    defaultConfig {{ minSdk = 24 }}
    {features}
    flavorDimensions += "brand"
    {flavors}
}}
'''
            build = project / 'build.gradle.kts'
            build.write_text(script, encoding='utf-8')
            command = [gradle, '--no-daemon', '--console=plain', '-p', project,
                       'generateBrand_aReleaseResValues', 'generateBrand_bReleaseResValues']
            run(command, project, timeout=300)
            for brand, name in [('brand_a', 'OmoFly'), ('brand_b', '袋鼠加速')]:
                files = list((project / 'build/generated/res/resValues' / (brand + '/release')).rglob('*.xml'))
                self.assertEqual(len(files), 1)
                values = {e.attrib.get('name'): e.text for e in ET.parse(files[0]).getroot()}
                self.assertEqual(values['app_name'], name)
            # Run the real AGP failure rather than simulating its default.
            for broken in (features.replace('true', 'false'), ''):
                build.write_text(script.replace(features, broken), encoding='utf-8')
                with self.assertRaisesRegex(AssertionError, 'custom resource values, but the feature is disabled'):
                    run(command, project, timeout=180)

    def test_real_prepare_cli_and_actual_gradle_identity_and_flavor_dsl(self):
        with tempfile.TemporaryDirectory(prefix='android-brand-') as temporary:
            root = Path(temporary)
            cases = root / 'cases'
            source = (ROOT / 'android/app/build.gradle.kts').read_text(encoding='utf-8')
            helper = source.split('// XBOARD_ANDROID_IDENTITY_BEGIN\n', 1)[1].split('// XBOARD_ANDROID_IDENTITY_END', 1)[0]
            flavors = block(source, 'productFlavors')
            names = {'brand_a': 'OmoFly', 'brand_b': '袋鼠加速'}
            manifest = []
            for style in ('plain', 'double', 'single', 'unicode', 'apostrophe', 'supplementary'):
                for newline in ('\n', '\r\n'):
                    case = cases / (style + str(len(newline)))
                    case.mkdir(parents=True)
                    (case / 'pubspec.yaml').write_bytes((ROOT / 'pubspec.yaml').read_bytes())
                    expected = {}
                    for brand, name in names.items():
                        if style == 'apostrophe':
                            name = "袋鼠's # Client" if brand == 'brand_b' else "OmoFly's # Client"
                        elif style == 'supplementary':
                            name += ' 🦘'
                        value = name
                        if style in ('double', 'supplementary'):
                            value = json.dumps(name, ensure_ascii=False)
                        elif style in ('single', 'apostrophe'):
                            value = "'" + name.replace("'", "''") + "'"
                        elif style == 'unicode':
                            value = json.dumps(name, ensure_ascii=True)
                            if brand == 'brand_a': value = r'"\u004FmoFly"'
                        expected[brand] = {'appName': name, 'appId': 'com.example.' + brand}
                        folder = case / 'flavors' / brand
                        (folder / 'assets/icons').mkdir(parents=True)
                        (folder / f'assets/icons/{brand}.png').write_bytes(b'public-icon')
                        (folder / 'assets/fallback.bin').write_bytes(b'public-fallback')
                        text = f'''appName: {value}
appId: 'com.example.{brand}'
versionName: "0.0.1"
brandColor: "#d92e1a"
aesKey: ""
bootstrapUrls: ["https://a.example.com", "https://b.example.com", "https://c.example.com"]
fallbackEnvelope: "assets/fallback.bin"
subscribeUserAgent: "test/flclash"
termsUrl: "https://example.com/terms"
privacyUrl: "https://example.com/privacy"
dataResidency: "test"
dataController: "test"
supportEmail: "test@example.com"
sentryDsn: "PRIVATE_FIXTURE_SENTINEL"
'''
                        (folder / 'flavor.yaml').write_bytes(text.replace('\n', newline).encode('utf-8'))
                    for selected in names:
                        run([dart_executable(), '--packages=' + str(ROOT / '.dart_tool/package_config.json'),
                             ROOT / 'tool/prepare_flavor.dart', '--flavor', selected, '--target', 'test', '--android-identity'], case)
                        generated = case / '.dart_tool/xboard/android_brand_identity.json'
                        public = json.loads(generated.read_text(encoding='utf-8'))
                        self.assertNotIn('PRIVATE_FIXTURE_SENTINEL', generated.read_text())
                        self.assertEqual(set(public), {'schemaVersion', 'brands'})
                        defines = json.loads((case / 'flavor_defines.json').read_text(encoding='utf-8'))
                        self.assertEqual(defines['XB_APP_NAME'], expected[selected]['appName'])
                        for brand in names:
                            identity = public['brands'][brand]
                            self.assertEqual(set(identity), {'appName', 'appId', 'sourceSha256'})
                            self.assertEqual(identity['sourceSha256'], hashlib.sha256((case / 'flavors' / brand / 'flavor.yaml').read_bytes()).hexdigest())
                    manifest.append({'path': case.as_posix(), 'expected': expected})
            # Desktop prepare must not read an unrelated, invalid brand identity.
            desktop = cases / 'plain1'
            generated = desktop / '.dart_tool/xboard/android_brand_identity.json'
            original = generated.read_bytes()
            other = desktop / 'flavors/brand_b/flavor.yaml'
            previous = other.read_bytes()
            other.write_text('appName: 123\n', encoding='utf-8')
            run([dart_executable(), '--packages=' + str(ROOT / '.dart_tool/package_config.json'),
                 ROOT / 'tool/prepare_flavor.dart', '--flavor', 'brand_a', '--target', 'test'], desktop)
            self.assertEqual(generated.read_bytes(), original)
            other.write_bytes(previous)
            (root / 'cases.json').write_text(json.dumps(manifest), encoding='utf-8')
            project = root / 'android'; project.mkdir()
            (project / 'settings.gradle.kts').write_text('rootProject.name = "brand-identity-test"\n')
            script = '''import groovy.json.JsonSlurper
import groovy.json.JsonOutput
import java.security.MessageDigest
''' + helper + '''
class Flavor {
 var dimension = ""; var applicationId = ""; val manifestPlaceholders = mutableMapOf<String, Any>()
 val resValues = mutableMapOf<Pair<String,String>,String>()
 fun resValue(type: String, name: String, value: String) { resValues[type to name] = value }
}
class Flavors {
 val values = mutableMapOf<String, Flavor>()
 fun create(name: String, body: Flavor.() -> Unit) { values[name] = Flavor().apply(body) }
}
fun productFlavors(body: Flavors.() -> Unit): Flavors = Flavors().apply(body)
fun configureActualFlavors(): Flavors = ''' + flavors + '''

tasks.register("checkBrandIdentity") {
 doLast {
  val root = rootProject.projectDir.parentFile
  val input = JsonSlurper().parse(File(root,"cases.json"), "UTF-8") as List<*>
  val generated = File(root,".dart_tool/xboard/android_brand_identity.json")
  fun rejected(action: () -> Unit) {
   var failed = false
   try { action() } catch(e: GradleException) {
    check(!e.message.orEmpty().contains("PRIVATE_FIXTURE_SENTINEL")); failed = true
   }
   check(failed) { "Invalid/stale identity was accepted" }
  }
  for (item in input) {
   val case = item as Map<*, *>
   val folder = File(case["path"] as String)
   File(folder,"flavors").copyRecursively(File(root,"flavors"), overwrite=true)
   generated.parentFile.mkdirs()
   File(folder,".dart_tool/xboard/android_brand_identity.json").copyTo(generated, overwrite=true)
   val good = generated.readBytes()
   val expected = case["expected"] as Map<*, *>
   val configured = configureActualFlavors().values
   for (brand in listOf("brand_a", "brand_b")) {
    val identity = androidBrandIdentity(brand)!!
    val want = expected[brand] as Map<*, *>
    check(identity["appName"] == want["appName"])
    check(identity["appId"] == want["appId"])
    check(configured[brand]!!.applicationId == want["appId"])
    check(configured[brand]!!.manifestPlaceholders["appName"] == want["appName"])
    check(configured[brand]!!.resValues["string" to "app_name"] == want["appName"])
    val yaml = File(root,"flavors/$brand/flavor.yaml")
    val original = yaml.readBytes()
    yaml.appendText("\\n# changed source\\n", Charsets.UTF_8)
    rejected { androidBrandIdentity(brand) }; yaml.writeBytes(original)
    generated.delete(); rejected { androidBrandIdentity(brand) }; generated.writeBytes(good)
    generated.writeText("invalid PRIVATE_FIXTURE_SENTINEL", Charsets.UTF_8)
    rejected { androidBrandIdentity(brand) }; generated.writeBytes(good)
    for (field in listOf("appName", "appId", "sourceSha256")) {
     val data = JsonSlurper().parseText(generated.readText(Charsets.UTF_8)) as MutableMap<String, Any>
     val all = data["brands"] as MutableMap<String, MutableMap<String, Any>>
     all[brand]!!.remove(field)
     generated.writeText(JsonOutput.toJson(data), Charsets.UTF_8)
     rejected { androidBrandIdentity(brand) }; generated.writeBytes(good)
    }
    yaml.delete(); check(androidBrandIdentity(brand) == null)
    val unconfigured = configureActualFlavors().values[brand]!!
    check(unconfigured.applicationId == "com.follow.clash")
    check(unconfigured.manifestPlaceholders["appName"] == "FlClash")
    check(unconfigured.resValues["string" to "app_name"] == "FlClash")
    yaml.writeBytes(original)
   }
  }
  println("ANDROID_BRAND_IDENTITY_OK cases=" + input.size)
 }
}
'''
            (project / 'build.gradle.kts').write_text(script, encoding='utf-8')
            result = check_gradle_identity(project, root)
            self.assertIn('ANDROID_BRAND_IDENTITY_OK cases=12', result)


if __name__ == '__main__':
    unittest.main(verbosity=2)
