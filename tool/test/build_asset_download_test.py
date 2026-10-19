"""Offline transport/redirect regressions; never read a real token or use a network."""
from email.message import Message
import io
import http.client
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.request
import urllib.response
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import fetch_build_asset as fetch
import prepare_appimagetool as appimage
import check_workflow_lints as lints

API = 'https://api.github.com/repos/AppImage/AppImageKit/releases/assets/123'
CDN = 'https://release-assets.githubusercontent.com/asset?signature=private-fixture'


class Transport(urllib.request.HTTPSHandler):
    def __init__(self, responses):
        super().__init__()
        self.responses = iter(responses)
        self.requests = []

    def https_open(self, request):
        self.requests.append(request)
        value = next(self.responses)
        if isinstance(value, Exception):
            raise value
        status, header_values, body = value
        headers = Message()
        for key, value in header_values.items(): headers[key] = value
        response = urllib.response.addinfourl(io.BytesIO(body) if isinstance(body, bytes) else body, headers, request.full_url, status)
        response.msg = 'test'
        return response


class DownloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'asset'

    def download(self, responses, **kwargs):
        transport = Transport(responses)
        opener = urllib.request.build_opener(fetch.AssetRedirectHandler(), transport)
        with mock.patch.object(fetch.urllib.request, 'build_opener', return_value=opener), \
             mock.patch.object(fetch.time, 'sleep') as sleep:
            fetch.download_asset(self.path, API, 20, **kwargs)
        return transport.requests, sleep

    def test_redirect_strips_credentials_including_same_origin_and_keeps_get(self):
        for target in (CDN, API + '4'):
            with self.subTest(target=target):
                requests, sleep = self.download([(302, {'Location': target}, b''), (200, {}, b'ok')], token='dummy')
                self.assertEqual(requests[0].get_header('Authorization'), 'Bearer dummy')
                self.assertIsNone(requests[1].get_header('Authorization'))
                self.assertEqual([r.get_method() for r in requests], ['GET', 'GET'])
                self.assertEqual(self.path.read_bytes(), b'ok')
                sleep.assert_not_called()

    def test_redirect_downgrade_and_unapproved_initial_token_destination_fail(self):
        with self.assertRaisesRegex(RuntimeError, 'HTTPS'):
            self.download([(302, {'Location': 'http://example.com/file'}, b'')], token='dummy')
        for url in ('https://api.github.com.evil.test/a', 'https://github.com/owner/repo/file',
                    'https://api.github.com/repos/other/repo/releases/assets/123'):
            with mock.patch.object(fetch.urllib.request, 'build_opener') as opener:
                with self.assertRaises(RuntimeError):
                    fetch.download_asset(self.path, url, 20, token='dummy')
                opener.assert_not_called()

    def test_rate_limit_headers_and_secondary_message_are_respected(self):
        cases = [(403, {'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1010'}, b'', 11),
                 (429, {'Retry-After': '7'}, b'', 7),
                 (403, {}, b'{"message":"API rate limit exceeded"}', 60),
                 (503, {}, b'', 2)]
        for code, headers, body, delay in cases:
            with self.subTest(code=code, headers=headers), mock.patch.object(fetch.time, 'time', return_value=1000):
                requests, sleep = self.download([(code, headers, body), (200, {}, b'ok')])
                self.assertEqual(len(requests), 2)
                sleep.assert_called_once_with(delay)

    def test_permanent_status_long_or_invalid_delay_do_not_retry_or_leak(self):
        for code, headers in ((401, {}), (403, {}), (404, {}),
                              (429, {'Retry-After': '3600'}), (429, {'Retry-After': 'nan'}),
                              (429, {'Retry-After': 'not-a-date'})):
            transport = Transport([(code, headers, b'secret response')])
            opener = urllib.request.build_opener(fetch.AssetRedirectHandler(), transport)
            with mock.patch.object(fetch.urllib.request, 'build_opener', return_value=opener), \
                 mock.patch.object(fetch.time, 'sleep') as sleep:
                with self.assertRaises(RuntimeError) as error:
                    fetch.download_asset(self.path, API, 20, token='dummy')
                self.assertNotIn('secret', str(error.exception)); self.assertNotIn('dummy', str(error.exception))
                self.assertEqual(len(transport.requests), 1)
                sleep.assert_not_called(); self.assertFalse(self.path.exists())

    def test_network_retries_bounded_and_stale_partial_is_overwritten(self):
        self.path.write_bytes(b'old partial')
        requests, sleep = self.download([TimeoutError('hidden'), urllib.error.URLError(CDN), (200, {}, b'ok')])
        self.assertEqual(self.path.read_bytes(), b'ok')
        self.assertEqual(len(requests), 3)
        self.assertEqual(sleep.call_args_list, [mock.call(2), mock.call(4)])
        with self.assertRaisesRegex(RuntimeError, 'attempt 3/3') as error:
            self.download([TimeoutError(CDN)] * 3)
        self.assertNotIn('signature', str(error.exception)); self.assertFalse(self.path.exists())

    def test_partial_response_error_restarts_file_without_appending(self):
        class Interrupted(io.BytesIO):
            def read(self, count=-1):
                if self.tell():
                    raise http.client.IncompleteRead(b'partial')
                return super().read(count)
        requests, sleep = self.download([(200, {}, Interrupted(b'partial')), (200, {}, b'complete')])
        self.assertEqual(self.path.read_bytes(), b'complete')
        self.assertEqual(len(requests), 2)
        sleep.assert_called_once_with(2)

    def test_http_date_and_longer_reset_both_respected(self):
        with mock.patch.object(fetch.time, 'time', return_value=1000):
            _, sleep = self.download([(429, {'Retry-After': 'Thu, 01 Jan 1970 00:16:50 GMT',
                                            'X-RateLimit-Remaining': '0', 'X-RateLimit-Reset': '1020'}, b''),
                                     (200, {}, b'ok')])
            sleep.assert_called_once_with(21)

    def test_secondary_limit_total_wait_and_attempts_are_bounded(self):
        transport = Transport([(403, {}, b'rate limit exceeded')] * 3)
        opener = urllib.request.build_opener(fetch.AssetRedirectHandler(), transport)
        with mock.patch.object(fetch.urllib.request, 'build_opener', return_value=opener), \
             mock.patch.object(fetch.time, 'sleep') as sleep:
            with self.assertRaisesRegex(RuntimeError, 'attempt 3/3'):
                fetch.download_asset(self.path, API, 20)
            self.assertEqual(sleep.call_args_list, [mock.call(60), mock.call(120)])
            self.assertEqual(len(transport.requests), 3)

    def test_size_bound_and_integrity_failure_never_retry(self):
        with self.assertRaisesRegex(RuntimeError, 'size'):
            self.download([(200, {}, b'x' * 21)])
        self.assertFalse(self.path.exists())
        def invalid(destination, *args, **kwargs): destination.write_bytes(b'wrong bytes')
        with mock.patch.object(appimage, 'download_asset', side_effect=invalid) as download:
            with self.assertRaisesRegex(RuntimeError, 'checksum'):
                appimage.fetch_asset(self.path, 'x86_64')
            download.assert_called_once(); self.assertFalse(self.path.exists())

    def test_cold_linter_fetch_uses_shared_transport_and_checks_hash_before_cache(self):
        root = Path(self.temp.name) / 'repo'; (root / 'tool').mkdir(parents=True)
        pins = {name: {'version': '1.2.3', 'url': 'https://github.com/owner/repo/releases/download/v1/asset',
                       'sha256': '0'*64} for name in ('actionlint', 'shellcheck')}
        (root / 'tool/build-tools.json').write_text(json.dumps({'lint_tools': pins}), encoding='utf-8')
        def download(path, *args): path.write_bytes(b'corrupt')
        with mock.patch.object(lints, 'ROOT', root), mock.patch.object(lints.platform, 'system', return_value='Linux'), \
             mock.patch.object(lints.platform, 'machine', return_value='x86_64'), \
             mock.patch.object(lints, 'download_asset', side_effect=download) as request, \
             mock.patch.object(lints.subprocess, 'run') as run:
            self.assertEqual(lints.main(['--prepare']), 1)
            request.assert_called_once(); run.assert_not_called()
            self.assertFalse(list((root/'.local-build/lint-tools').glob('*.tar.gz')))

    def test_ci_scopes_token_to_tool_preparation_and_keeps_integrity_pins(self):
        root = Path(__file__).resolve().parents[2]
        workflow = (root / '.github/workflows/release-package.yml').read_text(encoding='utf-8')
        step = workflow.split('- name: Prepare pinned AppImage tool\n', 1)[1].split('\n      - name:', 1)[0]
        self.assertIn('APPIMAGETOOL_GITHUB_TOKEN: ${{ github.token }}', step)
        self.assertIn("matrix.platform == 'linux'", step)
        self.assertIn('tool/prepare_appimagetool.py --target-arch', step)
        self.assertEqual(workflow.count('APPIMAGETOOL_GITHUB_TOKEN:'), 1)


if __name__ == '__main__': unittest.main()
