#!/usr/bin/env python3
import io
import json
from pathlib import Path
import sys
import unittest
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import diagnose_sibling_sdk as diagnostic

TOKEN = 'fixture-secret-not-for-output'
REF = 'a' * 40


class Response(io.BytesIO):
    status = 200


class Opener:
    def __init__(self, replies):
        self.replies = list(replies)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        reply = self.replies.pop(0)
        if isinstance(reply, Exception):
            raise reply
        return Response(json.dumps(reply).encode())


class DiagnosticTests(unittest.TestCase):
    def test_repository_and_exact_commit_are_both_checked(self):
        opener = Opener([{'full_name': 'wvjh3z/Xboard_sdk'}, {'sha': REF}])
        result = diagnostic.probe(TOKEN, REF, opener)
        self.assertEqual([x['code'] for x in result], ['accessible', 'accessible'])
        self.assertTrue(opener.requests[1].full_url.endswith('/git/commits/' + REF))
        self.assertNotIn(TOKEN, json.dumps(result))

    def test_failed_access_is_classified_without_echoing_response_or_token(self):
        cases = [(401, {}, 'authentication_rejected'),
                 (403, {}, 'access_denied_or_limited'),
                 (403, {'X-RateLimit-Remaining': '0'}, 'rate_limited'),
                 (403, {'X-GitHub-SSO': 'required; url=' + TOKEN}, 'organization_sso_required'),
                 (404, {}, 'repository_not_accessible'),
                 (302, {'Location': 'https://example.invalid/' + TOKEN}, 'redirect_not_followed')]
        for status, headers, expected in cases:
            with self.subTest(status=status, expected=expected):
                error = urllib.error.HTTPError(diagnostic.API, status, TOKEN, headers, io.BytesIO(TOKEN.encode()))
                opener = Opener([error])
                result = diagnostic.probe(TOKEN, REF, opener)
                self.assertEqual(result[0]['code'], expected)
                self.assertEqual(len(opener.requests), 1)
                self.assertNotIn(TOKEN, json.dumps(result))

    def test_commit_access_failure_is_distinct_from_repository_metadata_access(self):
        error = urllib.error.HTTPError(diagnostic.API, 404, TOKEN, {}, io.BytesIO(TOKEN.encode()))
        result = diagnostic.probe(TOKEN, REF, Opener([{'full_name': 'wvjh3z/Xboard_sdk'}, error]))
        self.assertEqual(result[-1]['code'], 'commit_not_accessible')
        self.assertNotIn(TOKEN, json.dumps(result))

    def test_wrong_commit_cannot_report_success(self):
        result = diagnostic.probe(TOKEN, REF, Opener([{'full_name': 'wvjh3z/Xboard_sdk'}, {'sha': 'b' * 40}]))
        self.assertEqual(result[-1]['code'], 'unexpected_api_response')

    def test_redirect_handler_does_not_forward_authorization(self):
        self.assertIsNone(diagnostic.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://example.invalid'))

    def test_diagnostic_mode_cannot_run_the_normal_module_job(self):
        root = Path(__file__).resolve().parents[2]
        text = (root / '.github/workflows/xboard-ci.yml').read_text()
        diagnostic_job, normal_job = text.split('  sdk-access-diagnostic:', 1)[1].split('  analyze-and-test:', 1)
        self.assertIn('if: ${{ inputs.sdk_diagnostic_only }}', diagnostic_job)
        self.assertIn('if: ${{ !inputs.sdk_diagnostic_only }}', normal_job)
        for forbidden in ('flutter-action', 'release_pipeline.py', 'package_desktop_local', 'postbuild_sentry', 'prepare_flavor'):
            self.assertNotIn(forbidden, diagnostic_job)
        self.assertIn('persist-credentials: false', diagnostic_job)
        self.assertIn('submodules: false', diagnostic_job)


if __name__ == '__main__':
    unittest.main()
