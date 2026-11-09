"""Prepare the pinned golden-only font; never installs a system package."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import urllib.request

CONFIG = Path(__file__).resolve().parents[1] / 'test/xboard/golden/environment.json'


def verify(data, expected):
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError('Golden CJK font digest mismatch')


def extract_font(package, member):
    process = subprocess.Popen(['dpkg-deb', '--fsys-tarfile', str(package)],
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    data = None
    try:
        with tarfile.open(fileobj=process.stdout, mode='r|') as archive:
            for entry in archive:
                if entry.name.removeprefix('./') == member:
                    if not entry.isfile() or entry.size > 32 * 1024**2:
                        raise ValueError('Invalid golden font archive member')
                    if data is not None:
                        raise ValueError('Duplicate golden font archive member')
                    data = archive.extractfile(entry).read()
        # Drain archive padding so dpkg-deb cannot block on a full stdout pipe.
        process.stdout.read()
        if process.wait(timeout=30) != 0 or data is None:
            raise ValueError('Golden font package extraction failed')
    finally:
        process.stdout.close()
        if process.poll() is None:
            process.kill()
            process.wait()
    return data


def prepare(output, config, source=None):
    output = Path(output)
    if output.exists():
        verify(output.read_bytes(), config['sha256'])
        return {'path': str(output.resolve()), 'sha256': config['sha256'], 'cached': True}
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='golden-font-', dir=output.parent) as temporary:
        temporary = Path(temporary)
        if source is not None:
            data = Path(source).read_bytes()
        else:
            package = temporary/'font.deb'
            with urllib.request.urlopen(config['packageUrl'], timeout=60) as response:
                with package.open('wb') as stream:
                    total = 0
                    while chunk := response.read(1024**2):
                        total += len(chunk)
                        if total > 128 * 1024**2:
                            raise ValueError('Golden font package exceeds size limit')
                        stream.write(chunk)
            data = extract_font(package, config['packageMember'])
        verify(data, config['sha256'])
        candidate = temporary/'verified.ttc'
        candidate.write_bytes(data)
        os.replace(candidate, output)
    return {'path': str(output.resolve()), 'sha256': config['sha256'], 'cached': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    parser.add_argument('--source', help='Use an already available font instead of downloading')
    args = parser.parse_args()
    config = json.loads(CONFIG.read_text())['cjk']
    print(json.dumps(prepare(args.output, config, args.source)))


if __name__ == '__main__':
    main()
