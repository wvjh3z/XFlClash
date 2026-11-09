#!/usr/bin/env python3
"""Read-only CI credential/commit/checkout diagnosis; never emit HTTP bodies."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.request

import checkout_sibling_sdk as checkout

API = 'https://api.github.com/repos/wvjh3z/Xboard_sdk'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        return None


def probe(token: str, ref: str, opener=None) -> list[dict]:
    opener = opener or urllib.request.build_opener(NoRedirect())
    results = []
    for phase, url in [('repository_access', API), ('commit_access', API + '/git/commits/' + ref)]:
        request = urllib.request.Request(url, headers={
            'Authorization': 'Bearer ' + token,
            'Accept': 'application/vnd.github+json',
            'X-GitHub-Api-Version': '2022-11-28',
            'User-Agent': 'xflclash-sdk-read-diagnostic',
        })
        row = {'phase': phase}
        try:
            with opener.open(request, timeout=20) as response:
                row['http_status'] = response.status
                data = response.read(1024 * 1024 + 1)
                if len(data) > 1024 * 1024:
                    raise ValueError('response limit')
                payload = json.loads(data)
                valid = (payload.get('full_name', '').lower() == 'wvjh3z/xboard_sdk'
                         if phase == 'repository_access' else payload.get('sha') == ref)
                row['code'] = 'accessible' if response.status == 200 and valid else 'unexpected_api_response'
        except urllib.error.HTTPError as error:
            row['http_status'] = error.code
            if error.code == 401:
                row['code'] = 'authentication_rejected'
            elif error.code == 403:
                if error.headers.get('X-RateLimit-Remaining') == '0':
                    row['code'] = 'rate_limited'
                elif 'required' in error.headers.get('X-GitHub-SSO', '').lower():
                    row['code'] = 'organization_sso_required'
                else:
                    row['code'] = 'access_denied_or_limited'
            elif error.code == 404:
                row['code'] = 'repository_not_accessible' if phase == 'repository_access' else 'commit_not_accessible'
            elif error.code == 429:
                row['code'] = 'rate_limited'
            elif 300 <= error.code < 400:
                row['code'] = 'redirect_not_followed'
            else:
                row['code'] = 'github_api_http_failure'
            error.close()
        except (OSError, ValueError, TypeError, AttributeError):
            row['code'] = 'api_transport_or_response_failure'
        results.append(row)
        if row['code'] != 'accessible':
            break
    return results


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref', required=True)
    args = parser.parse_args(argv)
    report = {'status': 'failed', 'api_checks': [], 'checkout_attempted': False}
    token = os.environ.get('SDK_READ_TOKEN', '')
    workspace = Path(os.environ.get('GITHUB_WORKSPACE', '.')).resolve()
    try:
        if not re.fullmatch(r'[a-f0-9]{40}', args.ref):
            report['code'] = 'immutable_sdk_sha_required'
        elif not token or len(token) > 4096 or any(not 33 <= ord(c) <= 126 for c in token):
            report['code'] = 'sdk_read_token_required_or_invalid'
        else:
            report['api_checks'] = probe(token, args.ref)
            if all(row['code'] == 'accessible' for row in report['api_checks']):
                report['checkout_attempted'] = True
                destination = workspace.parent / 'Xboard_sdk'
                checkout.checkout(destination, args.ref, dict(os.environ))
                result = subprocess.run(
                    ['git', '-C', str(destination), 'rev-parse', 'HEAD'],
                    env=checkout.clean_environment(dict(os.environ)),
                    capture_output=True, text=True, timeout=30,
                )
                if result.returncode == 0 and result.stdout.strip() == args.ref:
                    report.update(status='passed', code='fixed_sdk_checked_out', sdk_sha=args.ref)
                else:
                    report['code'] = 'checkout_identity_mismatch'
            else:
                report['code'] = report['api_checks'][-1]['code']
    except checkout.CheckoutError as error:
        report.update(phase=error.phase, code=error.code, exit_code=error.exit_code)
    except (OSError, ValueError, subprocess.SubprocessError):
        report['code'] = 'diagnostic_io_failure'
    output = workspace / 'build/sdk-access-diagnostic.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(report))
    return 0 if report['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
