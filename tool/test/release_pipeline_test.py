"""Offline shared pipeline contracts; no compiler, signer, uploader or secrets."""
import hashlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest import mock

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import release_pipeline as pipeline
import check_workflow_lints as lints
import record_build_environment as inventory


def context(platform='windows', arch='amd64', **updates):
    targets={'android':['apk'],'windows':['exe'],'macos':['dmg'],'linux':['deb','appimage']+(['rpm'] if arch=='amd64' else [])}
    result={'schema_version':1,'flavor':'brand_a','platform':platform,'arch':'' if platform=='android' else arch,
            'product_version':'0.0.1','base_version':'0.8.93','build_number':30,'source_revision':'a'*40,
            'build_tag':'202610182200','package_prefix':'omo','package_app_name':'OmoFly','targets':targets[platform]}
    result.update(updates)
    return result


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name);self.dist=self.root/'dist';self.dist.mkdir()
        self.report=self.root/'report.json'

    def test_mac_architecture_reaches_real_package_subprocess_for_both_brands(self):
        for flavor in ('brand_a','brand_b'):
            for arch, expected, excluded in [('amd64','x86_64','arm64'),('arm64','arm64','x86_64')]:
                c=context('macos',arch,flavor=flavor)
                path=self.root/'context.json';path.write_text(json.dumps(c))
                inherited={'FLUTTER_XCODE_ARCHS':'arm64 x86_64','FLUTTER_XCODE_EXCLUDED_ARCHS':expected,
                           'FLUTTER_MACOS_ARM64_ONLY':'true','KEEP':'sentinel'}
                with mock.patch.dict(os.environ,inherited),mock.patch('verify_brand_identity.verify'), \
                     mock.patch.object(pipeline.shutil,'which',return_value='dart-fixture'), \
                     mock.patch.object(pipeline.subprocess,'run',return_value=mock.Mock(returncode=0)) as run:
                    self.assertEqual(pipeline.main(['package','--context',str(path),'--dist',str(self.dist)]),0)
                    env=run.call_args.kwargs['env']
                    self.assertEqual(env['FLUTTER_XCODE_ARCHS'],expected)
                    self.assertEqual(env['FLUTTER_XCODE_EXCLUDED_ARCHS'],excluded)
                    self.assertEqual(env['FLUTTER_XCODE_ONLY_ACTIVE_ARCH'],'NO')
                    self.assertEqual(env['FLUTTER_MACOS_ARM64_ONLY'],'false')
                    self.assertEqual(env['KEEP'],'sentinel')
                    self.assertEqual(os.environ['FLUTTER_XCODE_ARCHS'],'arm64 x86_64')
        for platform,arch in [('android',''),('linux','amd64'),('windows','amd64')]:
            self.assertEqual(pipeline.package_environment(context(platform,arch),{'KEEP':'value'}),{'KEEP':'value'})

    def test_context_rejects_unknown_secret_fields_and_invalid_identity(self):
        path=self.root/'context.json'
        for changes in ({'secret':'sensitive'}, {'build_number':0},{'build_number':True},{'platform':'windows','arch':'arm64'},
                        {'package_prefix':'../../x'}, {'product_version':'0.0.1\ninjection'}, {'targets':['exe','exe']}):
            path.write_text(json.dumps(context(**changes)))
            with self.subTest(changes=changes),self.assertRaises(pipeline.PipelineError):pipeline.read_context(path)

    def test_argv_all_platforms_and_local_optional_formats(self):
        for target,arch in [('windows','amd64'),('android',''),('linux','amd64'),('linux','arm64'),('macos','amd64'),('macos','arm64')]:
            c=context(target,arch);args=pipeline.package_arguments(c)
            self.assertIn('build-number=30',next(a for a in args if a.startswith('--flutter-build-args=')))
            self.assertIn('split-debug-info=build/debug-info', ' '.join(args))
            if target=='android':
                self.assertIn('--build-target-platform=android-arm,android-arm64',args)
                self.assertNotIn('target-platform=',next(a for a in args if a.startswith('--flutter-build-args=')))
                self.assertNotIn('--description',args)
            else:self.assertEqual(args[args.index('--description')+1],arch)
        self.assertIn('exe,zip',pipeline.package_arguments(context(targets=['exe','zip'])))
        self.assertIn('deb,appimage',pipeline.package_arguments(context('linux',targets=['deb','appimage'])))

    def test_compose_preserves_private_defines_without_putting_them_in_context(self):
        defines=self.root/'defines.json';out=self.root/'env.json'
        defines.write_text(json.dumps({'XB_FLAVOR_ID':'brand_a','PRIVATE_MARKER':'not-for-report'}))
        pipeline.compose(context(),defines,self.root/'missing-core.json',out)
        data=json.loads(out.read_text());self.assertEqual(data['PRIVATE_MARKER'],'not-for-report')
        self.assertEqual(data['XB_BUILD_NUMBER'],'30');self.assertEqual(data['XB_PRODUCT_VERSION'],'0.0.1')
        if os.name!='nt':self.assertEqual(out.stat().st_mode & 0o777,0o600)
        pipeline.compose(context(),defines,self.root/'missing-core.json',out,app_env='beta')
        self.assertEqual(json.loads(out.read_text())['APP_ENV'],'beta')
        defines.write_text('{"XB_FLAVOR_ID":"brand_b"}')
        with self.assertRaises(pipeline.PipelineError):pipeline.compose(context(),defines,self.root/'none',out)

    def test_all_platform_inventories_are_exact_and_idempotent(self):
        for target,arch in [('windows','amd64'),('android',''),('linux','amd64'),('linux','arm64'),('macos','amd64'),('macos','arm64')]:
            c=context(target,arch)
            for p in self.dist.iterdir():p.unlink()
            names = (['OmoFly-0.8.93-android-armeabi-v7a-brand_a.apk',
                      'OmoFly-0.8.93-android-arm64-v8a-brand_a.apk'] if target == 'android'
                     else ['raw-'+suffix for suffix,_ in pipeline.expected_artifacts(c)])
            for name in names:(self.dist/name).write_bytes(b'fixture')
            report=pipeline.normalize(c,self.dist,self.report)
            self.assertTrue(report['passed']);self.assertEqual(len(report['artifacts']),len(c['targets']) if target!='android' else 2)
            self.assertEqual({p.name for p in self.dist.iterdir()},{x['file'] for x in report['artifacts']})
            self.assertEqual(pipeline.normalize(c,self.dist,self.report),report)
            self.assertTrue(all(x['sha256']==hashlib.sha256(b'fixture').hexdigest() for x in report['artifacts']))
            self.assertNotIn('PRIVATE_MARKER',self.report.read_text())

    def test_missing_duplicate_empty_extra_and_existing_destination_never_overwrite(self):
        for names in [[],['one-setup.exe','two-setup.exe'],['one-setup.exe','extra.zip'],['one-setup.exe','omo-0.0.1-windows-amd64-setup.exe']]:
            for p in self.dist.iterdir():p.unlink()
            for name in names:(self.dist/name).write_bytes(b'keep')
            before={p.name:p.read_bytes() for p in self.dist.iterdir()}
            with self.subTest(names=names),self.assertRaises(pipeline.PipelineError):pipeline.normalize(context(),self.dist,self.report)
            self.assertEqual({p.name:p.read_bytes() for p in self.dist.iterdir()},before)
            self.assertFalse(json.loads(self.report.read_text())['passed'])
        for p in self.dist.iterdir():p.unlink()
        (self.dist/'empty-setup.exe').touch()
        with self.assertRaises(pipeline.PipelineError):pipeline.normalize(context(),self.dist,self.report)

    def test_android_raw_name_requires_current_brand_version_name_and_exact_abi(self):
        c=context('android','')
        arm32='OmoFly-0.8.93-android-armeabi-v7a-brand_a.apk'
        arm64='OmoFly-0.8.93-android-arm64-v8a-brand_a.apk'
        for invalid in [arm32.replace('brand_a','brand_b'), arm32.replace('0.8.93','0.8.92'),
                        arm32.replace('OmoFly','omo'), arm32.replace('armeabi-v7a','x86_64'),
                        'raw-armeabi-v7a.apk', 'prefix-'+arm32]:
            for p in self.dist.iterdir():p.unlink()
            for name in (invalid,arm64):(self.dist/name).write_bytes(b'keep')
            before={p.name:p.read_bytes() for p in self.dist.iterdir()}
            with self.subTest(invalid=invalid),mock.patch.object(Path,'rename') as rename:
                with self.assertRaises(pipeline.PipelineError):pipeline.normalize(c,self.dist,self.report)
                rename.assert_not_called()
            self.assertEqual({p.name:p.read_bytes() for p in self.dist.iterdir()},before)

    @unittest.skipIf(os.name=='nt','Symlink fixture requires POSIX')
    def test_package_symlink_is_not_followed_or_renamed(self):
        real=self.root/'source';real.write_bytes(b'keep')
        (self.dist/'one-setup.exe').symlink_to(real)
        with self.assertRaises(pipeline.PipelineError):pipeline.normalize(context(),self.dist,self.report)
        self.assertEqual(real.read_bytes(),b'keep')

    def test_postbuild_verification_detects_changed_bytes_or_mixed_batch(self):
        (self.dist/'old-setup.exe').write_bytes(b'fixture')
        report=pipeline.normalize(context(),self.dist,self.report)
        files=pipeline.verified_files(context(),self.dist,self.report)
        self.assertEqual(len(files),1)
        # Non-package support files are never included in the upload file list.
        (self.dist/'diagnostic.txt').write_text('do not upload')
        self.assertEqual(pipeline.verified_files(context(),self.dist,self.report),files)
        with self.assertRaises(pipeline.PipelineError):pipeline.verified_files(context(build_number=31),self.dist,self.report)
        Path(files[0]).write_bytes(b'changed')
        with self.assertRaises(pipeline.PipelineError):pipeline.verified_files(context(),self.dist,self.report)

    def test_existing_local_packages_stop_before_compilation_without_deletion(self):
        old=self.dist/'previous.apk';old.write_bytes(b'keep')
        path=self.root/'context.json';path.write_text(json.dumps(context()))
        with mock.patch.object(pipeline.subprocess,'run') as run,mock.patch('sys.stderr',new=io.StringIO()):
            self.assertEqual(pipeline.main(['package','--context',str(path),'--dist',str(self.dist)]),1)
            run.assert_not_called()
        self.assertEqual(old.read_bytes(),b'keep')

    def test_upload_uses_only_verified_manifest_files_and_propagates_failure(self):
        (self.dist/'old-setup.exe').write_bytes(b'fixture')
        pipeline.normalize(context(),self.dist,self.report)
        context_path=self.root/'context.json';context_path.write_text(json.dumps(context()))
        argv=['upload','--context',str(context_path),'--dist',str(self.dist),'--manifest',str(self.report)]
        with mock.patch.dict(os.environ,{'TAG':'pkg-brand_a-v0.0.1','GITHUB_REPOSITORY':'fixture/repo'}):
            with mock.patch.object(pipeline.subprocess,'run',return_value=mock.Mock(returncode=7)) as run:
                self.assertEqual(pipeline.main(argv),7)
                command=run.call_args.args[0]
                self.assertIn(str(self.dist/'omo-0.0.1-windows-amd64-setup.exe'),command)
                self.assertNotIn('dist/*',command)
            (self.dist/'omo-0.0.1-windows-amd64-setup.exe').write_bytes(b'altered')
            with mock.patch.object(pipeline.subprocess,'run') as run,mock.patch('sys.stderr',new=io.StringIO()):
                self.assertEqual(pipeline.main(argv),1)
                run.assert_not_called()

    def test_validation_finishes_before_first_rename(self):
        (self.dist/'a.deb').write_bytes(b'keep')
        with mock.patch.object(Path,'rename') as rename,self.assertRaises(pipeline.PipelineError):
            pipeline.normalize(context('linux','arm64'),self.dist,self.report)
        rename.assert_not_called()

    def test_linter_archives_require_hash_and_regular_member(self):
        buf=io.BytesIO()
        with tarfile.open(fileobj=buf,mode='w:gz') as tar:
            member=tarfile.TarInfo('tool/actionlint');member.size=4;tar.addfile(member,io.BytesIO(b'test'))
        raw=buf.getvalue();digest=hashlib.sha256(raw).hexdigest()
        self.assertEqual(lints.verified_binary(raw,digest,'actionlint'),b'test')
        with self.assertRaises(ValueError):lints.verified_binary(raw,'0'*64,'actionlint')
        with self.assertRaises(ValueError):lints.verified_binary(raw,digest,'missing')

    def test_tool_inventory_excludes_raw_output_and_secrets(self):
        with mock.patch.object(inventory.subprocess,'run',return_value=mock.Mock(returncode=0,stdout='tool 1.2.3 PRIVATE_MARKER token=secret',stderr='')):
            self.assertEqual(inventory.command_version(['fixture']),{'status':'ok','versions':['1.2.3']})
        with mock.patch.object(inventory.subprocess,'run',return_value=mock.Mock(returncode=0,stdout='go version go1.24.0 linux/amd64',stderr='')):
            self.assertEqual(inventory.command_version(['fixture'])['versions'],['1.24.0'])
        with mock.patch.dict(os.environ,{'ImageOS':'ubuntu24','ImageVersion':'20261018.1','SENTRY_AUTH_TOKEN':'PRIVATE_MARKER'}), mock.patch.object(inventory,'command_version',return_value={'status':'ok','versions':['1.2.3']}), mock.patch.object(inventory.subprocess,'run',return_value=mock.Mock(returncode=0,stdout='{}')):
            report=inventory.collect('linux',self.root)
            self.assertEqual(report['runner_image']['ImageVersion'],'20261018.1')
            self.assertNotIn('PRIVATE_MARKER',json.dumps(report))
        with mock.patch.object(inventory.subprocess,'run',side_effect=FileNotFoundError):
            self.assertEqual(inventory.command_version(['fixture'])['status'],'unavailable')


if __name__=='__main__':unittest.main()
