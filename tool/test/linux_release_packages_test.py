"""Real DEB/RPM makers, package payloads and uninstall scripts; never install apps."""
from pathlib import Path
import io
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tool'))
from distributor_graph import resolved_packages
from verify_linux_packages import verify, PackageError, cpio_members, verify_members
from prepare_appimagetool import OUTPUT as APPIMAGE_TOOLS


class ArchiveSafetyTests(unittest.TestCase):
    def test_truncated_cpio_and_mutated_native_are_rejected(self):
        with self.assertRaises(PackageError): list(cpio_members(io.BytesIO(b'070701')))
        with self.assertRaisesRegex(PackageError,'bytes_changed'):
            verify_members([('usr/share/app/FlClash',0o100755,b'wrong')],'usr/share/app/',{'FlClash':'0'*64})
        with self.assertRaises(PackageError):
            verify_members([('../FlClash',0o100755,b'x')],'usr/share/app/',{'FlClash':'0'*64})
        with self.assertRaises(PackageError):
            verify_members([('usr/share/app/FlClash',0o120777,b'x')],'usr/share/app/',{'FlClash':'0'*64})
        expected={'FlClash':hashlib.sha256(b'runner').hexdigest()}
        records=[('usr/share/app/FlClash',0o100755,b'runner')]
        launcher=('usr/bin/app','/usr/share/app/FlClash')
        with self.assertRaisesRegex(PackageError,'missing_packaged_launcher'):
            verify_members(records,'usr/share/app/',expected,launcher)
        with self.assertRaisesRegex(PackageError,'invalid_packaged_launcher'):
            verify_members(records+[('usr/bin/app',0o120777,b'/usr/share/app/app')],
                           'usr/share/app/',expected,launcher)


