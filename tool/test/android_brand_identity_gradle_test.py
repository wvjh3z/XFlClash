#!/usr/bin/env python3
"""Real prepare_flavor CLI -> Gradle Kotlin DSL identity regression.

Runs only an isolated Gradle check task, without AGP or Android compilation.
Needs prepared Dart packages and Gradle 8.13 (XFLCLASH_TEST_GRADLE override or
repository wrapper). Public fixtures only; never reads real flavor secrets.
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

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))
from pub_get_retry import execute
sys.path.insert(0, str(Path(__file__).parent))
from windows_title_encoding_test import dart_executable


def run(command, cwd, timeout=180):
    lines = []
    code, _ = execute(list(map(str, command)), cwd, os.environ, attempts=1,
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


class AndroidIdentityGradleTests(unittest.TestCase):
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
class Flavor { var dimension = ""; var applicationId = ""; val manifestPlaceholders = mutableMapOf<String, Any>() }
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
    yaml.writeBytes(original)
   }
  }
  println("ANDROID_BRAND_IDENTITY_OK cases=" + input.size)
 }
}
'''
            (project / 'build.gradle.kts').write_text(script, encoding='utf-8')
            gradle = os.environ.get('XFLCLASH_TEST_GRADLE')
            if gradle:
                command = [gradle]
            elif os.name == 'nt':
                raise RuntimeError('Set XFLCLASH_TEST_GRADLE to a native Gradle launcher on Windows')
            else:
                command = ['bash', str(ROOT / 'android/gradlew')]
            result = run(command + ['--offline', '--no-daemon', '--console=plain', '-p', project, 'checkBrandIdentity'], project, timeout=240)
            self.assertIn('ANDROID_BRAND_IDENTITY_OK cases=12', result)


if __name__ == '__main__':
    unittest.main(verbosity=2)
