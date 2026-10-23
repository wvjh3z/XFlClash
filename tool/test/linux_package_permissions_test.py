"""Real DEB maker under restrictive umask; no client compilation or installation."""
from pathlib import Path
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tool'))
from distributor_graph import resolved_packages, PREPARED

@unittest.skipUnless(sys.platform=='linux' and shutil.which('dpkg-deb'),'Linux dpkg-deb required')
class LinuxPackagePermissionsTests(unittest.TestCase):
    def test_real_deb_both_brands_umask077_and_old_negative(self):
        graph=resolved_packages()
        dart=Path(os.environ['FLUTTER_ROOT'])/'bin/cache/dart-sdk/bin/dart'
        with tempfile.TemporaryDirectory(prefix='deb-permissions-') as temporary:
            root=Path(temporary)
            probe=root/'make.dart'
            probe.write_text("import 'dart:io';\nimport 'package:flutter_app_packager/src/makers/deb/app_package_maker_deb.dart';\n"
                "import 'package:shell_executor/shell_executor.dart';\nimport 'package:flutter_distributor/src/utils/default_shell_executor.dart';\n"
                "Future<void> main() async { ShellExecutor.global=DefaultShellExecutor(); final maker=AppPackageMakerDeb(); "
                "final config=maker.configLoader.load({'arch':'x64','build_mode':'release'},Directory('dist'),"
                "buildOutputDirectory:Directory('bundle'),buildOutputFiles:[]); await maker.make(config); }\n",encoding='utf-8')
            old=root/'old-packager';shutil.copytree(PREPARED/'flutter_app_packager',old)
            source=old/'lib/src/makers/deb/app_package_maker_deb.dart'
            text=source.read_text(encoding='utf-8')
            self.assertIn('await normalizeLinuxStagingPermissions(packagingDirectory);',text)
            source.write_text(text.replace('    await normalizeLinuxStagingPermissions(packagingDirectory);\n',''),encoding='utf-8')
            for brand,name in [('brand_a','OmoFly'),('brand_b','袋鼠加速')]:
                for legacy in (False,True):
                    with self.subTest(brand=brand,legacy=legacy):
                        case=root/(brand+str(legacy));(case/'bundle/data').mkdir(parents=True)
                        (case/'bundle/data/file').write_text('public fixture',encoding='utf-8')
                        (case/'bundle/data/file').chmod(0o600)
                        (case/'bundle/FixtureApp').write_text('#!/bin/sh\nexit 0\n',encoding='utf-8');(case/'bundle/FixtureApp').chmod(0o700)
                        (case/'bundle').chmod(0o700);(case/'bundle/data').chmod(0o700)
                        private=case/'outside';private.write_text('not packaged',encoding='utf-8');private.chmod(0o600)
                        (case/'bundle/link').symlink_to(private)
                        (case/'linux/packaging/deb').mkdir(parents=True)
                        config={'display_name':name,'package_name':brand.replace('_','-'),
                            'maintainer':{'name':'Fixture','email':'fixture@example.test'},
                            'installed_size':1,'icon':None,'dependencies':['libc6'],'priority':'optional',
                            'section':'x11','essential':False,'startup_notify':True}
                        (case/'linux/packaging/deb/make_config.yaml').write_text(json.dumps(config),encoding='utf-8')
                        (case/'linux/CMakeLists.txt').write_text('set(BINARY_NAME "FixtureApp")\n',encoding='utf-8')
                        (case/'pubspec.yaml').write_text('name: public_fixture\nversion: 1.2.3+1\ndescription: Public fixture\n',encoding='utf-8')
                        packages={k:dict(v) for k,v in graph.items()}
                        if legacy:packages['flutter_app_packager']['rootUri']=old.as_uri()
                        package_config=case/'packages.json';package_config.write_text(json.dumps({'configVersion':2,'packages':list(packages.values())}),encoding='utf-8')
                        result=subprocess.run([str(dart),'--packages='+str(package_config),str(probe)],cwd=case,umask=0o077,capture_output=True,text=True,encoding='utf-8',timeout=60)
                        if legacy:
                            self.assertNotEqual(result.returncode,0);self.assertIn('bad permissions',result.stdout+result.stderr)
                        else:
                            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                            package=next((case/'dist').glob('*.deb'))
                            data=subprocess.check_output(['dpkg-deb','--fsys-tarfile',str(package)])
                            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                                entries={m.name.removeprefix('./'):m for m in archive.getmembers()}
                                self.assertEqual(entries['usr/share/FixtureApp/FixtureApp'].mode,0o755)
                                self.assertEqual(entries['usr/share/FixtureApp/data/file'].mode,0o644)
                                self.assertTrue(all(m.mode==0o755 for m in entries.values() if m.isdir()))
                        self.assertEqual(private.stat().st_mode&0o777,0o600)
                        self.assertEqual((case/'bundle/data/file').stat().st_mode&0o777,0o600)
                        self.assertEqual((case/'bundle').stat().st_mode&0o777,0o700)

if __name__=='__main__':unittest.main()