@unittest.skipUnless(sys.platform=='linux','Linux package tools required')
class RealLinuxReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.has_rpm=platform.machine() in ('x86_64','amd64')
        cls.arch='amd64' if cls.has_rpm else 'arm64'
        cls.build_arch='x64' if cls.has_rpm else 'arm64'
        cls.appimagetool=Path(os.environ.get('APPIMAGETOOL_DIRECTORY', str(APPIMAGE_TOOLS)))/'bin/appimagetool'
        if not cls.appimagetool.is_file():raise RuntimeError('Pinned real appimagetool required')
        for tool in ('dpkg-deb','cc','mksquashfs','unsquashfs',*(('rpm','rpm2cpio','rpmbuild') if cls.has_rpm else ())):
            if not shutil.which(tool): raise RuntimeError('Required real package tool missing: '+tool)
        cls.temp=tempfile.TemporaryDirectory(prefix='linux-release-')
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root=Path(cls.temp.name)
        graph=cls.root/'packages.json'
        graph.write_text(json.dumps({'configVersion':2,'packages':list(resolved_packages().values())}), encoding='utf-8')
        cls.dart=Path(os.environ['FLUTTER_ROOT'])/'bin/cache/dart-sdk/bin/dart'
        cls.graph=graph
        cls.probe=cls.root/'make.dart'
        cls.probe.write_text("""import 'dart:io';
import 'package:flutter_app_packager/src/makers/deb/app_package_maker_deb.dart';
import 'package:flutter_app_packager/src/makers/rpm/app_package_maker_rpm.dart';
import 'package:shell_executor/shell_executor.dart';
import 'package:flutter_distributor/src/utils/default_shell_executor.dart';
Future<void> main(List<String> args) async {
 ShellExecutor.global=DefaultShellExecutor();
 final maker=args[0]=='rpm' ? AppPackageMakerRPM() : AppPackageMakerDeb();
 final config=maker.configLoader.load({'arch':args[1],'build_mode':'release'},Directory('dist'),buildOutputDirectory:Directory('build/linux/${args[1]}/release/bundle'),buildOutputFiles:[]);
 await maker.make(config);
}
""", encoding='utf-8')
        source=cls.root/'fixture.c';source.write_text('int main(void) { return 0; }\n', encoding='utf-8')
        cls.elf=cls.root/'runner';subprocess.run(['cc','-g',str(source),'-o',str(cls.elf)],check=True)

    def test_both_brands_real_packages_versions_links_cleanup_and_native_bytes(self):
        old_versions={}
        for brand,app,display in [('brand_a','omofly','OmoFly'),('brand_b','daishu','袋鼠加速')]:
            for number in (26,27):
                with self.subTest(brand=brand,number=number):
                    case=self.root/(brand+str(number));bundle=case/f'build/linux/{self.build_arch}/release/bundle'
                    (bundle/'lib').mkdir(parents=True)
                    for name in ('FlClash','FlClashCore','FlClashHelperService','lib/test.so'):
                        shutil.copyfile(self.elf,bundle/name);(bundle/name).chmod(0o700 if '/' not in name else 0o600)
                    (case/'assets/images').mkdir(parents=True)
                    (case/'assets/images/icon.png').write_bytes(b'public icon')
                    (case/'pubspec.yaml').write_text('name: fl_clash\nversion: 0.9.1+2026101702\ndescription: public fixture\n', encoding='utf-8')
                    (case/'distribute_options.yaml').write_text(f'app_name: {app}\nlinux_package_version: 0.0.1+{number}\n', encoding='utf-8')
                    (case/'linux').mkdir(exist_ok=True)
                    (case/'linux/CMakeLists.txt').write_text('set(BINARY_NAME "FlClash")\n', encoding='utf-8')
                    identity_result=subprocess.run([str(self.dart),'--packages='+str(self.graph),str(ROOT/'tool/test/linux_identity_fixture.dart'),str(ROOT),brand],cwd=case,capture_output=True,text=True)
                    self.assertEqual(identity_result.returncode,0,identity_result.stderr)
                    formats=['deb',*(['rpm'] if self.has_rpm else [])]
                    for kind in formats:
                        result=subprocess.run([str(self.dart),'--packages='+str(self.graph),str(self.probe),kind,self.build_arch],cwd=case,umask=0o077,capture_output=True,text=True,timeout=90)
                        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    context={'arch':self.arch,'product_version':'0.0.1','build_number':number,'package_app_name':app,'targets':formats}
                    self.assertEqual(len(verify(context,case/'dist',case/'build')),len(formats))
                    deb=next((case/'dist').glob('*.deb'))
                    version=subprocess.check_output(['dpkg-deb','-f',str(deb),'Version']).decode().strip()
                    self.assertEqual(version,f'1:0.0.1+{number}')
                    self.assertEqual(subprocess.run(['dpkg','--compare-versions',version,'gt',old_versions.get(brand,'0.9.1+2026101702')]).returncode,0)
                    old_versions[brand]=version
                    with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['dpkg-deb','--ctrl-tarfile',str(deb)]))) as archive:
                        script=archive.extractfile('./postrm').read().decode()
                    self.check_cleanup(case,script,'/usr/share/'+app+'/FlClashHelperService','remove','upgrade')
                    with tarfile.open(fileobj=io.BytesIO(subprocess.check_output(['dpkg-deb','--fsys-tarfile',str(deb)]))) as archive:
                        entry=next(m for m in archive if m.name.endswith('.desktop'))
                        text=archive.extractfile(entry).read().decode()
                    self.assertIn('StartupWMClass=com.cloud.app.'+app,text)
                    self.assertIn('x-scheme-handler/com.cloud.app.'+app,text)
                    if self.has_rpm:
                        rpm=next((case/'dist').glob('*.rpm'))
                        meta=subprocess.check_output(['rpm','-qp','--qf','%{EPOCH}:%{VERSION}-%{RELEASE}',str(rpm)]).decode()
                        self.assertEqual(meta,f'1:0.0.1-{number}')
                        payload=subprocess.check_output(['rpm2cpio',str(rpm)])
                        entries={n:(m,d) for n,m,d in cpio_members(io.BytesIO(payload))}
                        self.assertEqual(entries['usr/bin/'+app][1].decode(),'/usr/share/'+app+'/FlClash')
                        self.assertIn('usr/share/'+app+'/FlClash',entries)
                        post=subprocess.check_output(['rpm','-qp','--qf','%{POSTUN}',str(rpm)]).decode()
                        self.check_cleanup(case,post,'/usr/share/'+app+'/FlClashHelperService','0','1')
                    if self.has_rpm and number == 26:
                        # Real rpmbuild negative: enable an actual strip postprocessor.
                        config_path=case/'linux/packaging/rpm/make_config.yaml'
                        original=config_path.read_text(encoding='utf-8')
                        config_path.write_text(original.replace('%global __os_install_post %{nil}',
                            '%global __os_install_post /usr/bin/strip --strip-debug %{buildroot}%{_datadir}/%{name}/FlClashCore'), encoding='utf-8')
                        result=subprocess.run([str(self.dart),'--packages='+str(self.graph),str(self.probe),'rpm',self.build_arch],cwd=case,capture_output=True,text=True,timeout=90)
                        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                        with self.assertRaisesRegex(PackageError,'bytes_changed'):
                            verify(context,case/'dist',case/'build')
                        config_path.write_text(original, encoding='utf-8')
                        result=subprocess.run([str(self.dart),'--packages='+str(self.graph),str(self.probe),'rpm',self.build_arch],cwd=case,capture_output=True,text=True,timeout=90)
                        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    # Existing success evidence cannot mask a repackaged/changed native binary.
                    (bundle/'FlClashCore').write_bytes(b'\x7fELFchanged')
                    with self.assertRaisesRegex(PackageError,'bytes_changed'):
                        verify(context,case/'dist',case/'build')
                    # Legacy fixed version is rejected independently of byte comparisons.
                    shutil.copyfile(self.elf,bundle/'FlClashCore')
                    wrong={**context,'build_number':number+1}
                    with self.assertRaisesRegex(PackageError,'version_mismatch'):
                        verify(wrong,case/'dist',case/'build')
                    # Execute the formal CLI entry, including normalized names and fail-closed evidence.
                    # Use the real pinned type-2 writer: raw SquashFS is not an AppImage.
                    appdir=case/'public.AppDir';shutil.copytree(bundle,appdir)
                    (appdir/'AppRun').symlink_to('FlClash')
                    (appdir/'fixture.desktop').write_text('[Desktop Entry]\nType=Application\nName=Fixture\nExec=AppRun\nIcon=fixture\nCategories=Utility;\n',encoding='utf-8')
                    (appdir/'fixture.svg').write_text('<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16"/></svg>',encoding='utf-8')
                    image=case/'dist/fixture.AppImage'
                    env={k:v for k,v in os.environ.items() if k not in ('APPIMAGE','APPDIR','VERSION','SOURCE_DATE_EPOCH')}
                    env['ARCH']='x86_64' if self.has_rpm else 'arm_aarch64'
                    made=subprocess.run([str(self.appimagetool),'--no-appstream','--mksquashfs-opt=-processors',
                        '--mksquashfs-opt=1',str(appdir),str(image)],env=env,capture_output=True,timeout=90)
                    self.assertEqual(made.returncode,0,made.stderr)
                    old=subprocess.run(['unsquashfs','-cat',str(image),'FlClash'],capture_output=True,timeout=30)
                    self.assertNotEqual(old.returncode,0,'Old offset-free reader must reject real AppImage')
                    full={**context,'targets':['deb','appimage',*(['rpm'] if self.has_rpm else [])],'schema_version':1,'platform':'linux','flavor':brand,
                          'base_version':'0.9.1','source_revision':'a'*40,'build_tag':'202610230503',
                          'package_prefix':'omo' if brand=='brand_a' else 'ds'}
                    (case/'build/release-context.json').write_text(json.dumps(full), encoding='utf-8')
                    for action in ('normalize','verify'):
                        result=subprocess.run([sys.executable,str(ROOT/'tool/release_pipeline.py'),action],cwd=case,capture_output=True,text=True)
                        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                    (bundle/'FlClashCore').write_bytes(b'\x7fELFchanged')
                    result=subprocess.run([sys.executable,str(ROOT/'tool/release_pipeline.py'),'normalize'],cwd=case,capture_output=True,text=True)
                    self.assertNotEqual(result.returncode,0)
                    self.assertFalse(json.loads((case/'build/release-artifacts.json').read_text(encoding='utf-8'))['passed'])

    def check_cleanup(self,case,script,helper,remove,upgrade):
        unit=case/'unit.service';link=case/'client-link';commands=case/'commands'
        commands.mkdir(exist_ok=True)
        systemctl=commands/'systemctl';systemctl.write_text('#!/bin/sh\nexit 0\n', encoding='utf-8');systemctl.chmod(0o755)
        script=script.replace('/etc/systemd/system/'+Path(helper).parent.name+'-helper.service',str(unit)).replace('/usr/bin/'+Path(helper).parent.name,str(link))
        path=case/'postrm-test';path.write_text(script, encoding='utf-8')
        env={**os.environ,'PATH':str(commands)+':'+os.environ['PATH']}
        for owned,arg in [(True,upgrade),(False,remove),(True,remove)]:
            unit.write_text('ExecStart="'+(helper if owned else '/other/FlClashHelperService')+'"\n', encoding='utf-8');link.write_text('fixture', encoding='utf-8')
            result=subprocess.run(['sh',str(path),arg],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(unit.exists(),not(owned and arg==remove))
            if arg==upgrade:self.assertTrue(link.exists())


if __name__=='__main__': unittest.main()
