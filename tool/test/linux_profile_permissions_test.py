#!/usr/bin/env python3
"""Run existing Dart as a real unprivileged user against isolated Linux fixtures."""
import argparse
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--dart', required=True, type=Path)
    parser.add_argument('--user', default='nobody')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit('Root fixture controller required; Dart itself runs unprivileged')
    user = pwd.getpwnam(args.user)
    if user.pw_uid == 0:
        raise SystemExit('Test user must be non-root')
    repo = Path(__file__).resolve().parents[2]
    rows = []
    with tempfile.TemporaryDirectory(prefix='xb-permission-test-') as tmp:
        root = Path(tmp)
        root.chmod(0o755)
        shutil.copyfile(repo/'lib/xboard/services/xb_profile_file_write.dart', root/'xb_profile_file_write.dart')
        shutil.copyfile(repo/'lib/xboard/services/profile_recovery_owner.dart', root/'profile_recovery_owner.dart')
        shutil.copyfile(repo/'tool/test/fixtures/profile_permissions_probe.dart', root/'probe.dart')
        for brand in ('brand_a', 'brand_b'):
            for case in ('no_search', 'no_access', 'marker_read', 'payload_delete',
                         'root_list', 'target_delete', 'stage_cleanup',
                         'missing_marker', 'missing_root', 'missing_target', 'marker_link'):
                base = root/f'{brand}-{case}'
                base.mkdir()
                target = base/'42.yaml'
                target.write_text('old-config')
                recovery = base/'.xb-profile-owned'
                recovery.mkdir()
                marker = recovery/'owner.json'
                metadata = json.dumps({'schema': 1, 'flavor': brand, 'owner': 'owner', 'profile': '42.yaml'})
                marker.write_text(metadata)
                (recovery/'previous.yaml').write_text('old-backup')
                for path in [base, *base.rglob('*')]:
                    os.chown(path, user.pw_uid, user.pw_gid)
                    path.chmod(0o700 if path.is_dir() else 0o600)
                action = 'cleanup'
                denied = None
                if case == 'no_search': denied = recovery; denied.chmod(0o600)
                elif case == 'no_access': denied = recovery; denied.chmod(0)
                elif case == 'marker_read': denied = marker; denied.chmod(0)
                elif case == 'payload_delete': denied = recovery; denied.chmod(0o500)
                elif case == 'root_list': denied = base; denied.chmod(0)
                elif case == 'target_delete': denied = base; denied.chmod(0o600); action = 'delete'
                elif case == 'stage_cleanup': action = 'stage_cleanup'
                elif case == 'missing_marker': marker.unlink()
                elif case == 'missing_root': shutil.rmtree(base)
                elif case == 'missing_target': target.unlink(); action = 'delete'
                elif case == 'marker_link':
                    external = base/'external.json'; external.write_text(metadata)
                    os.chown(external, user.pw_uid, user.pw_gid); external.chmod(0o600)
                    marker.unlink(); marker.symlink_to(external)

                def probe(operation):
                    p = subprocess.run(['runuser', '-u', args.user, '--', str(args.dart),
                                        str(root/'probe.dart'), str(base), brand, operation],
                                       text=True, capture_output=True, timeout=30, check=True)
                    return json.loads(p.stdout)

                try:
                    result = probe(action)
                    negative = denied is not None or case == 'stage_cleanup'
                    assert result['ok'] is not negative, (brand, case, result)
                    if negative:
                        assert result['code'] in (1, 2, 13), (brand, case, result)
                        assert target.read_text() == 'old-config'
                        assert marker.exists()
                    if case in ('missing_marker', 'marker_link'):
                        assert (recovery/'previous.yaml').read_text() == 'old-backup'
                    if case == 'marker_link':
                        assert marker.is_symlink() and external.read_text() == metadata
                    rows.append({'brand': brand, 'scenario': case, 'phase': 'initial', 'result': result})
                finally:
                    if denied is not None:
                        denied.chmod(0o700 if denied.is_dir() else 0o600)
                if negative:
                    recovered = probe('delete' if action == 'delete' else 'cleanup')
                    assert recovered['ok'], (brand, case, recovered)
                    if action == 'delete': assert not target.exists()
                    else: assert not list(base.glob('.xb-profile-*'))
                    rows.append({'brand': brand, 'scenario': case, 'phase': 'restored', 'result': recovered})
        result = {'uid': user.pw_uid, 'dart': subprocess.check_output([str(args.dart), '--version'], text=True).strip(), 'cases': rows}
        if args.output:
            args.output.write_text(json.dumps(result, indent=2)+'\n')
        print(json.dumps(result))


if __name__ == '__main__':
    main()
