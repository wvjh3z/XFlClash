"""Offline transport/protocol regressions; never send events or upload symbols."""
import io
import json
from pathlib import Path
import sys
import unittest
from unittest import mock
import urllib.error
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sentry_upload_confirmation as c

ID = '12345678-1234-5678-abcd-123456789abc'
ID2 = 'abcdefab-1234-5678-abcd-123456789abc'


def local(ident=ID, fmt='elf', arch='x86_64'):
    return dict(debug_ids=[ident], format=fmt, architectures=[arch], features='debug, symtab')


def remote(ident=ID, fmt='elf', arch='x86_64', features=None):
    return dict(debugId=ident, symbolType=fmt, cpuName=arch,
                data={'features': ['debug', 'symtab'] if features is None else features})


class Clock:
    value = 0
    def now(self): return self.value
    def sleep(self, delay): self.value += delay


class ConfirmationTests(unittest.TestCase):
    def confirm(self, items, fetch, report=None, budget=40):
        clock = Clock()
        report = report if report is not None else {}
        c.confirm_symbol_inventory('daishu', items, 'fixture-secret', report,
                                   fetch=fetch, now=clock.now, sleep=clock.sleep, budget=budget)
        return report, clock

    def test_each_platform_and_brand_requires_exact_inventory(self):
        for project in ('omofly', 'daishu'):
            for fmt, server, arch in [('elf','elf','arm64'), ('elf','elf','x86_64'),
                                       ('pdb','pdb','x86_64'), ('dsym','macho','arm64')]:
                with self.subTest(project=project, fmt=fmt, arch=arch):
                    report = {}; clock = Clock()
                    c.confirm_symbol_inventory(project, [local(fmt=fmt, arch=arch)], 'secret', report,
                        fetch=lambda i,t: [remote(fmt=server,arch=arch)], now=clock.now, sleep=clock.sleep)
                    self.assertEqual(report['status'], 'confirmed')
                    self.assertEqual(report['confirmed'], 1)

    def test_macos_singular_architecture_and_aliases(self):
        item = local(fmt='dsym'); del item['architectures']; item['architecture'] = 'x64'
        result, _ = self.confirm([item], lambda i,t: [remote(fmt='macho')])
        self.assertEqual(result['confirmed'], 1)

    def test_pending_then_visible_reuses_confirmed_ids(self):
        calls = []
        def fetch(ident, timeout):
            calls.append(ident)
            if ident == ID2 and calls.count(ID2) < 3: return []
            return [remote(ident)]
        report, clock = self.confirm([local(), local(ID2)], fetch)
        self.assertEqual(report['rounds'], 3)
        self.assertEqual(calls.count(ID), 1)
        self.assertEqual(clock.value, 20)

    def test_same_count_wrong_id_format_arch_or_features_never_passes(self):
        wrong = [remote(ID2), remote(fmt='pdb'), remote(arch='arm64'), remote(features=['unwind']),
                 {}, dict(debugId=None, data={}), remote(features=['debug']), remote(features=[])]
        for row in wrong:
            with self.subTest(row=row), self.assertRaisesRegex(c.UploadError, 'unconfirmed'):
                self.confirm([local()], lambda i,t: [row], budget=20)

    def test_persistent_pending_and_network_failure_are_bounded_with_missing_rows(self):
        for failed in (False, True):
            report = {}; calls = []
            def fetch(i,t):
                calls.append(t)
                if failed: raise c.UploadError('transport_error', phase='confirmation')
                return []
            with self.subTest(failed=failed), self.assertRaises(c.UploadError):
                self.confirm([local()], fetch, report, budget=30)
            self.assertLessEqual(len(calls), 3)
            self.assertLessEqual(max(calls), 15)
            self.assertEqual(report['status'], 'failed')
            self.assertEqual(report['missing'][0]['debug_id'], ID)
            self.assertNotIn('fixture-secret', json.dumps(report))

    def test_auth_failure_is_fatal_even_if_other_files_exist(self):
        for category in ('authentication_rejected', 'permission_rejected', 'request_rejected'):
            calls = []
            def fetch(i,t):
                calls.append(i); raise c.UploadError(category, phase='confirmation')
            with self.subTest(category=category), self.assertRaisesRegex(c.UploadError, category):
                self.confirm([local()], fetch)
            self.assertEqual(calls, [ID])

    def test_rate_limit_respects_retry_after_and_deadline(self):
        count = 0
        def fetch(i,t):
            nonlocal count
            count += 1
            if count == 1: raise c.UploadError('rate_limited', phase='confirmation', retry_after=25)
            return [remote()]
        report, clock = self.confirm([local()], fetch)
        self.assertEqual(clock.value, 25)
        self.assertEqual(report['request_failures'], 1)
        with self.assertRaises(c.UploadError):
            self.confirm([local()], lambda *_: (_ for _ in ()).throw(
                c.UploadError('rate_limited', phase='confirmation', retry_after=100)), budget=20)

    def test_invalid_local_inventory_never_calls_http(self):
        for item in ({}, local(ident='bad'), local(fmt='exe'), local(arch='private/path')):
            fetch = mock.Mock()
            with self.subTest(item=item), self.assertRaises(c.UploadError):
                self.confirm([item], fetch)
            fetch.assert_not_called()

    def test_duplicates_are_deduplicated_but_same_id_different_formats_are_required(self):
        report, _ = self.confirm([local(),local(),local(fmt='pdb')], lambda i,t: [remote(),remote(fmt='pdb')])
        self.assertEqual(report['expected'], 2)


