import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_golden_font import CONFIG, prepare


class GoldenFontPreparationTests(unittest.TestCase):
    def test_verified_copy_and_cached_reuse_need_no_download(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root/'source.ttc'
            source.write_bytes(b'synthetic font fixture')
            config = {'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}
            target = root/'isolated/font.ttc'
            self.assertFalse(prepare(target, config, source)['cached'])
            source.unlink()
            self.assertTrue(prepare(target, config)['cached'])

    def test_bad_source_and_bad_cache_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root/'source.ttc'
            source.write_bytes(b'wrong')
            target = root/'font.ttc'
            config = {'sha256': hashlib.sha256(b'expected').hexdigest()}
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                prepare(target, config, source)
            self.assertFalse(target.exists())
            target.write_bytes(b'wrong cached data')
            with self.assertRaisesRegex(ValueError, 'digest mismatch'):
                prepare(target, config)
            self.assertEqual(target.read_bytes(), b'wrong cached data')

    def test_ci_flutter_version_matches_the_golden_contract(self):
        config = json.loads(CONFIG.read_text())
        workflow = (CONFIG.parents[3]/'.github/workflows/xboard-ci.yml').read_text()
        self.assertIn('flutter-version: '+config['runtime']['frameworkVersion'], workflow)
        self.assertIn('tool/prepare_golden_font.py', workflow)
        self.assertIn('XB_GOLDEN_CJK_FONT=', workflow)


if __name__ == '__main__':
    unittest.main()
