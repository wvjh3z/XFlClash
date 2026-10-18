#!/usr/bin/env python3
"""Shared packaging argv, private defines composition and strict final inventory."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


class PipelineError(RuntimeError):
    pass


def write_json(path, data, *, private=False):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise PipelineError('output_symlink')
    fd, tmp = tempfile.mkstemp(prefix='.release-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=True, indent=2)
            f.write('\n')
        if not private:
            os.chmod(tmp, 0o644)
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


def read_context(path):
    c = json.loads(Path(path).read_text(encoding='utf-8'))
    required = {'schema_version','flavor','platform','arch','product_version','base_version',
                'build_number','source_revision','build_tag','package_prefix','package_app_name','targets'}
    if not isinstance(c,dict) or set(c) != required or type(c['schema_version']) != int or c['schema_version'] != 1 or c['flavor'] not in ('brand_a','brand_b'):
        raise PipelineError('invalid_context')
    for key, pattern in [('product_version', r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?(?:\+[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*)?'),
                         ('base_version', r'[0-9]+\.[0-9]+\.[0-9]+'), ('source_revision', r'[a-f0-9]{40}'),
                         ('build_tag', r'[0-9]{12}'), ('package_prefix', r'[A-Za-z0-9][A-Za-z0-9._-]*'),
                         ('package_app_name', r'[A-Za-z0-9][A-Za-z0-9._-]*')]:
        if not isinstance(c[key], str) or not re.fullmatch(pattern, c[key]):
            raise PipelineError('invalid_context_field')
    if type(c['build_number']) != int or not 1 <= c['build_number'] <= 65535:
        raise PipelineError('invalid_build_number')
    if not isinstance(c['platform'],str) or not isinstance(c['arch'],str) or not isinstance(c['targets'],list):
        raise PipelineError('invalid_target_types')
    allowed = {('android',''): (['apk'],), ('windows','amd64'): (['exe'],['exe','zip']),
               ('macos','amd64'): (['dmg'],), ('macos','arm64'): (['dmg'],),
               ('linux','amd64'): (['deb','appimage'],['deb','appimage','rpm']),
               ('linux','arm64'): (['deb','appimage'],)}
    if c['targets'] not in allowed.get((c['platform'],c['arch']), ()):
        raise PipelineError('invalid_target_set')
    return c


def package_arguments(c):
    options = ['dart-define-from-file=env.json', 'build-name='+c['base_version'],
               'build-number='+str(c['build_number']), 'split-debug-info=build/debug-info']
    if c['platform'] == 'android':
        options.append('split-per-abi')
    args = ['pub','global','run','flutter_distributor:main','package','--skip-clean',
            '--platform',c['platform'],'--targets',','.join(c['targets']),
            '--flutter-build-args='+','.join(options)]
    if c['platform'] == 'android':
        args += ['--build-target-platform=android-arm,android-arm64','--build-flavor',c['flavor']]
    else:
        args += ['--description',c['arch']]
    return args


def compose(c, defines_path='flavor_defines.json', core_path='core_sha256.json', output='env.json', app_env='stable'):
    if not isinstance(app_env,str) or not re.fullmatch(r'[A-Za-z][A-Za-z0-9_-]{0,31}',app_env):
        raise PipelineError('invalid_app_environment')
    data = json.loads(Path(defines_path).read_text(encoding='utf-8'))
    if not isinstance(data, dict) or data.get('XB_FLAVOR_ID') != c['flavor']:
        raise PipelineError('defines_flavor_mismatch')
    core = ''
    if Path(core_path).exists():
        core = json.loads(Path(core_path).read_text(encoding='utf-8')).get('CORE_SHA256', '')
        if not isinstance(core, str) or (core and not re.fullmatch(r'[0-9a-fA-F]{64}', core)):
            raise PipelineError('invalid_core_hash')
    data.update(APP_ENV=app_env, CORE_SHA256=core, XB_FORM_A='true', XB_BUILD_TAG=c['build_tag'],
                XB_PRODUCT_VERSION=c['product_version'], XB_BUILD_NUMBER=str(c['build_number']))
    write_json(output, data, private=True)


def expected_artifacts(c):
    stem = c['package_prefix']+'-'+c['product_version']+'-'+c['platform']+'-'
    if c['platform'] == 'android':
        return [('armeabi-v7a.apk',stem+'armeabi-v7a.apk'), ('arm64-v8a.apk',stem+'arm64-v8a.apk')]
    suffix = {'exe':'-setup.exe','zip':'.zip','dmg':'.dmg','deb':'.deb','appimage':'.AppImage','rpm':'.rpm'}
    return [('setup.exe' if t == 'exe' else suffix[t],stem+c['arch']+suffix[t]) for t in c['targets']]


def normalize(c, dist, manifest):
    write_json(manifest, {'schema_version': 1, 'passed': False, 'artifacts': []})
    dist = Path(dist)
    if not dist.is_dir() or dist.is_symlink():
        raise PipelineError('missing_or_unsafe_dist')
    # Nested packaging directories are normal; distribution files must be unique.
    files = [p for p in dist.iterdir() if p.is_file() or p.is_symlink()]
    package_suffixes = ('.apk','.exe','.zip','.dmg','.deb','.AppImage','.rpm')
    packages = [p for p in files if p.name.endswith(package_suffixes)]
    plans = []
    for suffix, target in expected_artifacts(c):
        # Existing final names are accepted for idempotent postbuild verification.
        matches = [p for p in packages if p.name.endswith(suffix)]
        if len(matches) != 1:
            raise PipelineError('missing_or_duplicate_artifact: '+suffix)
        source = matches[0]
        if source.is_symlink() or source.stat().st_size == 0:
            raise PipelineError('empty_or_symlink_artifact')
        destination = dist/target
        if source != destination and destination.exists():
            raise PipelineError('artifact_destination_exists')
        plans.append((source,destination))
    if set(packages) != {p for p,_ in plans}:
        raise PipelineError('unexpected_artifact')
    # Validate the entire set before touching any filename; no silent mv -f loss.
    completed = []
    try:
        for source,destination in plans:
            if source != destination:
                source.rename(destination)
                completed.append((source,destination))
    except OSError:
        for source,destination in reversed(completed):
            destination.rename(source)
        raise
    records = []
    for _,path in plans:
        digest = hashlib.sha256()
        with path.open('rb') as f:
            for block in iter(lambda:f.read(1024*1024), b''):
                digest.update(block)
        records.append({'file':path.name,'size':path.stat().st_size,'sha256':digest.hexdigest()})
    report = {'schema_version':1, 'passed': True, **{k:c[k] for k in ('flavor','platform','arch','product_version','build_number','source_revision')},
              'artifacts':records}
    write_json(manifest,report)
    return report



def verified_files(c, dist, manifest):
    report = json.loads(Path(manifest).read_text(encoding='utf-8'))
    for key in ('flavor','platform','arch','product_version','build_number','source_revision'):
        if report.get(key) != c[key]: raise PipelineError('manifest_identity_mismatch')
    wanted = {target for _,target in expected_artifacts(c)}
    rows = report.get('artifacts',[])
    if report.get('passed') is not True or len(rows) != len(wanted) or {r.get('file') for r in rows} != wanted:
        raise PipelineError('manifest_inventory_mismatch')
    dist = Path(dist)
    if dist.is_symlink(): raise PipelineError('unsafe_dist')
    actual = {p.name for p in dist.iterdir() if p.name.endswith(('.apk','.exe','.zip','.dmg','.deb','.AppImage','.rpm'))}
    if actual != wanted: raise PipelineError('unexpected_final_artifact')
    files=[]
    for row in rows:
        if type(row.get('size')) != int or row['size'] <= 0 or not isinstance(row.get('sha256'),str) or not re.fullmatch(r'[0-9a-f]{64}',row['sha256']):
            raise PipelineError('invalid_manifest_record')
        path=dist/row['file']
        if path.is_symlink() or not path.is_file() or path.stat().st_size != row['size']:
            raise PipelineError('final_artifact_changed')
        digest=hashlib.sha256()
        with path.open('rb') as f:
            for block in iter(lambda:f.read(1024*1024),b''): digest.update(block)
        if digest.hexdigest() != row['sha256']: raise PipelineError('final_artifact_changed')
        files.append(str(path))
    return files


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['compose','package','normalize','value','verify','upload'])
    parser.add_argument('--context', default='build/release-context.json')
    parser.add_argument('--dist', default='dist')
    parser.add_argument('--manifest', default='build/release-artifacts.json')
    parser.add_argument('--key', choices=['product_version','base_version'])
    args = parser.parse_args(argv)
    try:
        c = read_context(args.context)
        if args.action == 'value':
            if not args.key: raise PipelineError('missing_key')
            print(c[args.key])
        elif args.action == 'compose':
            compose(c, app_env=os.environ.get('APP_ENV','stable'))
            print('Private build defines composed; values not printed')
        elif args.action == 'normalize':
            report = normalize(c,args.dist,args.manifest)
            print('Verified distribution files: '+str(len(report['artifacts'])))
        elif args.action in ('verify','upload'):
            files = verified_files(c,args.dist,args.manifest)
            if args.action == 'upload':
                tag,repo = os.environ.get('TAG',''),os.environ.get('GITHUB_REPOSITORY','')
                expected_tag = 'pkg-'+c['flavor']+'-v'+c['product_version']
                if tag != expected_tag or not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repo):
                    raise PipelineError('invalid_upload_identity')
                return subprocess.run(['gh','release','upload',tag,*files,'--repo',repo,'--clobber'],check=False).returncode
            print('Final artifact hashes match the prepared manifest')
        else:
            # CI uses a fresh checkout. Locally stop before compilation if old
            # distributables would make this run ambiguous; never delete them.
            dist = Path(args.dist)
            if dist.is_symlink() or (dist.exists() and any(p.name.endswith(('.apk','.exe','.zip','.dmg','.deb','.AppImage','.rpm')) for p in dist.iterdir())):
                raise PipelineError('dist_contains_existing_packages_use_clean_output_workspace')
            native = Path(os.environ.get('FLUTTER_ROOT',''))/'bin/cache/dart-sdk/bin/dart.exe'
            dart = str(native) if os.name == 'nt' and native.is_file() else shutil.which('dart')
            if not dart: raise PipelineError('dart_missing')
            return subprocess.run([dart,*package_arguments(c)], check=False).returncode
        return 0
    except (OSError, ValueError, TypeError, KeyError, PipelineError) as error:
        reason = str(error) if isinstance(error, PipelineError) else type(error).__name__
        print('Release pipeline failed: '+reason, file=sys.stderr)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
