#!/usr/bin/env python3
"""Read actual APK metadata and enforce cross-entry Android release contracts."""
import json
import itertools
import os
from pathlib import Path
import re
import shutil
import sys
import subprocess
from apk_archive import ApkArchive

ROOT = Path(__file__).resolve().parents[1]
POLICY = json.loads((ROOT / 'tool/android_version_policy.json').read_text(encoding='utf-8'))
def validate_crisp_contract(contract):
    if contract.get('schema_version') != 2 or not isinstance(contract.get('resources'), dict) or not contract['resources']:
        raise ValueError('Invalid Crisp resource mapping schema')
    for identifier, runtime in contract['resources'].items():
        if not re.fullmatch(r'[a-z]+/[A-Za-z0-9_]+', identifier) or not isinstance(runtime, str) or not re.fullmatch(r'[A-Za-z0-9_.]+', runtime):
            raise ValueError('Invalid Crisp resource name')
        if identifier.split('/', 1)[1] != runtime.replace('.', '_'):
            raise ValueError('Crisp runtime name does not match its R identifier')
    return contract


CRISP_CONTRACT = validate_crisp_contract(json.loads((ROOT / 'tool/crisp_resource_contract.json').read_text(encoding='utf-8')))
CHANNELS = ('service', 'core', 'app', 'battery', 'battery/optimization', 'tile')


def version_code(build):
    if type(build) is not int or not 0 < build <= POLICY['maximum'] - POLICY['offset']:
        raise ValueError('Invalid Android product build number')
    return POLICY['offset'] + build


def resource_value_is_usable(value):
    if value.strip() == '<bag>':
        return True
    scalar = re.match(r't=0x([0-9a-fA-F]+)\s+d=0x([0-9a-fA-F]+)\b', value)
    if not scalar:
        return False
    kind, data = (int(part, 16) for part in scalar.groups())
    # TYPE_NULL (including @empty) and zero reference/attribute targets are
    # unusable. Scalar zero remains valid: false, integer 0, transparent color.
    return kind != 0 and not (kind in (1, 2, 7, 8) and data == 0)


class ResourceConfigurationUncertain(ValueError):
    """A qualifier changes reference flow but its selection is not modeled."""


_CONFIG_AXES = {'ldltr': ('direction', 'ltr'), 'ldrtl': ('direction', 'rtl'),
                'port': ('orientation', 'port'), 'land': ('orientation', 'land'),
                'notnight': ('night', False), 'night': ('night', True)}


def parse_resource_configuration(label):
    result = {'version': 0}
    if label == '(default)':
        return result
    for token in label.split('-'):
        if token in _CONFIG_AXES:
            key, value = _CONFIG_AXES[token]
        elif re.fullmatch(r'v[0-9]+', token):
            key, value = 'version', int(token[1:])
        else:
            return None
        if key in result and key != 'version':
            return None
        result[key] = value
    return result


def resource_flow(value):
    if not resource_value_is_usable(value):
        return ('invalid', 0)
    if value.strip() == '<bag>':
        return ('leaf', 0)
    scalar = re.match(r't=0x([0-9a-fA-F]+)\s+d=0x([0-9a-fA-F]+)\b', value)
    kind, data = (int(part, 16) for part in scalar.groups())
    return ('reference', data) if kind in (1, 7) else ('leaf', 0)


def select_resource_value(values, context):
    # Configuration-invariant valid terminals or identical references need no
    # qualifier emulation (e.g. translated strings or density-specific images).
    flows = {resource_flow(value) for value in values.values()}
    if len(flows) == 1 and next(iter(flows))[0] != 'invalid':
        if '(default)' in values:
            return values['(default)']
        # Density variants can legitimately omit default resources. Collapse
        # only identical flows and only if the API level has an available entry.
        density = r'(?:ldpi|mdpi|tvdpi|hdpi|xhdpi|xxhdpi|xxxhdpi|anydpi|nodpi|[0-9]+dpi)(?:-v([0-9]+))?'
        densities = [(re.fullmatch(density, label), value) for label, value in values.items()]
        if all(match for match, value in densities):
            available = [value for match, value in densities if int(match[1] or 0) <= context['version']]
            return available[0] if available else None
    candidates = []
    for label, value in values.items():
        config = parse_resource_configuration(label)
        if config is None:
            raise ResourceConfigurationUncertain('Unsupported resource configuration: ' + label)
        if config['version'] > context['version']:
            continue
        if any(key in config and config[key] != context[key] for key in ('direction', 'orientation', 'night')):
            continue
        # Android qualifier priority: layout direction, orientation, UI/night,
        # then API level. Do not rank only by number of qualifier tokens.
        rank = tuple(int(key in config) for key in ('direction', 'orientation', 'night')) + (config['version'],)
        candidates.append((rank, value))
    if not candidates:
        return None
    rank = max(rank for rank, value in candidates)
    winners = [value for candidate_rank, value in candidates if candidate_rank == rank]
    if len({resource_flow(value) for value in winners}) != 1:
        raise ResourceConfigurationUncertain('Ambiguous resource configuration selection')
    return winners[0]


