"""Default Gradle provisioning without repository wrapper or warm install."""
import hashlib
import io
import re
from pathlib import Path
import sys
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import prepare_test_gradle as g


def archive(entries=None):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w') as z:
        for name, content in (entries or {'gradle-9.8.0/bin/gradle': 'launcher',
                                          'gradle-9.8.0/bin/gradle.bat': 'launcher'}).items():
            z.writestr(name, content)
    return output.getvalue()


class GradleProvisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='gradle-preflight-中文-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_empty_cache_downloads_verifies_extracts_then_reuses_only_archive(self):
        data = archive()
        calls = []
        def download(path, url, limit):
            calls.append((url, limit)); path.write_bytes(data)
        with patch.object(g, 'SHA256', hashlib.sha256(data).hexdigest()):
            first = g.prepare(self.root/'first', cache=self.root/'cache', download=download)
            first.write_text('tampered extracted launcher')
            second = g.prepare(self.root/'second', cache=self.root/'cache', download=download)
            self.assertEqual(second.read_text(), 'launcher')
            self.assertEqual(len(calls), 1)
            self.assertEqual(calls[0][0], g.URL)
            self.assertFalse((self.root/'android/gradlew').exists())

    def test_bad_cache_is_replaced_only_after_verified_download(self):
        cache = self.root/'cache'; cache.mkdir()
        target = cache/'gradle-9.8.0-bin.zip'; target.write_bytes(b'broken')
        data = archive()
        with patch.object(g, 'SHA256', hashlib.sha256(data).hexdigest()):
            g.prepare(self.root/'out', cache=cache, download=lambda p,*_: p.write_bytes(data))
            self.assertEqual(target.read_bytes(), data)

    def test_hash_mismatch_never_executes_or_publishes_archive(self):
        with self.assertRaisesRegex(RuntimeError, 'SHA256'):
            g.prepare(self.root/'out', cache=self.root/'cache', download=lambda p,*_: p.write_bytes(archive()))
        self.assertFalse((self.root/'out').exists())
        self.assertFalse((self.root/'cache/gradle-9.8.0-bin.zip').exists())

    def test_failed_partial_download_is_cleaned(self):
        def fail(path, *_):
            path.write_bytes(b'partial'); raise RuntimeError('download failed')
        with self.assertRaisesRegex(RuntimeError, 'download failed'):
            g.prepare(self.root/'out', cache=self.root/'cache', download=fail)
        self.assertEqual(list((self.root/'cache').iterdir()), [])

    def test_traversal_archive_is_rejected(self):
        for name in ['../escaped', 'gradle-9.8.0/../../escaped', 'gradle-9.8.0/..\\escaped']:
            data = archive({name: 'bad'})
            with self.subTest(name=name), patch.object(g, 'SHA256', hashlib.sha256(data).hexdigest()):
                with self.assertRaisesRegex(RuntimeError, 'Unsafe'):
                    g.prepare(self.root/'out', cache=self.root/'cache', download=lambda p,*_: p.write_bytes(data))
            self.assertFalse((self.root/'escaped').exists())

    def test_clean_checkout_default_entry_ignores_missing_wrapper_and_installed_override(self):
        from tool.test import android_brand_identity_gradle_test as entry
        data = subprocess.check_output(['git', 'archive', 'HEAD', 'android'], cwd=g.ROOT)
        checkout = self.root/'clean'; checkout.mkdir()
        with tarfile.open(fileobj=io.BytesIO(data)) as bundle:
            bundle.extractall(checkout, filter='data')
        self.assertFalse((checkout/'android/gradlew').exists())
        self.assertFalse((checkout/'android/gradle/wrapper/gradle-wrapper.jar').exists())
        launcher = self.root/'prepared/bin/gradle'
        with patch.dict(g.os.environ, {'XFLCLASH_TEST_GRADLE': '/missing/manual/gradle'}), \
             patch.object(entry, 'prepare', return_value=launcher) as prepare, \
             patch.object(entry, 'run', side_effect=['[pub-get output] Gradle 9.8.0\n', 'OK']) as run:
            self.assertEqual(entry.check_gradle_identity(checkout/'project', checkout), 'OK')
        prepare.assert_called_once_with(checkout/'verified-gradle')
        self.assertEqual(run.call_args.args[0][0], launcher)
        self.assertIn('--offline', run.call_args.args[0])
        self.assertEqual(run.call_args.kwargs['environment']['GRADLE_USER_HOME'], str(checkout/'empty-gradle-home'))
        self.assertFalse((checkout/'empty-gradle-home').exists())

    def test_preflight_pin_matches_tracked_android_gradle_release(self):
        properties = (g.ROOT/'android/gradle/wrapper/gradle-wrapper.properties').read_text()
        match = re.search(r'gradle-([0-9.]+)-(?:all|bin)\.zip', properties)
        self.assertIsNotNone(match)
        self.assertEqual(match[1], g.VERSION)

    def test_wrong_gradle_version_stops_before_task(self):
        from tool.test import android_brand_identity_gradle_test as entry
        with patch.object(entry, 'prepare', return_value=self.root/'gradle'), \
             patch.object(entry, 'run', return_value='Gradle 9.0\n') as run:
            with self.assertRaisesRegex(RuntimeError, 'Unexpected Gradle'):
                entry.check_gradle_identity(self.root, self.root)
        self.assertEqual(run.call_count, 1)


if __name__ == '__main__': unittest.main()
