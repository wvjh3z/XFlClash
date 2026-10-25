"""Real injection CLI across platforms/brands; no app build or private config."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tool'))
from verify_brand_identity import verify
from distributor_graph import PACKAGES
from generate_brand_identity import rendered

class CatalogTests(unittest.TestCase):
    def test_generated_catalog_and_independent_identities(self):
        self.assertEqual((ROOT/'tool/identity/brands.dart').read_text(encoding='utf-8'),rendered())
        identities=json.loads((ROOT/'tool/identity/brands.json').read_text(encoding='utf-8'))
        a,b=identities.values()
        for key in a:self.assertNotEqual(a[key],b[key],key)
        self.assertEqual(a['id'],'com.cloud.app.omofly')
        self.assertEqual(b['id'],'com.cloud.app.daishu')
        # Neither brand may claim upstream's machine-wide identifiers.
        for identity in (a,b):
            self.assertNotEqual(identity['id'],'com.follow.clash')
            self.assertNotEqual(identity['name'],'FlClash')
            self.assertNotEqual(identity['linuxService'],'flclash-helper')
            self.assertNotEqual(identity['windowsService'],'FlClashHelperService')
            self.assertNotEqual(identity['runtimeDirectory'],'flclash')

class IdentityCliTests(unittest.TestCase):
    def test_real_cli_windows_linux_mac_both_brands_and_missing_inputs(self):
        dart=Path(os.environ['FLUTTER_ROOT'])/('bin/cache/dart-sdk/bin/dart.exe' if os.name=='nt' else 'bin/cache/dart-sdk/bin/dart')
        with tempfile.TemporaryDirectory(prefix='brand-injection-') as tmp:
            root=Path(tmp)
            paths=['build_config.yaml','windows/CMakeLists.txt','windows/runner/main.cpp','windows/runner/Runner.rc',
                'linux/CMakeLists.txt','linux/runner/my_application.cc','macos/Runner/Configs/AppInfo.xcconfig',
                'macos/Runner/Info.plist','macos/Runner.xcodeproj/project.pbxproj','macos/packaging/dmg/make_config.yaml',
                'linux/packaging/appimage/make_config.yaml','linux/packaging/rpm/make_config.yaml',
                'linux/packaging/deb/make_config.yaml','windows/packaging/exe/make_config.yaml',
                'windows/packaging/exe/inno_setup.iss','services/helper/src/service/windows.rs',
                'services/helper/src/service/linux.rs','services/helper/src/service/peer.rs','tool/identity/brands.json']
            for name in paths:
                dest=root/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,dest)
            for brand,name in [('brand_a','OmoFly'),('brand_b','袋鼠加速')]:
                shutil.copytree(ROOT/'flavors'/brand,root/'flavors'/brand,ignore=shutil.ignore_patterns('flavor.yaml','*.jks','fallback.bin'))
                (root/'flavors'/brand/'flavor.yaml').write_text('appName: '+json.dumps(name)+'\nversionName: 0.0.1\n',encoding='utf-8')
            (root/'assets/images').mkdir(parents=True)
            for platform in ('windows','linux','macos','windows'):
                for brand in ('brand_a','brand_b','brand_a'):
                    result=subprocess.run([str(dart),'--packages='+str(PACKAGES),str(ROOT/'tool/inject_desktop_brand.dart'),
                        '--flavor',brand,'--platform',platform,'--build-number','26'],cwd=root,capture_output=True,text=True,encoding='utf-8',timeout=60)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    id=json.loads((ROOT/'tool/identity/brands.json').read_text(encoding='utf-8'))[brand]
                    (root/'env.json').write_text(json.dumps({'XB_NATIVE_ID':id['id'],'XB_NATIVE_NAME':id['name'],
                        'XB_HELPER_WINDOWS_SERVICE':id['windowsService'],'XB_HELPER_SOCKET':'/run/'+id['runtimeDirectory']+'/helper.sock',
                        'XB_URL_SCHEME':id['scheme'],'XB_DEFAULT_MIXED_PORT':str(id['mixedPort']),
                        'XB_WINDOWS_CORE_NAME':id['name']+'Core','XB_WINDOWS_HELPER_NAME':id['name']+'HelperService'}), encoding='utf-8')
                    verify(root,brand,platform)
                    for name, expected, wrong in [
                        ('linux/packaging/deb/make_config.yaml', '/usr/share/'+id['slug']+'/', '/usr/share/FlClash/'),
                        ('linux/packaging/rpm/make_config.yaml', 'unit=/etc/systemd/system/'+id['linuxService']+'.service', 'unit=/etc/systemd/system/flclash-helper.service'),
                        ('macos/Runner/Info.plist', '<string>'+id['scheme']+'</string>', '<string>flclash</string>'),
                    ]:
                        path=root/name;original=path.read_text(encoding='utf-8')
                        self.assertIn(expected,original)
                        path.write_text(original.replace(expected,wrong),encoding='utf-8')
                        try:
                            with self.assertRaises(ValueError):verify(root,brand,platform)
                        finally:path.write_text(original,encoding='utf-8')
                    self.assertIn('package_name: "'+id['slug']+'"',(root/'linux/packaging/deb/make_config.yaml').read_text(encoding='utf-8'))
                    self.assertNotIn('x-scheme-handler/clash\n',(root/'linux/packaging/rpm/make_config.yaml').read_text(encoding='utf-8'))
            peer=root/'services/helper/src/service/peer.rs';peer.write_text(peer.read_text(encoding='utf-8').replace('OmoFlyHelperService','FlClashHelperService'), encoding='utf-8')
            with self.assertRaises(ValueError):verify(root,'brand_a','windows')

if __name__=='__main__':unittest.main()
