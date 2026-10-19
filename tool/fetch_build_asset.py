"""Bounded GitHub build-asset GETs; consumers must verify pins before caching/executing."""
from __future__ import annotations
from email.utils import parsedate_to_datetime
import http.client
import math
from pathlib import Path
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit


class AssetRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).scheme != "https":
            raise RuntimeError("Build asset redirect must use HTTPS")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None:
            # Tokens belong only on the initial pinned API request, including
            # when a redirect happens to target another API URL.
            redirected.remove_header("Authorization")
        return redirected


def retry_delay(error, attempt):
    """None means permanent; respect server timing rather than retry too early."""
    if not isinstance(error, urllib.error.HTTPError):
        return 2 ** attempt
    headers = error.headers
    limited = (error.code == 429 or headers.get("X-RateLimit-Remaining") == "0"
               or headers.get("Retry-After") is not None)
    if error.code == 403 and not limited:
        # GitHub may return a secondary rate limit without timing headers.
        limited = b"rate limit" in error.read(8192).lower()
    if error.code not in (429, 500, 502, 503, 504) and not (error.code == 403 and limited):
        return None
    delays = []
    retry_after = headers.get("Retry-After")
    if retry_after:
        try:
            delays.append(float(retry_after))
        except ValueError:
            try:
                delays.append(parsedate_to_datetime(retry_after).timestamp() - time.time())
            except (ValueError, TypeError, OverflowError):
                return None  # Cannot honor an invalid server delay safely.
    if headers.get("X-RateLimit-Remaining") == "0":
        try:
            delays.append(float(headers["X-RateLimit-Reset"]) - time.time() + 1)
        except (KeyError, ValueError, TypeError):
            delays.append(60 * 2 ** (attempt - 1))
    if any(not math.isfinite(delay) for delay in delays):
        return None
    return max([1, *delays]) if delays else (60 * 2 ** (attempt - 1) if limited else 2 ** attempt)


def download_asset(destination: Path, source_url: str, size_limit: int, *, token: str = "") -> None:
    url = urlsplit(source_url)
    if (url.scheme != "https" or url.netloc not in ("api.github.com", "github.com")
            or url.query or url.fragment):
        raise RuntimeError("Build asset must use an approved HTTPS GitHub URL")
    if token and (url.netloc != "api.github.com"
                  or not url.path.startswith("/repos/AppImage/AppImageKit/releases/assets/")
                  or not url.path.rsplit("/", 1)[-1].isdigit()):
        raise RuntimeError("Build asset token is restricted to pinned AppImage API assets")
    headers = {"Accept": "application/octet-stream", "User-Agent": "XFlclash-pinned-build-tools",
               "X-GitHub-Api-Version": "2022-11-28"}
    if token:
        headers["Authorization"] = "Bearer " + token
    opener = urllib.request.build_opener(AssetRedirectHandler())
    waited = 0.0
    for attempt in range(1, 4):
        try:
            request = urllib.request.Request(source_url, headers=headers)
            # Fresh file on every attempt; never append a partial response.
            with opener.open(request, timeout=60) as response, destination.open("wb") as output:
                started = time.monotonic()
                received = 0
                while True:
                    data = response.read(min(65536, size_limit + 1 - received))
                    if not data:
                        break
                    received += len(data)
                    if received > size_limit:
                        raise RuntimeError("Build asset exceeds pinned size")
                    output.write(data)
                    if time.monotonic() - started > 120:
                        raise TimeoutError("Asset transfer time limit")
            return
        except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.HTTPException) as error:
            delay = retry_delay(error, attempt)
            status = f"HTTP {error.code}" if isinstance(error, urllib.error.HTTPError) else type(error).__name__
            if isinstance(error, urllib.error.HTTPError):
                error.close()
            destination.unlink(missing_ok=True)
            if attempt == 3 or delay is None or waited + delay > 180:
                # Do not echo response bodies, signed URLs, or token-bearing exceptions.
                raise RuntimeError(f"Build asset download failed ({status}, attempt {attempt}/3); "
                                   "not retryable or retry budget exhausted") from None
            print(f"Build asset download retry {attempt}/2 ({status}); waiting {delay:g}s", file=sys.stderr)
            time.sleep(delay)
            waited += delay
        except Exception:
            destination.unlink(missing_ok=True)
            raise