class DiagnosticsTests(unittest.TestCase):
    def test_classification_and_private_output_never_leaks(self):
        cases = [('HTTP status: 401', 'authentication_rejected'), ('HTTP status: 403', 'permission_rejected'),
                 ('HTTP status: 429', 'rate_limited'), ('HTTP status: 503','server_error'),
                 ('HTTP status: 400','request_rejected'), ('connection reset','transport_error'),
                 ('Some symbols could not be found!','invalid_or_missing_symbols'),
                 ('Error: some symbols did not process correctly','symbol_processing_failed'),
                 ('The file is still processing and not ready yet','processing_incomplete'),
                 ('unknown','cli_failed_unknown')]
        private = '\nAuthorization: Bearer fixture-secret https://example.com/?token=fixture-secret C:/private/品牌/flavor.yaml'
        for message, category in cases:
            with self.subTest(category=category):
                error = c.cli_failure(1, message + private, private)
                self.assertEqual(error.category, category)
                rendered = json.dumps(error.diagnostic) + str(error)
                for value in ('fixture-secret', 'example.com', 'flavor.yaml', '品牌'):
                    self.assertNotIn(value, rendered)
                self.assertIn('exit 1', str(error))

    def test_auth_takes_precedence_over_pending_and_success_sentences(self):
        error = c.cli_failure(1, '> File processing complete:\nThe file is still processing and not ready yet', 'HTTP status: 403')
        self.assertEqual(error.category, 'permission_rejected')


class Response(io.BytesIO):
    def __init__(self, content, headers=None):
        super().__init__(content); self.headers = headers or {}


class HttpContractTests(unittest.TestCase):
    def test_get_is_project_scoped_and_keeps_token_off_url(self):
        opener = mock.Mock()
        opener.open.return_value = Response(json.dumps([remote()]).encode())
        self.assertEqual(len(c.get_debug_files('daishu', ID, 'fixture-secret', 12, opener=opener)), 1)
        request = opener.open.call_args.args[0]
        self.assertEqual(request.get_method(), 'GET')
        self.assertEqual(request.full_url, 'https://us.sentry.io/api/0/projects/ka-chiu-lee/daishu/files/dsyms/?debug_id='+ID)
        self.assertEqual(opener.open.call_args.kwargs['timeout'], 12)
        self.assertNotIn('fixture-secret', request.full_url)

    def test_http_errors_are_precise_and_do_not_echo_bodies(self):
        for code, category in [(401,'authentication_rejected'),(403,'permission_rejected'),(429,'rate_limited'),(503,'server_error'),(302,'request_rejected')]:
            opener = mock.Mock(); body = io.BytesIO(b'private-token-server-body')
            opener.open.side_effect = urllib.error.HTTPError('https://private/',code,'secret',{'Retry-After':'17'},body)
            with self.subTest(code=code), self.assertRaises(c.UploadError) as error:
                c.get_debug_files('omofly',ID,'secret',10,opener=opener)
            self.assertEqual(error.exception.category,category)
            self.assertEqual(error.exception.diagnostic['http_status'],code)
            self.assertNotIn('private',str(error.exception))
            self.assertTrue(body.closed)

    def test_redirect_handler_never_forwards_authorization(self):
        self.assertIsNone(c.NoRedirect().redirect_request(None,None,302,'',{},'https://evil.example'))

    def test_bad_json_shapes_and_oversized_responses_fail_closed(self):
        for data in [b'not json', b'{}', b'[null]', b'x'*2_000_001]:
            opener=mock.Mock(); opener.open.return_value=Response(data)
            with self.subTest(size=len(data)), self.assertRaises(c.UploadError):
                c.get_debug_files('daishu',ID,'secret',10,opener=opener)

    def test_invalid_project_and_id_never_send_credentials(self):
        opener=mock.Mock()
        for project, ident in [('evil',ID),('omofly','../private')]:
            with self.assertRaises(c.UploadError): c.get_debug_files(project,ident,'secret',10,opener=opener)
        opener.open.assert_not_called()


if __name__ == '__main__': unittest.main()
