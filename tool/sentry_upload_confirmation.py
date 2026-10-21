"""Bounded, credential-safe diagnostics and per-DIF Sentry confirmation.

Only GETs the fixed US SaaS project route. No API writes, redirects, source
uploads or arbitrary URLs. A CLI completion sentence alone is not proof that
all local debug IDs, formats, architectures and features exist on the server.
"""
from __future__ import annotations
import concurrent.futures
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
import json
import http.client
import math
import re
import time
import urllib.error
import urllib.parse
import urllib.request

PROJECTS = {'omofly', 'daishu'}
FORMATS = {'elf', 'pdb', 'dsym', 'breakpad', 'portablepdb'}
FEATURES = {'debug', 'symtab', 'unwind', 'sources'}
WAIT_SECONDS = 600
REQUEST_SECONDS = 15


class UploadError(RuntimeError):
    def __init__(self, category, *, phase, exit_code=None, http_status=None, retry_after=0):
        self.category, self.retry_after = category, retry_after
        self.diagnostic = {'phase': phase, 'category': category}
        if exit_code is not None:
            self.diagnostic['exit_code'] = exit_code
        if http_status is not None:
            self.diagnostic['http_status'] = http_status
        suffix = f' (exit {exit_code})' if exit_code is not None else ''
        super().__init__(f'Sentry {phase}: {category}{suffix}')


def cli_failure(code, stdout, stderr):
    # Inspect bounded tails in memory only. Do not persist any raw line: headers,
    # signed URLs, env/config paths and arbitrary server bodies can contain secrets.
    text = (stdout[-65536:] + '\n' + stderr[-65536:]).lower()
    statuses = [int(x) for x in re.findall(r'\b(?:http(?:\s+status)?|status(?:\s+code)?)[\s:=(]+([1-5][0-9]{2})\b', text)]
    status = 401 if 401 in statuses else 403 if 403 in statuses else statuses[-1] if statuses else None
    if status == 401 or 'authentication failed' in text or 'invalid token' in text:
        category = 'authentication_rejected'
    elif status == 403 or 'permission denied' in text or 'forbidden' in text:
        category = 'permission_rejected'
    elif status == 429 or 'rate limit' in text:
        category = 'rate_limited'
    elif status and status >= 500:
        category = 'server_error'
    elif status and status >= 400:
        category = 'request_rejected'
    elif 'some symbols could not be found' in text or 'invalid debug' in text:
        category = 'invalid_or_missing_symbols'
    elif any(x in text for x in ('the file is still processing and not ready yet', 'processing timed out',
                                 'did not finish processing', 'processing timeout')):
        category = 'processing_incomplete'
    elif 'some symbols did not process correctly' in text:
        category = 'symbol_processing_failed'
    elif any(x in text for x in ('timed out', 'timeout', 'could not resolve',
                                 'failed to connect', 'connection reset', 'network')):
        category = 'transport_error'
    else:
        category = 'cli_failed_unknown'
    error = UploadError(category, phase='upload', exit_code=code, http_status=status)
    error.diagnostic.update(stdout_bytes=len(stdout.encode('utf-8')),
                            stderr_bytes=len(stderr.encode('utf-8')))
    return error


def cpu(value):
    value = str(value).lower()
    return {'x64': 'x86_64', 'amd64': 'x86_64', 'aarch64': 'arm64',
            'arm64-v8a': 'arm64', 'armeabi-v7a': 'arm', 'armv7': 'arm', 'armv7l': 'arm', 'i386': 'x86'}.get(value, value)


def requirements(inventory):
    expected = set()
    for item in inventory:
        fmt = item.get('format')
        text = item.get('features', '')
        if not isinstance(text, str):
            raise UploadError('invalid_local_inventory', phase='confirmation')
        features = frozenset(x.strip() for x in text.split(',') if x.strip())
        arches = item.get('architectures') or [item.get('architecture')]
        ids = item.get('debug_ids')
        if not isinstance(ids, list) or not ids or not isinstance(arches, list):
            raise UploadError('invalid_local_inventory', phase='confirmation')
        if fmt not in FORMATS or not arches or not features or not features <= FEATURES:
            raise UploadError('invalid_local_inventory', phase='confirmation')
        # --no-sources deliberately prevents uploading source bundles.
        features = features - {'sources'}
        if not features:
            raise UploadError('invalid_local_features', phase='confirmation')
        for ident in ids:
            if not isinstance(ident, str) or not re.fullmatch(r'[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}(?:-[a-fA-F0-9]+)?', ident):
                raise UploadError('invalid_local_debug_id', phase='confirmation')
            for arch in arches:
                if not isinstance(arch, str) or not re.fullmatch(r'[a-zA-Z0-9_+-]{1,32}', arch):
                    raise UploadError('invalid_local_architecture', phase='confirmation')
                expected.add((ident.lower(), 'macho' if fmt == 'dsym' else fmt, cpu(arch), features))
    if not expected:
        raise UploadError('empty_local_inventory', phase='confirmation')
    return expected


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def retry_after(value):
    if not value:
        return 10
    try:
        delay = float(value)
    except ValueError:
        try:
            delay = (parsedate_to_datetime(value) - datetime.now(timezone.utc)).total_seconds()
        except (ValueError, TypeError, OverflowError):
            raise UploadError('invalid_retry_after', phase='confirmation') from None
    if not math.isfinite(delay):
        raise UploadError('invalid_retry_after', phase='confirmation')
    return max(1, delay)


