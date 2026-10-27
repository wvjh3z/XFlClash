"""Static FileProvider contract: narrow roots for both APK download locations.

This checks shipped XML and manifest wiring; it is not an Android device test.
Run: python3 tool/test/android_update_paths_test.py
"""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / "android/app/src/main"
NS = "{http://schemas.android.com/apk/res/android}"


def validate_paths(xml):
    root = ET.fromstring(xml)
    if root.tag != "paths" or root.attrib:
        raise ValueError("Unexpected paths root")
    entries = list(root)
    if len(entries) != 2:
        raise ValueError("Only the two update directories may be shared")
    if {e.tag for e in entries} != {"cache-path", "external-cache-path"}:
        raise ValueError("Both internal and external cache are required")
    names = set()
    for entry in entries:
        if set(entry.attrib) != {"name", "path"} or entry.get("path") != "update/":
            raise ValueError("Only update/ may be shared")
        name = entry.get("name")
        if not name or name in names:
            raise ValueError("Distinct URI root names required")
        names.add(name)


class AndroidUpdatePathsTests(unittest.TestCase):
    def setUp(self):
        self.xml = (ANDROID / "res/xml/update_file_paths.xml").read_text(encoding="utf-8")

    def test_shipped_paths_cover_both_download_roots(self):
        validate_paths(self.xml)

    def test_provider_uses_package_specific_authority_and_this_resource(self):
        manifest = ET.parse(ANDROID / "AndroidManifest.xml")
        providers = [p for p in manifest.findall("application/provider")
                     if p.get(NS + "name") == ".UpdateFileProvider"]
        self.assertEqual(len(providers), 1)
        provider = providers[0]
        self.assertEqual(provider.get(NS + "authorities"), "${applicationId}.update_provider")
        self.assertEqual(provider.get(NS + "exported"), "false")
        self.assertEqual(provider.get(NS + "grantUriPermissions"), "true")
        metadata = {m.get(NS + "name"): m.get(NS + "resource")
                    for m in provider.findall("meta-data")}
        self.assertEqual(metadata["android.support.FILE_PROVIDER_PATHS"], "@xml/update_file_paths")

    def test_old_external_only_configuration_is_rejected(self):
        with self.assertRaises(ValueError):
            validate_paths('<paths><external-cache-path name="update" path="update/" /></paths>')

    def test_broad_roots_and_duplicate_names_are_rejected(self):
        for path in [".", "", "../", "/", "update/../"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                validate_paths(self.xml.replace('path="update/"', f'path="{path}"', 1))
        with self.assertRaises(ValueError):
            validate_paths(self.xml.replace('name="internal_update"', 'name="update"'))
        with self.assertRaises(ValueError):
            validate_paths(self.xml.replace("cache-path name=\"internal_update\"", "root-path name=\"internal_update\""))


if __name__ == "__main__":
    unittest.main()