def verify_crisp_resources(dump, package, *, min_sdk=24):
    expected = {identifier.split('/', 1)[0] + '/' + runtime
                for identifier, runtime in CRISP_CONTRACT['resources'].items()}
    entries, names, roots = {}, {}, {}
    invalid = set()
    configuration = '(default)'
    pattern = r'^\s*resource (0x[0-9a-fA-F]+) ([\w.]+):([\w]+)/([\w.]+):\s*(.*)$'
    for line in dump.splitlines():
        header = re.match(r'^\s*config ([^:]+):\s*$', line)
        if header:
            configuration = header[1]
            continue
        match = re.match(pattern, line)
        if not match:
            continue
        identifier, owner, kind, name, value = match.groups()
        identifier = int(identifier, 16)
        if identifier == 0 or owner != package:
            continue
        resource = kind + '/' + name
        if identifier in names and names[identifier] != resource:
            invalid.add(identifier)
        names[identifier] = resource
        values = entries.setdefault(identifier, {})
        if configuration in values and values[configuration] != value:
            invalid.add(identifier)
        values[configuration] = value
        if resource in expected:
            roots.setdefault(resource, set()).add(identifier)


    missing = {resource for resource in expected if len(roots.get(resource, ())) != 1}
    ambiguous_ids = invalid
    # Qualifier transitions partition the supported device space. API values
    # between boundaries have identical selection, so no per-version loop.
    versions = {min_sdk}
    axes = {'direction': ['ltr'], 'orientation': ['port'], 'night': [False]}
    for values in entries.values():
        for label in values:
            api = re.search(r'(?:^|-)v([0-9]+)$', label)
            if api and int(api[1]) >= min_sdk: versions.add(int(api[1]))
            config = parse_resource_configuration(label)
            if config is None:
                continue
            if config['version'] >= min_sdk:
                versions.add(config['version'])
            if 'direction' in config: axes['direction'] = ['ltr', 'rtl']
            if 'orientation' in config: axes['orientation'] = ['port', 'land']
            if 'night' in config: axes['night'] = [False, True]
    uncertain = set()
    for direction, orientation, night, version in itertools.product(axes['direction'], axes['orientation'], axes['night'], sorted(versions)):
        context = dict(direction=direction, orientation=orientation, night=night, version=version)
        pending = [identifier for ids in roots.values() for identifier in ids]
        dependencies, parents = {}, {}
        invalid, unknown = set(ambiguous_ids), set()
        while pending:
            identifier = pending.pop()
            if identifier in dependencies:
                continue
            dependencies[identifier] = set()
            if identifier not in entries:
                invalid.add(identifier)
                continue
            try:
                value = select_resource_value(entries[identifier], context)
            except ResourceConfigurationUncertain:
                unknown.add(identifier)
                continue
            if value is None or not resource_value_is_usable(value):
                invalid.add(identifier)
                continue
            flow, target = resource_flow(value)
            if flow != 'reference' or target >> 24 == 0x01:
                continue
            dependencies[identifier].add(target)
            parents.setdefault(target, set()).add(identifier)
            pending.append(target)
        remaining = {identifier: len(targets) for identifier, targets in dependencies.items()}
        ready = [identifier for identifier, count in remaining.items() if count == 0]
        resolved = set()
        while ready:
            identifier = ready.pop()
            resolved.add(identifier)
            for parent in parents.get(identifier, ()):
                if identifier in invalid: invalid.add(parent)
                if identifier in unknown: unknown.add(parent)
                remaining[parent] -= 1
                if remaining[parent] == 0: ready.append(parent)
        invalid.update(set(dependencies) - resolved)
        for resource, identifiers in roots.items():
            if identifiers & invalid: missing.add(resource)
            if identifiers & unknown: uncertain.add(resource)
    if missing:
        names = sorted(missing)
        raise ValueError('APK Crisp runtime resources missing or unusable (' + str(len(names)) + '): ' + ', '.join(names[:8]))
    if uncertain:
        raise ResourceConfigurationUncertain('Crisp reference configurations require explicit review: ' + ', '.join(sorted(uncertain)[:8]))
    return len(CRISP_CONTRACT['resources'])