def get_debug_files(project, ident, token, timeout, *, opener=None):
    if project not in PROJECTS or not re.fullmatch(r'[a-f0-9-]{36,70}', ident):
        raise UploadError('invalid_request_identity', phase='confirmation')
    if not token or '\n' in token or '\r' in token:
        raise UploadError('invalid_credential', phase='confirmation')
    url = ('https://us.sentry.io/api/0/projects/ka-chiu-lee/' + project
           + '/files/dsyms/?' + urllib.parse.urlencode({'debug_id': ident}))
    request = urllib.request.Request(url, method='GET', headers={
        'Authorization': 'Bearer ' + token, 'Accept': 'application/json',
        'User-Agent': 'XFlclash-symbol-confirmation'})
    try:
        with (opener or urllib.request.build_opener(NoRedirect())).open(request, timeout=timeout) as response:
            # A single debug ID has a small number of format/architecture rows.
            # Do not accept partial pages silently or follow arbitrary Link URLs.
            if 'rel="next"; results="true"' in response.headers.get('Link', ''):
                raise UploadError('inventory_pagination_unexpected', phase='confirmation')
            chunks, size = [], 0
            deadline = time.monotonic() + timeout
            while True:
                chunk = response.read1(min(65536, 2_000_001 - size))
                if time.monotonic() > deadline:
                    raise TimeoutError()
                if not chunk:
                    break
                chunks.append(chunk); size += len(chunk)
                if size > 2_000_000:
                    raise UploadError('response_too_large', phase='confirmation')
            raw = b''.join(chunks)
            data = json.loads(raw)
            if not isinstance(data, list) or any(not isinstance(x, dict) for x in data):
                raise UploadError('invalid_server_inventory', phase='confirmation')
            return data
    except urllib.error.HTTPError as error:
        code = error.code
        try:
            delay = retry_after(error.headers.get('Retry-After')) if code in (429, 503) else 10
        finally:
            error.close()
        category = {401: 'authentication_rejected', 403: 'permission_rejected',
                    429: 'rate_limited'}.get(code, 'server_error' if code >= 500 else 'request_rejected')
        raise UploadError(category, phase='confirmation', http_status=code, retry_after=delay) from None
    except (urllib.error.URLError, OSError, http.client.HTTPException):
        raise UploadError('transport_error', phase='confirmation', retry_after=10) from None
    except (ValueError, UnicodeError):
        raise UploadError('invalid_server_inventory', phase='confirmation') from None


def matches(row, expected):
    ident, fmt, arch, features = expected
    if not isinstance(row, dict) or not isinstance(row.get('debugId'), str):
        return False
    data = row.get('data')
    if not isinstance(data, dict) or not isinstance(data.get('features'), list):
        return False
    return (row.get('debugId', '').lower() == ident
            and row.get('symbolType') == fmt and cpu(row.get('cpuName')) == arch
            and features <= set(x for x in data['features'] if isinstance(x, str)))


def confirm_symbol_inventory(project, inventory, token, report, *,
                             budget=WAIT_SECONDS, fetch=None, now=None, sleep=None, emit=None):
    fetch = fetch or (lambda ident, timeout: get_debug_files(project, ident, token, timeout))
    now, sleep = now or time.monotonic, sleep or time.sleep
    pending = requirements(inventory)
    total = len(pending)
    started = now()
    deadline = started + budget
    report.update(phase='confirmation', status='pending', expected=total, confirmed=0,
                  rounds=0, request_failures=0, wait_budget_seconds=budget)
    try:
        while pending and now() < deadline and report['rounds'] < 61:
            report['rounds'] += 1
            delay = 10
            ids = sorted({item[0] for item in pending})
            def query(ident):
                remaining = deadline - now()
                if remaining <= 0:
                    return ident, UploadError('confirmation_deadline', phase='confirmation')
                try:
                    return ident, fetch(ident, min(REQUEST_SECONDS, remaining))
                except UploadError as error:
                    return ident, error
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                for ident, result in pool.map(query, ids):
                    if isinstance(result, UploadError):
                        report['last_request_error'] = result.diagnostic
                        report['request_failures'] += 1
                        if result.category not in {'transport_error', 'server_error', 'rate_limited', 'confirmation_deadline'}:
                            raise result
                        delay = max(delay, result.retry_after)
                    else:
                        pending = {item for item in pending if item[0] != ident
                                   or not any(matches(row, item) for row in result)}
            report['confirmed'] = total - len(pending)
            if emit:
                emit(f'Sentry confirmation: {report["confirmed"]}/{total}, round {report["rounds"]}')
            if not pending:
                report['status'] = 'confirmed'
                return
            remaining = deadline - now()
            if remaining <= 0 or delay >= remaining:
                break
            sleep(delay)
        raise UploadError('symbols_unconfirmed_before_deadline', phase='confirmation')
    except UploadError as error:
        report.update(status='failed', error=error.diagnostic)
        raise
    finally:
        report['confirmed'] = total - len(pending)
        report['elapsed_seconds'] = round(now() - started, 3)
        report['missing'] = [dict(debug_id=i, format=f, architecture=a, features=sorted(s))
                             for i, f, a, s in sorted(pending)]
