"""Verify selected encrypted fallback in final APKs or desktop Flutter bundles.

Desktop bundles are the inputs packaged into EXE/DMG/DEB/AppImage; this check
does not claim to unpack every installer format. No secrets appear in reports.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile


def canonical_pubspec(data):
    """Ignore ONLY the controlled brand entry when binding local build sources."""
    pattern = rb'(?m)^    # xboard-fallback-assets:begin\r?\n(.*?)^    # xboard-fallback-assets:end'
    matches = list(re.finditer(pattern, data, re.S))
    if len(matches) != 1:
        raise ValueError('fallback_asset_markers_invalid')
    lines = [s.strip() for s in matches[0][1].splitlines() if s.strip() and not s.strip().startswith(b'#')]
    if len(lines) != 1 or not re.fullmatch(rb'- flavors/brand_[ab]/assets/(?:fallback\.bin)?', lines[0]):
        raise ValueError('fallback_asset_entry_invalid')
    return data[:matches[0].start()] + b'    # selected-fallback-entry' + data[matches[0].end():]


def verify(root, flavor, platform, *, packages=(), build_root=None):
    root = Path(root).resolve()
    if flavor not in ('brand_a','brand_b') or platform not in ('android','windows','macos','linux'):
        raise ValueError('invalid_fallback_target')
    relative = f'flavors/{flavor}/assets/fallback.bin'
    source = root / relative
    if source.is_symlink() or not source.resolve().is_relative_to(root) or not source.is_file() or not source.stat().st_size:
        raise ValueError('missing_fallback_source')
    expected = source.read_bytes()
    checked = []
    if platform == 'android':
        if not packages:
            raise ValueError('no_apks_for_fallback_check')
        for package in packages:
            with zipfile.ZipFile(package) as archive:
                names = archive.namelist()
                wanted = 'assets/flutter_assets/'+relative
                fallbacks = [n for n in names if n.startswith('assets/flutter_assets/flavors/') and n.endswith('/fallback.bin')]
                if fallbacks != [wanted] or archive.read(wanted) != expected:
                    raise ValueError('apk_fallback_missing_mixed_or_changed')
            checked.append(Path(package).name)
    else:
        build = Path(build_root) if build_root else root/'build'
        patterns = {
            'windows':['windows/*/runner/Release/data/flutter_assets'],
            'linux':['linux/*/release/bundle/data/flutter_assets'],
            'macos':['macos/Build/Products/Release/*.app/Contents/Frameworks/App.framework/Resources/flutter_assets',
                     'macos/Build/Products/Release/*.app/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets'],
        }
        roots = {p.resolve() for pattern in patterns[platform] for p in build.glob(pattern) if p.is_dir()}
        if len(roots) != 1:
            raise ValueError('missing_or_ambiguous_flutter_asset_bundle')
        assets = roots.pop()
        if not assets.is_relative_to(build.resolve()):
            raise ValueError('asset_bundle_outside_build')
        fallbacks = list((assets/'flavors').rglob('fallback.bin'))
        wanted = assets/relative
        if fallbacks != [wanted] or wanted.is_symlink() or not wanted.resolve().is_relative_to(assets) or wanted.read_bytes() != expected:
            raise ValueError('bundle_fallback_missing_mixed_or_changed')
        checked.append('desktop_flutter_bundle')
    return {'passed':True,'flavor':flavor,'platform':platform,'checked':checked,
            'fallback_sha256':hashlib.sha256(expected).hexdigest()}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--context',type=Path,default=Path('build/release-context.json'))
    parser.add_argument('--dist',type=Path,default=Path('dist'))
    args=parser.parse_args()
    from release_pipeline import read_context, verified_files, write_json
    evidence=Path('build/fallback-assets-evidence.json')
    write_json(evidence,{'passed':False})
    c=read_context(args.context)
    packages=verified_files(c,args.dist,Path('build/release-artifacts.json'))
    report=verify(Path.cwd(),c['flavor'],c['platform'],packages=packages if c['platform']=='android' else ())
    write_json(evidence,report)
    print('Selected fallback matches the packaged Flutter assets')


if __name__=='__main__':
    try:main()
    except (ValueError,OSError,KeyError,zipfile.BadZipFile):
        raise SystemExit('Fallback asset verification failed')