def _verify(apk, build, package, aapt, *, badging=None, resources_dump=None):
    if badging is None:
        result = subprocess.run([str(aapt), 'dump', 'badging', str(apk)],
                                capture_output=True, check=True, timeout=60)
        badging = result.stdout.decode('utf-8')
    text = badging
    line = next((line for line in text.splitlines() if line.startswith('package: ')), '')
    fields = dict(re.findall(r"([A-Za-z]+)='([^']*)'", line))
    if fields.get('name') != package or fields.get('versionCode') != str(version_code(build)):
        raise ValueError('APK metadata mismatch: ' + json.dumps({
            'file': Path(apk).name, 'expected': {'package': package, 'versionCode': version_code(build)},
            'actual': {key: fields.get(key, '<missing>')[:128] for key in ('name', 'versionCode', 'versionName')},
        }, ensure_ascii=True))
    with ApkArchive(apk) as archive:
        dex = b'\0'.join(archive.read(n) for n in archive.namelist() if re.fullmatch(r'classes\d*\.dex', n))
        aot_paths = [n for n in archive.namelist() if re.fullmatch(r'lib/[^/]+/libapp\.so', n)]
        if not aot_paths:
            raise ValueError('APK Dart AOT library missing')
        for name in aot_paths:
            aot = archive.read(name)
            for suffix in CHANNELS:
                if (package + '/' + suffix).encode() in aot:
                    raise ValueError('APK Dart uses branded native channel: ' + suffix)
    for suffix in CHANNELS:
        if ('com.follow.clash/' + suffix).encode() + b'\0' not in dex:
            raise ValueError('APK native channel missing: ' + suffix)
    if resources_dump is None:
        result = subprocess.run([str(aapt), 'dump', 'resources', str(apk)], capture_output=True, check=True, timeout=60)
        resources_dump = result.stdout.decode('utf-8')
    minimum = re.search(r"^sdkVersion:'([0-9]+)'", badging, re.M)
    resource_count = verify_crisp_resources(resources_dump, package, min_sdk=int(minimum[1]) if minimum else 24)
    return {'file': Path(apk).name, 'versionCode': version_code(build), 'package': package,
            'crispResourcesVerified': True, 'crispResourceCount': resource_count}



def verify(apk, build, package, aapt, *, badging=None, resources_dump=None, diagnostic_path=None):
    """Persist only safe metadata, including failure evidence for either entrypoint."""
    report = {'schema_version': 1, 'scope': 'android-contract', 'file': Path(apk).name, 'passed': False,
              'expected': {'package': package, 'productBuild': build}, 'actual': None}
    try:
        report['expected']['versionCode'] = version_code(build)
        if badging is None:
            result = subprocess.run([str(aapt), 'dump', 'badging', str(apk)],
                                    capture_output=True, check=True, timeout=60)
            badging = result.stdout.decode('utf-8')
        line = next((line for line in badging.splitlines() if line.startswith('package: ')), '')
        fields = dict(re.findall(r"([A-Za-z]+)='([^']*)'", line))
        report['actual'] = {key: fields.get(key, '<missing>')[:128]
                            for key in ('name', 'versionCode', 'versionName')}
        result = _verify(apk, build, package, aapt, badging=badging, resources_dump=resources_dump)
        report.update(passed=True, result=result)
        return result
    except Exception as error:
        report['failureType'] = type(error).__name__
        report['inconclusive'] = isinstance(error, ResourceConfigurationUncertain)
        raise
    finally:
        if diagnostic_path is not None:
            write_diagnostic(diagnostic_path, report)


def write_diagnostic(path, report):
    """Replace evidence atomically; callers supply only safe structured fields."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(report, ensure_ascii=True, indent=2) + '\n', encoding='utf-8')
    temporary.replace(path)


def find_aapt():
    sdk = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
    if sdk:
        candidates = list((Path(sdk) / 'build-tools').glob('*/aapt'))
        if candidates:
            return sorted(candidates, key=lambda p: tuple(int(x) for x in re.findall(r'\d+', p.parent.name)))[-1]
    found = shutil.which('aapt')
    if not found:
        raise RuntimeError('Android aapt is required for final artifact verification')
    return found


def main():
    context = json.loads((ROOT / 'build/release-context.json').read_text(encoding='utf-8'))
    assert context['platform'] == 'android'
    defines = json.loads((ROOT / 'flavor_defines.json').read_text(encoding='utf-8'))
    package = defines['XB_NATIVE_ID']
    apks = list((ROOT / 'dist').glob('*.apk'))
    if len(apks) != 2:
        raise ValueError('Expected both official ARM32 and ARM64 APKs')
    reports, failures = [], []
    for p in sorted(apks):
        try:
            reports.append(verify(p, context['build_number'], package, find_aapt(),
                                  diagnostic_path=ROOT / 'build/android-release-contract' / (p.name + '.json')))
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            failures.append(error)
            print(str(error) if isinstance(error, ValueError) else type(error).__name__, file=sys.stderr)
    if failures:
        # A definite bad artifact takes precedence over uncertain resource analysis.
        raise next((e for e in failures if not isinstance(e, ResourceConfigurationUncertain)), failures[0])
    print(json.dumps(reports))


if __name__ == '__main__':
    try:
        main()
    except ResourceConfigurationUncertain as error:
        print('INCONCLUSIVE: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
